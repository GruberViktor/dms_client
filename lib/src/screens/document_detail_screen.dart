import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../util/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/edit_sessions.dart';
import '../state/permissions.dart';
import '../state/session.dart';
import '../state/watches.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import '../widgets/timeline.dart';
import 'edit_document_screen.dart';

class DocumentDetailScreen extends ConsumerStatefulWidget {
  final String uuid;

  const DocumentDetailScreen({super.key, required this.uuid});

  @override
  ConsumerState<DocumentDetailScreen> createState() =>
      _DocumentDetailScreenState();
}

class _DocumentDetailScreenState extends ConsumerState<DocumentDetailScreen> {
  Document? _doc;
  List<TimelineEvent>? _events;
  List<DocumentComment>? _comments;
  Object? _error;
  Timer? _pollTimer;
  bool _busy = false;
  // Versions whose release hit the four-eyes 403 (`approval_required`): the
  // button stays visible but disabled with a hint — unlike a plain 403,
  // which drops release_version for the whole type (hand-off §4).
  final Set<int> _fourEyesBlocked = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final api = ref.read(apiProvider);
      final doc = await api.document(widget.uuid);
      List<TimelineEvent>? events;
      try {
        events = await api.timeline(widget.uuid);
      } on ApiException {
        events = null; // timeline may be forbidden; the rest still works
      }
      List<DocumentComment>? comments;
      try {
        comments = await api.comments(widget.uuid);
      } on ApiException {
        comments = null;
      }
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _events = events;
        _comments = comments;
      });
      _schedulePollIfExtracting();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  /// Poll while any visible version is pending/running OCR (spec §3).
  void _schedulePollIfExtracting() {
    _pollTimer?.cancel();
    final extracting =
        _doc?.versions.any(
          (v) =>
              !v.isHidden &&
              (v.extractionStatus == ExtractionStatus.pending ||
                  v.extractionStatus == ExtractionStatus.running),
        ) ??
        false;
    if (extracting) {
      _pollTimer = Timer(const Duration(seconds: 4), _load);
    }
  }

  Future<void> _toggleArchive() async {
    final doc = _doc!;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiProvider);
      if (doc.archived) {
        await api.unarchiveDocument(doc.uuid);
      } else {
        await api.archiveDocument(doc.uuid);
      }
      if (mounted) {
        showSnack(context, doc.archived ? 'Unarchived.' : 'Archived.');
      }
      await _load();
    } on ApiException catch (e) {
      if (e.isForbidden) _recordDenied('archive');
      if (mounted) showSnack(context, e.detail);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final doc = _doc!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete document?'),
        content: Text('"${doc.title}" will be permanently deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(apiProvider).deleteDocument(doc.uuid);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isComplianceLocked) {
        _showComplianceDialog();
      } else {
        if (e.isForbidden) _recordDenied('delete');
        showSnack(context, e.detail);
      }
    }
  }

  void _showComplianceDialog() {
    final doc = _doc!;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: const Text('Under retention'),
        content: Text(
          'This document is in compliance mode'
          '${doc.retentionUntil != null ? ' until ${formatDate(doc.retentionUntil)}' : ''} '
          'and cannot be deleted or have its file replaced.\n\n'
          'You can still upload a new version, edit metadata, or archive it '
          'to get it out of the default lists.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
          if (!doc.archived)
            FilledButton.tonal(
              onPressed: () {
                Navigator.pop(context);
                _toggleArchive();
              },
              child: const Text('Archive instead'),
            ),
        ],
      ),
    );
  }

  Future<void> _downloadAndOpen(DocumentVersion v, {bool asPdf = false}) async {
    final doc = _doc!;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiProvider);
      final bytes = asPdf
          ? await api.downloadVersionPdf(doc.uuid, v.number)
          : await api.downloadVersion(doc.uuid, v.number);
      final dir = await getTemporaryDirectory();
      var safeName = v.originalFilename.isNotEmpty
          ? v.originalFilename.replaceAll(RegExp(r'[/\\]'), '_')
          : 'document';
      if (asPdf) safeName = pdfFilename(safeName);
      final file = File('${dir.path}/dms/${doc.uuid}/v${v.number}/$safeName');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      final opened = await openExternally(file.path);
      if (mounted && !opened) {
        showSnack(context, 'Saved to ${file.path}');
      }
    } on ApiException catch (e) {
      if (e.isForbidden) _recordDenied('download');
      if (mounted) showSnack(context, e.detail);
    } catch (e) {
      if (mounted) showSnack(context, 'Download failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Watch = notified on any mutation (notifications hand-off §2); the
  /// toggle is optimistic, the notifier reverts on failure.
  Future<void> _toggleWatch() async {
    try {
      final on =
          await ref.read(watchesProvider.notifier).toggleDocument(_doc!.uuid);
      if (mounted) {
        showSnack(
          context,
          on
              ? 'Watching — you will be notified about changes.'
              : 'No longer watching this document.',
        );
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    }
  }

  void _recordDenied(String action) {
    final doc = _doc;
    if (doc != null) {
      ref.read(deniedActionsProvider.notifier).deny(doc.documentType, action);
    }
  }

  Future<void> _editDocument() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EditDocumentScreen(document: _doc!)),
    );
    if (changed == true) _load();
  }

  Future<MultipartFile?> _pickMultipart() async {
    final result = await FilePicker.pickFiles(withData: false);
    final f = result?.files.firstOrNull;
    if (f == null) return null;
    if (f.path != null) {
      return MultipartFile.fromFileSync(f.path!, filename: f.name);
    }
    final bytes = f.bytes;
    if (bytes == null) return null;
    return MultipartFile.fromBytes(bytes, filename: f.name);
  }

  Future<void> _uploadNewVersion({
    MultipartFile? file,
    bool force = false,
  }) async {
    final picked = file ?? await _pickMultipart();
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      // Whether the version needs a release is the server's call — read it
      // off the response, never compute it client-side (hand-off §3).
      final v = await ref
          .read(apiProvider)
          .uploadVersion(_doc!.uuid, picked, force: force);
      if (mounted) {
        showSnack(
          context,
          v.isPending
              ? 'Version ${v.number} uploaded — awaiting release.'
              : 'New version uploaded.',
        );
      }
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isDuplicateFile) {
        _showVersionDuplicateDialog(e, picked);
      } else {
        if (e.isForbidden) _recordDenied('upload_version');
        showSnack(context, e.detail);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Same bytes exist already; a retry must re-read the file since a
  /// MultipartFile stream can only be consumed once.
  void _showVersionDuplicateDialog(ApiException e, MultipartFile sent) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.copy_all_outlined),
        title: const Text('Identical file already exists'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('The same bytes are already stored in:'),
            const SizedBox(height: 8),
            for (final uuid in e.duplicateOf)
              TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(
                  uuid,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.of(this.context).push(
                    MaterialPageRoute(
                      builder: (_) => DocumentDetailScreen(uuid: uuid),
                    ),
                  );
                },
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () {
              Navigator.pop(context);
              _uploadNewVersion(file: sent.clone(), force: true);
            },
            child: const Text('Upload anyway'),
          ),
        ],
      ),
    );
  }

  static bool get _isDesktop =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  /// Hide a version ("wrong upload") with an optional reason (M4).
  Future<void> _hideVersion(DocumentVersion v) async {
    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hide version ${v.number}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The version stays stored but is struck through in the '
              'timeline and no longer counts as "the document".',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'e.g. wrong upload',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hide version'),
          ),
        ],
      ),
    );
    final reason = reasonCtrl.text.trim();
    reasonCtrl.dispose();
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(apiProvider)
          .hideVersion(
            _doc!.uuid,
            v.number,
            reason: reason.isEmpty ? null : reason,
          );
      await _load();
    } on ApiException catch (e) {
      // e.g. "cannot hide the only visible version"
      if (mounted) showSnack(context, e.detail);
    }
  }

  Future<void> _unhideVersion(DocumentVersion v) async {
    try {
      await ref.read(apiProvider).unhideVersion(_doc!.uuid, v.number);
      await _load();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    }
  }

  /// Release a pending version (approvals hand-off §4).
  Future<void> _releaseVersion(DocumentVersion v) async {
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).releaseVersion(_doc!.uuid, v.number);
      if (mounted) showSnack(context, 'Version ${v.number} released.');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 400) {
        // "not pending release" — someone was faster; just catch up (§7).
        await _load();
      } else if (e.isApprovalRequired) {
        setState(() => _fourEyesBlocked.add(v.number));
        showSnack(
          context,
          'Four-eyes approval: another user must release your own upload.',
        );
      } else {
        if (e.isForbidden) _recordDenied('release_version');
        showSnack(context, e.detail);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reExtract(DocumentVersion v) async {
    try {
      await ref.read(apiProvider).reExtract(_doc!.uuid, v.number);
      if (mounted) showSnack(context, 'Re-extraction queued.');
      await _load(); // status back to pending → polling resumes
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    }
  }

  /// Comments changed → the timeline changed too; refresh it quietly.
  Future<void> _refreshEvents() async {
    try {
      final events = await ref.read(apiProvider).timeline(widget.uuid);
      if (mounted) setState(() => _events = events);
    } on ApiException {
      // keep the current timeline
    }
  }

  Future<bool> _postComment(String body) async {
    try {
      final c = await ref.read(apiProvider).postComment(_doc!.uuid, body);
      if (!mounted) return true;
      setState(() => _comments = [...?_comments, c]);
      _refreshEvents();
      return true;
    } on ApiException catch (e) {
      // §5 graceful degradation: a 403 disables composing for this type.
      if (e.isForbidden) _recordDenied('comment');
      if (mounted) showSnack(context, e.detail);
      return false;
    }
  }

  Future<bool> _editComment(DocumentComment c, String body) async {
    try {
      final updated =
          await ref.read(apiProvider).patchComment(_doc!.uuid, c.id, body);
      if (!mounted) return true;
      setState(() => _comments = [
            for (final x in _comments ?? const <DocumentComment>[])
              x.id == c.id ? updated : x,
          ]);
      _refreshEvents();
      return true;
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
      return false;
    }
  }

  /// Soft delete server-side, but irreversible from the client (no undelete).
  Future<void> _deleteComment(DocumentComment c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete comment?'),
        content: const Text(
          'The comment disappears for everyone. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(apiProvider).deleteComment(_doc!.uuid, c.id);
    } on ApiException catch (e) {
      // 404 = already gone (deleted elsewhere) — dropping the row is right
      // either way.
      if (e.statusCode != 404) {
        if (mounted) showSnack(context, e.detail);
        return;
      }
    }
    if (!mounted) return;
    setState(() => _comments =
        [...?_comments]..removeWhere((x) => x.id == c.id));
    _refreshEvents();
  }

  /// Change the document type (409s in compliance mode; not offered there).
  Future<void> _changeType() async {
    final doc = _doc!;
    final types =
        ref.read(documentTypesProvider).value ?? const <DocumentType>[];
    String? selected;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change document type'),
        content: StatefulBuilder(
          builder: (context, setState) => DropdownButtonFormField<String>(
            initialValue: selected,
            decoration: const InputDecoration(
              labelText: 'New type',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final t in types.where(
                (t) => t.isActive && t.slug != doc.documentType,
              ))
                DropdownMenuItem(
                  value: t.slug,
                  child: Text('${'    ' * t.depth}${t.name}'),
                ),
            ],
            onChanged: (v) => setState(() => selected = v),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Change type'),
          ),
        ],
      ),
    );
    if (confirmed != true || selected == null || !mounted) return;
    try {
      await ref.read(apiProvider).changeType(doc.uuid, selected!);
      if (mounted) showSnack(context, 'Type changed.');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isComplianceLocked) {
        _showComplianceDialog();
      } else if (e.isInvalidMetadata) {
        showSnack(
          context,
          '${e.detail} — adjust the metadata first, then change the type.',
        );
      } else {
        if (e.isForbidden) _recordDenied('edit_metadata');
        showSnack(context, e.detail);
      }
    }
  }

  /// M3 round-trip editing: download, open externally, watch for changes.
  Future<void> _openAndEdit(DocumentVersion v) async {
    setState(() => _busy = true);
    try {
      await ref.read(editSessionsProvider.notifier).start(_doc!, v);
      if (mounted) {
        showSnack(
          context,
          'Opened ${v.originalFilename} — watching for changes.',
        );
      }
    } on ApiException catch (e) {
      if (e.isForbidden) _recordDenied('download');
      if (mounted) showSnack(context, e.detail);
    } catch (e) {
      if (mounted) showSnack(context, 'Could not open the file: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editUploadNewVersion() async {
    try {
      await ref
          .read(editSessionsProvider.notifier)
          .uploadAsNewVersion(_doc!.uuid);
      if (mounted) showSnack(context, 'Uploaded as new version.');
      await _load();
    } on ApiException catch (e) {
      if (e.isForbidden) _recordDenied('upload_version');
      if (mounted) showSnack(context, e.detail);
    } catch (e) {
      if (mounted) showSnack(context, 'Upload failed: $e');
    }
  }

  Future<void> _editReplaceFile() async {
    try {
      await ref.read(editSessionsProvider.notifier).replaceFile(_doc!.uuid);
      if (mounted) showSnack(context, 'File replaced.');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isComplianceLocked) {
        _showComplianceDialog();
      } else {
        if (e.isForbidden) _recordDenied('upload_version');
        showSnack(context, e.detail);
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Upload failed: $e');
    }
  }

  /// Replace bytes in place — never offered in compliance mode (spec §3).
  Future<void> _replaceFile(DocumentVersion v) async {
    final picked = await _pickMultipart();
    if (picked == null || !mounted) return;
    // §7 "replace resets release": warn when approvals plausibly apply. The
    // effective mode is resolved client-side and only feeds this warning —
    // the response's approval_status is what we act on.
    final approvalGated = effectiveApprovalMode(
          ref.read(documentTypesBySlugProvider),
          _doc!.documentType,
        ) !=
        'none';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Replace file of version ${v.number}?'),
        content: Text(
          'The stored bytes will be overwritten in place. To keep history, '
          'upload a new version instead.'
          '${approvalGated && !v.isPending ? '\n\nThis type requires release '
              'approval: the replaced version drops back to "awaiting '
              'release", and the document reverts to the previous released '
              'content until it is released again.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final replaced = await ref
          .read(apiProvider)
          .replaceVersionFile(_doc!.uuid, v.number, picked);
      if (mounted) {
        showSnack(
          context,
          replaced.isPending
              ? 'File replaced — version ${replaced.number} awaits release; '
                  'the document shows the previous released content until then.'
              : 'File replaced.',
        );
      }
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isComplianceLocked) {
        _showComplianceDialog();
      } else {
        if (e.isForbidden) _recordDenied('upload_version');
        showSnack(context, e.detail);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: ErrorRetry(error: _error!, onRetry: _load),
      );
    }
    if (doc == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final current = doc.currentVersion;
    final bySlug = ref.watch(documentTypesBySlugProvider);
    final typeName = bySlug[doc.documentType]?.name ?? doc.documentType;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    ref.watch(deniedActionsProvider); // rebuild when an action gets denied
    final denied = ref.watch(deniedActionsProvider.notifier);
    final canEdit = !denied.isDenied(doc.documentType, 'edit_metadata');
    final canUpload = !denied.isDenied(doc.documentType, 'upload_version');
    // Optimistic like the rest of §5: shown until a plain 403 denies it.
    final canRelease = !denied.isDenied(doc.documentType, 'release_version');
    final pending = doc.latestPendingVersion;
    // No "may I comment?" flag exists — show the composer optimistically and
    // drop it for this type after a 403 (hand-off §5).
    final canComment = !denied.isDenied(doc.documentType, 'comment');
    final watching = ref.watch(watchesProvider).documents.contains(doc.uuid);
    final editSession = ref.watch(editSessionsProvider)[doc.uuid];

    final infoColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (editSession != null) ...[
          _EditSessionBanner(
            session: editSession,
            canUpload: canUpload,
            approvalGated:
                effectiveApprovalMode(bySlug, doc.documentType) != 'none',
            onUploadNewVersion: _editUploadNewVersion,
            onReplaceFile: _editReplaceFile,
            onStop: () =>
                ref.read(editSessionsProvider.notifier).stop(doc.uuid),
          ),
          const SizedBox(height: 12),
        ],
        if (pending != null) ...[
          _PendingReleaseBanner(
            version: pending,
            canRelease: canRelease,
            fourEyesBlocked: _fourEyesBlocked.contains(pending.number),
            noReleasedContent: current == null,
            onRelease: _busy ? null : () => _releaseVersion(pending),
          ),
          const SizedBox(height: 12),
        ],
        _MetadataCard(doc: doc, typeName: typeName, bySlug: bySlug),
        const SizedBox(height: 12),
        _VersionsCard(
          doc: doc,
          onDownload: _busy ? null : _downloadAndOpen,
          onDownloadPdf:
              _busy ? null : (v) => _downloadAndOpen(v, asPdf: true),
          onOpenEdit: (_busy || !_isDesktop) ? null : _openAndEdit,
          onUploadVersion: (_busy || !canUpload)
              ? null
              : () => _uploadNewVersion(),
          // Replace-in-place is never offered in compliance mode (§3).
          onReplaceFile: (_busy || doc.inComplianceMode || !canUpload)
              ? null
              : _replaceFile,
          onHide: (_busy || !canUpload) ? null : _hideVersion,
          onUnhide: (_busy || !canUpload) ? null : _unhideVersion,
          onReExtract: (_busy || !canUpload) ? null : _reExtract,
          onRelease: (_busy || !canRelease) ? null : _releaseVersion,
          fourEyesBlocked: _fourEyesBlocked,
        ),
        const SizedBox(height: 12),
        _CommentsCard(
          comments: _comments,
          canCompose: canComment,
          onPost: _postComment,
          onEdit: _editComment,
          onDelete: _deleteComment,
          // §3: pass the document so can_view reflects *this* document.
          queryMentions: (q) => ref
              .read(apiProvider)
              .userSuggestions(search: q, documentUuid: doc.uuid, limit: 8),
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Timeline',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                if (_events == null)
                  const Text('Timeline not available.')
                else
                  DocumentTimeline(events: _events!),
              ],
            ),
          ),
        ),
      ],
    );

    // PDFs (and odt/docx via server-side conversion) render in-app with a
    // real text layer; everything else uses the server preview images.
    // Preview the released content; if none exists (only-released version
    // replaced, §7), fall back to the pending proposal — its per-version
    // preview is open to anyone with `view` (§5).
    final previewVersion = current ?? pending;
    final preview = previewVersion == null
        ? const SizedBox.shrink()
        : (isPdfMime(previewVersion.mimeType) ||
                canDownloadAsPdf(previewVersion.mimeType))
        ? _PdfPreview(
            api: ref.read(apiProvider),
            uuid: doc.uuid,
            version: previewVersion,
          )
        : _PreviewPager(
            api: ref.read(apiProvider),
            uuid: doc.uuid,
            version: previewVersion,
          );

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Flexible(child: Text(doc.title, overflow: TextOverflow.ellipsis)),
            if (doc.inComplianceMode)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: ComplianceBadge(retentionUntil: doc.retentionUntil),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: watching ? 'Stop watching' : 'Watch for changes',
            icon: Icon(
              watching
                  ? Icons.notifications_active
                  : Icons.notifications_none_outlined,
            ),
            onPressed: _toggleWatch,
          ),
          if (canEdit)
            IconButton(
              tooltip: 'Edit metadata',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _busy ? null : _editDocument,
            ),
          if (current != null)
            IconButton(
              tooltip: 'Download & open',
              icon: const Icon(Icons.open_in_new),
              onPressed: _busy ? null : () => _downloadAndOpen(current),
            ),
          if (current != null && canDownloadAsPdf(current.mimeType))
            IconButton(
              tooltip: 'Download as PDF',
              icon: const Icon(Icons.picture_as_pdf_outlined),
              onPressed:
                  _busy ? null : () => _downloadAndOpen(current, asPdf: true),
            ),
          IconButton(
            tooltip: doc.archived ? 'Unarchive' : 'Archive',
            icon: Icon(
              doc.archived
                  ? Icons.unarchive_outlined
                  : Icons.inventory_2_outlined,
            ),
            onPressed: _busy ? null : _toggleArchive,
          ),
          // In compliance mode the server 409s deletes — don't offer the
          // button; the lock badge explains why.
          if (!doc.inComplianceMode)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: _busy ? null : _delete,
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          if (!doc.inComplianceMode && canEdit)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'change_type') _changeType();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'change_type',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.swap_horiz),
                    title: Text('Change type'),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: preview,
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
                    child: infoColumn,
                  ),
                ),
              ],
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (previewVersion != null)
                    SizedBox(height: 420, child: preview),
                  const SizedBox(height: 12),
                  infoColumn,
                ],
              ),
            ),
    );
  }
}

