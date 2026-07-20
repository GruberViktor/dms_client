import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:watcher/watcher.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import 'session.dart';

/// Desktop round-trip editing (spec §7 M3): download a version to a temp
/// dir, open it in the system default app, watch the file, and once its
/// content is *stable* and different, offer replace-in-place / new-version.
enum EditPhase { watching, changed, uploading }

class EditSession {
  final String uuid;
  final int versionNumber;
  final String filePath;
  final String fileName;
  final bool compliance;
  final EditPhase phase;

  /// Checksum of the last downloaded/uploaded content — "unchanged" baseline.
  final String checksum;

  const EditSession({
    required this.uuid,
    required this.versionNumber,
    required this.filePath,
    required this.fileName,
    required this.compliance,
    required this.phase,
    required this.checksum,
  });

  EditSession copyWith({
    EditPhase? phase,
    String? checksum,
    int? versionNumber,
  }) =>
      EditSession(
        uuid: uuid,
        versionNumber: versionNumber ?? this.versionNumber,
        filePath: filePath,
        fileName: fileName,
        compliance: compliance,
        phase: phase ?? this.phase,
        checksum: checksum ?? this.checksum,
      );
}

class EditSessionsNotifier extends Notifier<Map<String, EditSession>> {
  final _subs = <String, StreamSubscription<WatchEvent>>{};
  final _debounce = <String, Timer>{};

  @override
  Map<String, EditSession> build() {
    // Login/logout resets all edit sessions (and cancels their watchers).
    ref.watch(sessionProvider);
    ref.onDispose(() {
      for (final s in _subs.values) {
        s.cancel();
      }
      for (final t in _debounce.values) {
        t.cancel();
      }
      _subs.clear();
      _debounce.clear();
    });
    return {};
  }

  static String _hash(List<int> bytes) => sha256.convert(bytes).toString();

  /// Download version [v], open it externally, and start watching.
  /// One session per document — a new start replaces the old one.
  Future<void> start(Document doc, DocumentVersion v) async {
    stop(doc.uuid);
    final api = ref.read(apiProvider);
    final bytes = await api.downloadVersion(doc.uuid, v.number);
    final dir = await getTemporaryDirectory();
    final safeName = v.originalFilename.isNotEmpty
        ? v.originalFilename.replaceAll(RegExp(r'[/\\]'), '_')
        : 'document';
    final file =
        File('${dir.path}/dms_edit/${doc.uuid}/v${v.number}/$safeName');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);

    state = {
      ...state,
      doc.uuid: EditSession(
        uuid: doc.uuid,
        versionNumber: v.number,
        filePath: file.path,
        fileName: safeName,
        compliance: doc.inComplianceMode,
        phase: EditPhase.watching,
        checksum: _hash(bytes),
      ),
    };
    _subs[doc.uuid] =
        FileWatcher(file.path).events.listen((e) => _onEvent(doc.uuid));
    await OpenFilex.open(file.path);
  }

  void stop(String uuid) {
    _subs.remove(uuid)?.cancel();
    _debounce.remove(uuid)?.cancel();
    if (state.containsKey(uuid)) {
      state = {...state}..remove(uuid);
    }
  }

  void _onEvent(String uuid) {
    // Editors save in bursts (temp file + rename, multiple writes) — debounce
    // and only act once the content has stopped moving.
    _armDebounce(uuid);
  }

  void _armDebounce(String uuid) {
    _debounce[uuid]?.cancel();
    _debounce[uuid] =
        Timer(const Duration(seconds: 2), () => _checkStability(uuid));
  }

  /// The editing app may still hold the file open: hash twice with a pause
  /// and only prompt when both hashes agree and differ from the baseline.
  Future<void> _checkStability(String uuid) async {
    final s = state[uuid];
    if (s == null || s.phase == EditPhase.uploading) return;
    final file = File(s.filePath);
    String h1, h2;
    try {
      if (!await file.exists()) return; // atomic-save window — keep watching
      h1 = _hash(await file.readAsBytes());
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!await file.exists()) return;
      h2 = _hash(await file.readAsBytes());
    } catch (_) {
      _armDebounce(uuid); // file busy/locked — try again later
      return;
    }
    if (h1 != h2) {
      _armDebounce(uuid); // still being written
      return;
    }
    final current = state[uuid];
    if (current == null) return;
    if (h1 == current.checksum) {
      // Saved without changes (or reverted) — nothing to offer.
      if (current.phase == EditPhase.changed) {
        state = {...state, uuid: current.copyWith(phase: EditPhase.watching)};
      }
      return;
    }
    state = {...state, uuid: current.copyWith(phase: EditPhase.changed)};
  }

  /// Upload the changed file as version N+1. Duplicate-bytes 409 is retried
  /// with force — the user explicitly chose to upload this exact content.
  Future<void> uploadAsNewVersion(String uuid) async {
    final s = state[uuid];
    if (s == null) return;
    state = {...state, uuid: s.copyWith(phase: EditPhase.uploading)};
    final api = ref.read(apiProvider);
    try {
      final bytes = await File(s.filePath).readAsBytes();
      DocumentVersion created;
      try {
        created = await api.uploadVersion(
            uuid, MultipartFile.fromBytes(bytes, filename: s.fileName));
      } on ApiException catch (e) {
        if (!e.isDuplicateFile) rethrow;
        created = await api.uploadVersion(
            uuid, MultipartFile.fromBytes(bytes, filename: s.fileName),
            force: true);
      }
      state = {
        ...state,
        uuid: s.copyWith(
          phase: EditPhase.watching,
          checksum: _hash(bytes),
          versionNumber: created.number,
        ),
      };
    } catch (_) {
      final cur = state[uuid];
      if (cur != null) {
        state = {...state, uuid: cur.copyWith(phase: EditPhase.changed)};
      }
      rethrow;
    }
  }

  /// Replace the bytes of the watched version in place (non-compliance only;
  /// the server 409s otherwise).
  Future<void> replaceFile(String uuid) async {
    final s = state[uuid];
    if (s == null) return;
    state = {...state, uuid: s.copyWith(phase: EditPhase.uploading)};
    final api = ref.read(apiProvider);
    try {
      final bytes = await File(s.filePath).readAsBytes();
      await api.replaceVersionFile(uuid, s.versionNumber,
          MultipartFile.fromBytes(bytes, filename: s.fileName));
      state = {
        ...state,
        uuid: s.copyWith(phase: EditPhase.watching, checksum: _hash(bytes)),
      };
    } catch (_) {
      final cur = state[uuid];
      if (cur != null) {
        state = {...state, uuid: cur.copyWith(phase: EditPhase.changed)};
      }
      rethrow;
    }
  }
}

final editSessionsProvider =
    NotifierProvider<EditSessionsNotifier, Map<String, EditSession>>(
        EditSessionsNotifier.new);
