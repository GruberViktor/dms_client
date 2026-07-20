import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/screens/home_screen.dart';
import 'src/screens/login_screen.dart';
import 'src/state/session.dart';

void main() {
  runApp(const ProviderScope(child: DmsApp()));
}

class DmsApp extends ConsumerWidget {
  const DmsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    return MaterialApp(
      title: 'DMS',
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
