import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import 'session.dart';

/// The caller's watch set, keyed for the two toggle surfaces (document
/// detail app bar, type tree). The list is small — fetched once per session
/// and updated optimistically on toggle (notifications hand-off §2).
class WatchState {
  final bool loaded;
  final Set<String> documents; // uuids
  final Set<String> types; // slugs

  const WatchState({
    this.loaded = false,
    this.documents = const {},
    this.types = const {},
  });

  WatchState copyWith({Set<String>? documents, Set<String>? types}) =>
      WatchState(
        loaded: true,
        documents: documents ?? this.documents,
        types: types ?? this.types,
      );
}

class WatchesNotifier extends Notifier<WatchState> {
  @override
  WatchState build() {
    if (ref.watch(sessionProvider).session == null) return const WatchState();
    Future.microtask(reload);
    return const WatchState();
  }

  Future<void> reload() async {
    try {
      final watches = await ref.read(apiProvider).watches();
      state = WatchState(
        loaded: true,
        documents: {for (final w in watches) ?w.documentUuid},
        types: {for (final w in watches) ?w.documentType},
      );
    } on ApiException {
      // Leave unloaded; toggles still work (PUT/DELETE are idempotent).
    }
  }

  /// Optimistic flip; reverts and rethrows on failure so the caller can snack.
  Future<bool> toggleDocument(String uuid) =>
      _toggle(uuid, state.documents, (s) => state.copyWith(documents: s),
          (on) => ref.read(apiProvider).setDocumentWatch(uuid, on));

  Future<bool> toggleType(String slug) =>
      _toggle(slug, state.types, (s) => state.copyWith(types: s),
          (on) => ref.read(apiProvider).setTypeWatch(slug, on));

  Future<bool> _toggle(
    String key,
    Set<String> current,
    WatchState Function(Set<String>) apply,
    Future<void> Function(bool on) call,
  ) async {
    final on = !current.contains(key);
    final before = state;
    state = apply(on ? {...current, key} : ({...current}..remove(key)));
    try {
      await call(on);
      return on;
    } on ApiException {
      state = before;
      rethrow;
    }
  }
}

final watchesProvider =
    NotifierProvider<WatchesNotifier, WatchState>(WatchesNotifier.new);
