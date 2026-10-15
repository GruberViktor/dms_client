import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The last `luvi-dms://` link the OS handed us (email, chat, `xdg-open`),
/// until `HomeScreen` consumes it. Kept alive from app start so a link that
/// arrives on the login screen is applied once the user is logged in.
/// Targets: `luvi-dms://doc/<uuid>` (document detail) and `luvi-dms://<tab>`
/// with tab = documents | indexes | inbox | notifications | admin.
class PendingDeepLink extends Notifier<Uri?> {
  @override
  Uri? build() {
    // The stream also delivers the link the app was cold-started with.
    final sub = AppLinks().uriLinkStream.listen((uri) => state = uri);
    ref.onDispose(sub.cancel);
    return null;
  }

  void clear() => state = null;
}

final pendingDeepLinkProvider =
    NotifierProvider<PendingDeepLink, Uri?>(PendingDeepLink.new);