class _MetadataCard extends StatelessWidget {
  final Document doc;
  final String typeName;
  final Map<String, DocumentType> bySlug;

  const _MetadataCard({
    required this.doc,
    required this.typeName,
    required this.bySlug,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fieldDefs = {
      for (final f in mergedMetadataFields(bySlug, doc.documentType)) f.key: f,
    };
    final extracting = doc.versions.any(
      (v) =>
          !v.isHidden &&
          (v.extractionStatus == ExtractionStatus.pending ||
              v.extractionStatus == ExtractionStatus.running),
    );

    Widget row(String label, Widget value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: value),
        ],
      ),
    );

    Widget textRow(String label, String value) =>
        row(label, Text(value, style: theme.textTheme.bodyMedium));

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Details', style: theme.textTheme.titleMedium),
                ),
                if (extracting)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'processing…',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            textRow('Type', typeName),
            textRow('Document date', formatDate(doc.documentDate)),
            textRow('Added', formatDateTime(doc.dateAdded)),
            textRow('Added by', doc.addedBy),
            if (doc.retentionUntil != null)
              textRow('Retention until', formatDate(doc.retentionUntil)),
            if (doc.notes?.isNotEmpty ?? false) textRow('Notes', doc.notes!),
            if (doc.metadata.isNotEmpty) ...[
              const Divider(height: 20),
              for (final e in doc.metadata.entries)
                textRow(
                  fieldDefs[e.key]?.label ?? e.key,
                  _formatMetadataValue(fieldDefs[e.key], e.value),
                ),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatMetadataValue(MetadataFieldDef? def, Object? value) {
    if (value == null) return '—';
    switch (def?.fieldType) {
      case FieldType.date:
        return formatDate('$value');
      case FieldType.boolean:
        return value == true ? 'Yes' : 'No';
      case FieldType.monetary:
        return '$value'; // decimal string from the server, shown verbatim
      default:
        return '$value';
    }
  }
}

