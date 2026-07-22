import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'session.dart';

/// Unread inbox count, polled at a modest interval — the server has no push
/// channel (notifications hand-off §1/§5); `unread-count/` is the cheap poll
/// target. The inbox screen listens to this and refetches its list when the
/// count changes; mark-read paths update it locally so the badge doesn't lag
/// a poll cycle behind.
class UnreadNotifications extends Notifier<int> {
  Timer? _timer;

  @override
  int build() {
    _timer?.cancel();
    if (ref.watch(sessionProvider).session == null) return 0;
    _timer = Timer.periodic(const Duration(seconds: 45), (_) => refresh());
    ref.onDispose(() => _timer?.cancel());
    Future.microtask(refresh);
    return 0;
  }

  Future<void> refresh() async {
    try {
      final n = await ref.read(apiProvider).unreadNotificationCount();
      if (n != state) state = n;
    } catch (_) {
      // Transient poll failure (or session just dropped) — keep the last
      // count; the next tick will catch up.
    }
  }

  /// Reflect a mark-read done in the UI without waiting for the next poll.
  void setLocal(int n) => state = n < 0 ? 0 : n;
}

final unreadNotificationsProvider =
    NotifierProvider<UnreadNotifications, int>(UnreadNotifications.new);
