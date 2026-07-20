import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Session-scoped graceful degradation (spec §5): there is no
/// "my effective permissions" endpoint, so after a 403 for an action on a
/// document type we disable that action for that type until logout.
class DeniedActions extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};

  static String _key(String typeSlug, String action) => '$typeSlug:$action';

  void deny(String typeSlug, String action) {
    state = {...state, _key(typeSlug, action)};
  }

  bool isDenied(String typeSlug, String action) =>
      state.contains(_key(typeSlug, action));
}

final deniedActionsProvider =
    NotifierProvider<DeniedActions, Set<String>>(DeniedActions.new);