/// Flat plain-text comments (comments hand-off §5). Edit/delete affordances
/// are driven purely by the server-resolved can_edit/can_delete flags.
class _CommentsCard extends StatefulWidget {
  final List<DocumentComment>? comments; // null = could not be loaded
  final bool canCompose;
  final Future<bool> Function(String body) onPost;
  final Future<bool> Function(DocumentComment comment, String body) onEdit;
  final Future<void> Function(DocumentComment comment) onDelete;
  final Future<List<UserSuggestion>> Function(String query) queryMentions;

  const _CommentsCard({
    required this.comments,
    required this.canCompose,
    required this.onPost,
    required this.onEdit,
    required this.onDelete,
    required this.queryMentions,
  });

  @override
  State<_CommentsCard> createState() => _CommentsCardState();
}

class _CommentsCardState extends State<_CommentsCard> {
  final _composerCtrl = TextEditingController();
  final _editCtrl = TextEditingController();
  int? _editingId;
  bool _sending = false;

  @override
  void dispose() {
    _composerCtrl.dispose();
    _editCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _composerCtrl.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ok = await widget.onPost(body);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (ok) _composerCtrl.clear();
    });
  }

  Future<void> _saveEdit(DocumentComment c) async {
    final body = _editCtrl.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ok = await widget.onEdit(c, body);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (ok) _editingId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final comments = widget.comments;
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              comments == null || comments.isEmpty
                  ? 'Comments'
                  : 'Comments (${comments.length})',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (comments == null)
              Text('Comments not available.', style: muted)
            else if (comments.isEmpty)
              Text('No comments yet.', style: muted)
            else
              // Server order: oldest first, new ones append at the bottom.
              for (final c in comments)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _editingId == c.id ? _editor(c) : _tile(c),
                ),
            if (widget.canCompose) _composer() else ...[
              const SizedBox(height: 4),
              Text(
                'You are not allowed to comment on this document type.',
                style: muted?.copyWith(fontStyle: FontStyle.italic),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tile(DocumentComment c) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: c.author,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text: '  ${formatDateTime(c.createdAt)}',
                    style: muted,
                  ),
                  if (c.isEdited)
                    TextSpan(
                      text: c.editedBy != null && c.editedBy != c.author
                          ? ' · edited by ${c.editedBy}'
                          : ' · edited',
                      style: muted?.copyWith(fontStyle: FontStyle.italic),
                    ),
                ]),
                style: theme.textTheme.bodyMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (c.canEdit)
              IconButton(
                tooltip: 'Edit comment',
                icon: const Icon(Icons.edit_outlined, size: 16),
                visualDensity: VisualDensity.compact,
                onPressed: _sending
                    ? null
                    : () => setState(() {
                          _editingId = c.id;
                          _editCtrl.text = c.body;
                        }),
              ),
            if (c.canDelete)
              IconButton(
                tooltip: 'Delete comment',
                icon: const Icon(Icons.delete_outline, size: 16),
                visualDensity: VisualDensity.compact,
                onPressed: _sending ? null : () => widget.onDelete(c),
              ),
          ],
        ),
        // Untrusted plain text: rendered verbatim, newlines preserved.
        // @username tokens are only styled — the server treats them as text.
        Text.rich(
          _withMentionStyle(
            c.body,
            TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _editor(DocumentComment c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MentionField(
          controller: _editCtrl,
          queryMentions: widget.queryMentions,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed:
                  _sending ? null : () => setState(() => _editingId = null),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: _sending ? null : () => _saveEdit(c),
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _composer() {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: _MentionField(
              controller: _composerCtrl,
              queryMentions: widget.queryMentions,
              enabled: !_sending,
              decoration: const InputDecoration(
                hintText: 'Add a comment…  (@ mentions someone)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: 'Post comment',
            icon: _sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send, size: 18),
            onPressed: _sending ? null : _send,
          ),
        ],
      ),
    );
  }
}

