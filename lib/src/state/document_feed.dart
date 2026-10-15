import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import 'session.dart';

/// Live document feed: one `/events/` connection per session, opened again
/// 5 s after any drop. After a reconnect it first emits
/// [DocumentChange.resync], because the server keeps no history and events
/// sent during the gap are lost. Screens `ref.listen` to it and reload.
final documentFeedProvider = StreamProvider<FeedEvent>((ref) async* {
  final session = ref.watch(sessionProvider).session;
  if (session == null) return;
  var disposed = false;
  ref.onDispose(() => disposed = true);
  var reconnect = false;
  while (!disposed) {
    try {
      final feed = await session.api.documentFeed();
      if (reconnect) yield DocumentChange.resync();
      yield* feed;
    } catch (_) {
      // Dropped, timed out or server unreachable — try again below. A 401
      // already ended the session via onUnauthorized.
    }
    reconnect = true;
    await Future.delayed(const Duration(seconds: 5));
  }
});
