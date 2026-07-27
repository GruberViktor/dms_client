import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'src/screens/home_screen.dart';
import 'src/screens/login_screen.dart';
import 'src/state/session.dart';
import 'src/theme/adwaita_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The UI is German-only, so pin intl's default locale once instead of
  // threading a locale through every DateFormat/NumberFormat call site.
  // The top-level DateFormats in util/format.dart are lazy, so they pick
  // this up as long as it is set before the first frame.
  Intl.defaultLocale = 'de_DE';
  await initializeDateFormatting('de_DE');
  runApp(const ProviderScope(child: DmsApp()));
}

/// Stable key for the root Navigator so the mouse-button Listener in the
/// MaterialApp `builder` can pop routes. The builder's context sits *above*
/// the Navigator, so Navigator.of(context) can't be used there.
final _rootNavigatorKey = GlobalKey<NavigatorState>();

class DmsApp extends ConsumerWidget {
  const DmsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    return MaterialApp(
      title: 'LUVI Docs',
      navigatorKey: _rootNavigatorKey,
      locale: const Locale('de', 'DE'),
      supportedLocales: const [Locale('de', 'DE')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // Route mouse back/forward side-buttons to navigation.
      builder: (context, child) => Listener(
        onPointerDown: (event) {
          if (event.buttons & kBackMouseButton != 0) {
            _rootNavigatorKey.currentState?.maybePop();
          } else if (event.buttons & kForwardMouseButton != 0) {
            // Flutter's Navigator is a pure stack with no forward history,
            // so there is nothing to navigate to. Handled here only to keep
            // the button from being treated as an unexpected primary click.
          }
        },
        child: child,
      ),
      theme: adwaitaDarkTheme(),
      darkTheme: adwaitaDarkTheme(),
      themeMode: ThemeMode.dark,
      home: session.restoring
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : session.loggedIn
              ? const HomeScreen()
              : const LoginScreen(),
    );
  }
}