/// Username-shaped tokens (notifications hand-off §3: `. @ + - _` allowed).
final _mentionRe = RegExp(r'@[A-Za-z0-9._@+\-]+');

/// Styles `@username` tokens in a comment body. Purely cosmetic — unknown
/// names are styled too; the server resolves real mentions.
TextSpan _withMentionStyle(String body, TextStyle mentionStyle) {
  final children = <TextSpan>[];
  var last = 0;
  for (final m in _mentionRe.allMatches(body)) {
    if (m.start > last) children.add(TextSpan(text: body.substring(last, m.start)));
    children.add(TextSpan(text: m.group(0), style: mentionStyle));
    last = m.end;
  }
  if (last < body.length) children.add(TextSpan(text: body.substring(last)));
  return TextSpan(children: children);
}

/// Comment input with an @-mention picker (notifications hand-off §3):
/// typing `@…` at the cursor queries the username autocomplete (debounced)
/// and shows suggestions above the field. Users without `view` on the
/// document come back `can_view: false` and are shown struck through — the
/// mention would post as plain text and notify nobody.
class _MentionField extends StatefulWidget {
  final TextEditingController controller;
  final Future<List<UserSuggestion>> Function(String query) queryMentions;
  final InputDecoration decoration;
  final bool enabled;
  final bool autofocus;

