import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import 'document_feed.dart';
import 'session.dart';

/// Who else is editing which document, from `document_editing` feed events:
/// uuid → username → expiry. An editor whose notice is not repeated before
/// it expires is dropped (their client closed without a DELETE). Own notices
/// are ignored. A client that connects mid-edit learns about the editor
/// with the next repeat (≤ 30 s).
class DocumentEditors extends Notifier<Map<String, Map<String, DateTime>>> {
  @override
  Map<String, Map<String, DateTime>> build() {
    final me = ref.watch(sessionProvider).session?.user.username;
    ref.listen(documentFeedProvider, (_, next) {
      final e = next.value;
      if (e is! DocumentEditing || e.user == me) return;
      final editors = {...?state[e.uuid]};
      if (e.editing) {
        editors[e.user] = DateTime.now().add(e.expiresIn);
        Timer(e.expiresIn, _dropExpired);
      } else {
        editors.remove(e.user);
      }
      state = {...state, e.uuid: editors}..removeWhere((_, m) => m.isEmpty);
    });
    return {};
  }

  void _dropExpired() {
    if (!ref.mounted) return;
    final now = DateTime.now();
    state = {
      for (final MapEntry(:key, :value) in state.entries)
        key: {...value}..removeWhere((_, expiry) => !expiry.isAfter(now)),
    }..removeWhere((_, m) => m.isEmpty);
  }
}

final documentEditorsProvider =
    NotifierProvider<DocumentEditors, Map<String, Map<String, DateTime>>>(
      DocumentEditors.new,
    );

/// Tells the other clients that this user edits [uuid]: PUT now and every
/// 30 s until [stop] sends DELETE. Best effort — failures are ignored, the
/// next repeat or the server-side expiry covers them.
class EditingAnnouncement {
  final ApiClient _api;
  final String uuid;
  late final Timer _timer;

  EditingAnnouncement(this._api, this.uuid) {
    _send(true);
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _send(true));
  }

  void _send(bool editing) => _api.setEditing(uuid, editing).catchError((_) {});

  void stop() {
    _timer.cancel();
    _send(false);
  }

  /// Stop repeating without a DELETE (session gone: the token is dead, the
  /// notice simply expires on the other clients).
  void cancel() => _timer.cancel();
}
