import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/screens/home_screen.dart';
import 'src/screens/login_screen.dart';
import 'src/state/session.dart';

void main() {
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
      title: 'DMS',
      navigatorKey: _rootNavigatorKey,
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E5E4E)),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E5E4E),
          brightness: Brightness.dark,
        ),
      ),
      home: session.restoring
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : session.loggedIn
              ? const HomeScreen()
              : const LoginScreen(),
    );
  }
}