  const _MentionField({
    required this.controller,
    required this.queryMentions,
    required this.decoration,
    this.enabled = true,
    this.autofocus = false,
  });

  @override
  State<_MentionField> createState() => _MentionFieldState();
}

class _MentionFieldState extends State<_MentionField> {
  static final _tokenRe = RegExp(r'(?:^|\s)@([A-Za-z0-9._@+\-]*)$');

  List<UserSuggestion> _suggestions = const [];
  int _tokenStart = -1; // index of the '@' being completed
  Timer? _debounce;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged() {
    final value = widget.controller.value;
    final cursor = value.selection.baseOffset;
    if (!value.selection.isCollapsed || cursor < 0) {
      _clear();
      return;
    }
    final m = _tokenRe.firstMatch(value.text.substring(0, cursor));
    if (m == null) {
      _clear();
      return;
    }
    _tokenStart = cursor - m.group(1)!.length - 1;
    final query = m.group(1)!;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final gen = ++_generation;
      try {
        final users = await widget.queryMentions(query);
        // Drop stale responses and responses for an abandoned token.
        if (mounted && gen == _generation && _tokenStart >= 0) {
          setState(() => _suggestions = users);
        }
      } on ApiException {
        // Autocomplete is best-effort; typing the name still works.
      }
    });
  }

  void _clear() {
    _debounce?.cancel();
    _generation++;
    _tokenStart = -1;
    if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
  }

  void _insert(UserSuggestion u) {
    final value = widget.controller.value;
    final cursor = value.selection.baseOffset;
    if (_tokenStart < 0 || cursor < _tokenStart) return;
    final replaced = '@${u.username} ';
    widget.controller.value = TextEditingValue(
      text: value.text.replaceRange(_tokenStart, cursor, replaced),
      selection:
          TextSelection.collapsed(offset: _tokenStart + replaced.length),
    );
    _clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_suggestions.isNotEmpty)
          Card(
            margin: const EdgeInsets.only(bottom: 4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final u in _suggestions)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.alternate_email, size: 16),
                      title: Text(
                        u.username,
                        style: u.canView
                            ? null
                            : TextStyle(
                                decoration: TextDecoration.lineThrough,
                                color: scheme.onSurfaceVariant,
                              ),
                      ),
                      subtitle: u.canView
                          ? null
                          : Text(
                              'Cannot view this document — will not be notified',
                              style: theme.textTheme.labelSmall,
                            ),
                      onTap: () => _insert(u),
                    ),
                ],
              ),
            ),
          ),
        TextField(
          controller: widget.controller,
          enabled: widget.enabled,
          autofocus: widget.autofocus,
          minLines: 1,
          maxLines: 6,
          inputFormatters: [LengthLimitingTextInputFormatter(10000)],
          decoration: widget.decoration,
        ),
      ],
    );
  }
}

/// Round-trip editing status card: shows the watching/changed/uploading
/// state of an [EditSession] and the compliance-aware upload choices.
class _EditSessionBanner extends StatelessWidget {
  final EditSession session;
  final bool canUpload;
  // Approvals may apply to this type (client-side resolved, warning only).
  final bool approvalGated;
  final VoidCallback onUploadNewVersion;
  final VoidCallback onReplaceFile;
  final VoidCallback onStop;

  const _EditSessionBanner({
    required this.session,
    required this.canUpload,
    required this.approvalGated,
    required this.onUploadNewVersion,
    required this.onReplaceFile,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final changed = session.phase == EditPhase.changed;
    final uploading = session.phase == EditPhase.uploading;

    return Card(
      margin: EdgeInsets.zero,
      color: changed ? scheme.tertiaryContainer : scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (uploading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    changed
                        ? Icons.upload_file_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    uploading
                        ? 'Uploading ${session.fileName}…'
                        : changed
                        ? '${session.fileName} changed on disk'
                        : 'Editing v${session.versionNumber} — watching '
                              '${session.fileName} for changes',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Stop watching',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: uploading ? null : onStop,
                ),
              ],
            ),
            if (changed) ...[
              const SizedBox(height: 8),
              Text(
                (session.compliance
                        ? 'This document is under retention: the change can only '
                              'be uploaded as version ${session.versionNumber + 1}.'
                        : 'Upload the change as version '
                              '${session.versionNumber + 1}, or overwrite the file '
                              'of version ${session.versionNumber} in place.') +
                    (approvalGated
                        ? ' This type requires release approval — the result '
                              'awaits release before it becomes the document.'
                        : ''),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: canUpload ? onUploadNewVersion : null,
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: Text('Upload as v${session.versionNumber + 1}'),
                  ),
                  if (!session.compliance)
                    OutlinedButton.icon(
                      onPressed: canUpload ? onReplaceFile : null,
                      icon: const Icon(Icons.find_replace, size: 18),
                      label: Text('Replace file in v${session.versionNumber}'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Slim banner while a version awaits release (approvals hand-off §9):
/// reviewers see it without scrolling; the timeline below holds the
/// proposed diff. Release is optimistic — a plain 403 hides the button for
/// the type, the four-eyes 403 disables it with a hint.
class _PendingReleaseBanner extends StatelessWidget {
  final DocumentVersion version;
  final bool canRelease;
  final bool fourEyesBlocked;
  final bool noReleasedContent;
  final VoidCallback? onRelease;

  const _PendingReleaseBanner({
    required this.version,
    required this.canRelease,
    required this.fourEyesBlocked,
    required this.noReleasedContent,
    required this.onRelease,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    return Card(
      margin: EdgeInsets.zero,
      color: dark
          ? Colors.amber.shade900.withValues(alpha: .25)
          : Colors.amber.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.pending_actions,
                    size: 18,
                    color: dark ? Colors.amber.shade200 : Colors.amber.shade900),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Version ${version.number} awaiting release — uploaded by '
                    '${version.uploadedBy} · ${formatDateTime(version.uploadedAt)}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              noReleasedContent
                  ? 'No released version exists right now — the document has '
                      'no effective content until this version is released.'
                  : 'The document still shows the previous released content. '
                      'Review the proposed changes in the timeline below.',
              style: theme.textTheme.bodySmall,
            ),
            if (canRelease) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: fourEyesBlocked ? null : onRelease,
                    icon: const Icon(Icons.task_alt, size: 18),
                    label: Text('Release v${version.number}'),
                  ),
                  if (fourEyesBlocked)
                    Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: Text(
                        'Four-eyes: another user must release this.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VersionsCard extends StatelessWidget {
  final Document doc;
  final void Function(DocumentVersion)? onDownload;
  final void Function(DocumentVersion)? onDownloadPdf;
  final void Function(DocumentVersion)? onOpenEdit;
  final VoidCallback? onUploadVersion;
  final void Function(DocumentVersion)? onReplaceFile;
  final void Function(DocumentVersion)? onHide;
  final void Function(DocumentVersion)? onUnhide;
  final void Function(DocumentVersion)? onReExtract;
  final void Function(DocumentVersion)? onRelease;
  final Set<int> fourEyesBlocked;

  const _VersionsCard({
    required this.doc,
    required this.onDownload,
    required this.onDownloadPdf,
    required this.onOpenEdit,
    required this.onUploadVersion,
    required this.onReplaceFile,
    required this.onHide,
    required this.onUnhide,
    required this.onReExtract,
    required this.onRelease,
    required this.fourEyesBlocked,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final versions = [...doc.versions]
      ..sort((a, b) => b.number.compareTo(a.number));
    final currentNumber = doc.currentVersion?.number;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Versions', style: theme.textTheme.titleMedium),
                ),
                if (onUploadVersion != null)
                  FilledButton.tonalIcon(
                    onPressed: onUploadVersion,
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: const Text('New version'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (final v in versions)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  mimeIcon(v.mimeType),
                  color: v.isHidden
                      ? theme.colorScheme.outline
                      : theme.colorScheme.primary,
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        'v${v.number} · ${v.originalFilename}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          decoration:
                              v.isHidden ? TextDecoration.lineThrough : null,
                          color: v.isHidden ? theme.colorScheme.outline : null,
                          fontWeight: v.number == currentNumber
                              ? FontWeight.w600
                              : null,
                        ),
                      ),
                    ),
                    if (!v.isHidden && v.isPending)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: PendingReleaseBadge(),
                      ),
                  ],
                ),
                subtitle: Text(
                  v.isHidden
                      ? 'Hidden${v.hiddenBy != null ? ' by ${v.hiddenBy}' : ''}'
                            '${(v.hiddenReason?.isNotEmpty ?? false) ? ': ${v.hiddenReason}' : ''}'
                      : '${formatBytes(v.size)} · ${v.uploadedBy}'
                            ' · ${formatDateTime(v.uploadedAt)}'
                            // Explicit releases only — auto-released versions
                            // carry no released_by (§5).
                            '${v.releasedBy != null ? ' · released by ${v.releasedBy}' : ''}'
                            '${v.extractionStatus == ExtractionStatus.failed ? ' · OCR failed' : ''}',
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!v.isHidden && v.isPending && onRelease != null)
                      IconButton(
                        tooltip: fourEyesBlocked.contains(v.number)
                            ? 'Four-eyes: another user must release this'
                            : 'Release this version',
                        icon: const Icon(Icons.task_alt, size: 20),
                        onPressed: fourEyesBlocked.contains(v.number)
                            ? null
                            : () => onRelease!(v),
                      ),
                    if (!v.isHidden) ...[
                      if (onOpenEdit != null)
                        IconButton(
                          tooltip: 'Open & edit (watch for changes)',
                          icon: const Icon(Icons.edit_document, size: 20),
                          onPressed: () => onOpenEdit!(v),
                        ),
                      if (onReplaceFile != null)
                        IconButton(
                          tooltip: 'Replace file in place',
                          icon: const Icon(Icons.find_replace, size: 20),
                          onPressed: () => onReplaceFile!(v),
                        ),
                      IconButton(
                        tooltip: 'Download & open',
                        icon: const Icon(Icons.file_download_outlined),
                        onPressed: onDownload != null
                            ? () => onDownload!(v)
                            : null,
                      ),
                      if (canDownloadAsPdf(v.mimeType))
                        IconButton(
                          tooltip: 'Download as PDF',
                          icon: const Icon(Icons.picture_as_pdf_outlined),
                          onPressed: onDownloadPdf != null
                              ? () => onDownloadPdf!(v)
                              : null,
                        ),
                    ],
                    if ((v.consoleUrl != null && v.consoleUrl!.isNotEmpty) ||
                        (v.isHidden
                            ? onUnhide != null
                            : (onHide != null || onReExtract != null)))
                      PopupMenuButton<String>(
                        onSelected: (action) => switch (action) {
                          'console' => launchUrl(
                            Uri.parse(v.consoleUrl!),
                            mode: LaunchMode.externalApplication,
                          ),
                          'hide' => onHide!(v),
                          'unhide' => onUnhide!(v),
                          're-extract' => onReExtract!(v),
                          _ => null,
                        },
                        itemBuilder: (context) => [
                          if (v.isHidden)
                            const PopupMenuItem(
                              value: 'unhide',
                              child: ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.visibility_outlined),
                                title: Text('Unhide'),
                              ),
                            )
                          else ...[
                            if (onHide != null)
                              const PopupMenuItem(
                                value: 'hide',
                                child: ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.visibility_off_outlined),
                                  title: Text('Hide (wrong upload)…'),
                                ),
                              ),
                            if (onReExtract != null)
                              const PopupMenuItem(
                                value: 're-extract',
                                child: ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.refresh),
                                  title: Text('Re-run text extraction'),
                                ),
                              ),
                          ],
                          if (v.consoleUrl != null && v.consoleUrl!.isNotEmpty)
                            const PopupMenuItem(
                              value: 'console',
                              child: ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.open_in_new),
                                title: Text('Open in console'),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// In-app pdfium viewer (pdfrx) with a real text layer: select, copy,
/// zoom. Native PDFs load their original bytes; odt/docx go through the
/// server's on-the-fly PDF conversion. If the fetch fails we fall back to
/// the server-rendered preview images.
class _PdfPreview extends StatefulWidget {
  final ApiClient api;
  final String uuid;
  final DocumentVersion version;

  const _PdfPreview({
    required this.api,
    required this.uuid,
    required this.version,
  });

  @override
  State<_PdfPreview> createState() => _PdfPreviewState();
}

class _PdfPreviewState extends State<_PdfPreview> {
  final _controller = PdfViewerController();
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_PdfPreview old) {
    super.didUpdateWidget(old);
    if (old.uuid != widget.uuid || old.version.number != widget.version.number) {
      setState(() {
        _bytes = null;
        _failed = false;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final v = widget.version;
    try {
      final bytes = isPdfMime(v.mimeType)
          ? await widget.api.downloadVersion(widget.uuid, v.number)
          : await widget.api.downloadVersionPdf(widget.uuid, v.number);
      if (!mounted) return;
      setState(() => _bytes = bytes);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return _PreviewPager(
        api: widget.api,
        uuid: widget.uuid,
        version: widget.version,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: _bytes == null
          ? const Center(child: CircularProgressIndicator())
          : PdfViewer.data(
              _bytes!,
              sourceName: '${widget.uuid}/v${widget.version.number}',
              controller: _controller,
              params: PdfViewerParams(
                backgroundColor: scheme.surfaceContainerHighest,
                // pdfrx defaults to 0.2 (a fifth of the normal Flutter
                // scroll delta) — far too sluggish on desktop.
                scrollByMouseWheel: 1.0,
                viewerOverlayBuilder: (context, size, handleLinkTap) => [
                  PdfViewerScrollThumb(controller: _controller),
                ],
              ),
            ),
    );
  }
}

/// Page-by-page viewer over the server-rendered preview endpoint.
/// Non-previewable formats (404) fall back to a mime icon + hint.
class _PreviewPager extends StatefulWidget {
  final ApiClient api;
  final String uuid;
  final DocumentVersion version;

  const _PreviewPager({
    required this.api,
    required this.uuid,
    required this.version,
  });

  @override
  State<_PreviewPager> createState() => _PreviewPagerState();
}

class _PreviewPagerState extends State<_PreviewPager> {
  late final PageController _controller;
  int _page = 1;

  int get _pageCount => widget.version.pageCount ?? 1;

  @override
  void initState() {
    super.initState();
    _controller = PageController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: PageView.builder(
              controller: _controller,
              itemCount: _pageCount,
              onPageChanged: (i) => setState(() => _page = i + 1),
              itemBuilder: (context, i) => InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: Image.network(
                    widget.api.versionPreviewUrl(
                      widget.uuid,
                      widget.version.number,
                      page: i + 1,
                    ),
                    headers: widget.api.authHeaders,
                    fit: BoxFit.contain,
                    // Lazy pages may take ~1s to render server-side.
                    loadingBuilder: (context, child, progress) =>
                        progress == null
                        ? child
                        : const Center(child: CircularProgressIndicator()),
                    errorBuilder: (context, e, st) => Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          mimeIcon(widget.version.mimeType),
                          size: 64,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No preview for this format.\nUse "Download & open".',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_pageCount > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _page > 1
                      ? () => _controller.previousPage(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                        )
                      : null,
                ),
                Text('$_page / $_pageCount'),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _page < _pageCount
                      ? () => _controller.nextPage(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                        )
                      : null,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
