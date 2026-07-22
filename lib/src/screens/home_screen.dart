import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/notifications.dart';
import '../state/session.dart';
import 'admin/admin_screen.dart';
import 'document_list_screen.dart';
import 'index_browser_screen.dart';
import 'notifications_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 0;

  // Each tab gets its own nested Navigator so that pushing a detail / browser
  // route stays inside the content area — the rail (or bottom nav) persists
  // instead of being overlaid — and each tab keeps its own navigation stack.
  final Map<int, GlobalKey<NavigatorState>> _navKeys = {};

  GlobalKey<NavigatorState> _navKey(int tab) =>
      _navKeys.putIfAbsent(tab, () => GlobalKey<NavigatorState>());

  Widget _rootFor(int tab) => switch (tab) {
        0 => const DocumentListScreen(),
        1 => const IndexListScreen(),
        2 => const NotificationsScreen(),
        _ => const AdminScreen(),
      };

  Widget _tabNavigator(int tab) => Navigator(
        key: _navKey(tab),
        onGenerateRoute: (settings) =>
            MaterialPageRoute(builder: (_) => _rootFor(tab)),
      );

  void _onDestinationSelected(int i) {
    // Re-tapping the active tab pops it back to its root, matching the usual
    // bottom-nav / rail convention.
    if (i == _tab) {
      _navKey(i).currentState?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _tab = i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).session;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final isAdmin = session?.user.isSuperuser ?? false;
    // No push channel exists — the badge count is polled (~45 s) while
    // logged in (notifications hand-off §1).
    final unread = ref.watch(unreadNotificationsProvider);
    final inboxIcon = Badge.count(
      count: unread,
      isLabelVisible: unread > 0,
      child: const Icon(Icons.notifications_outlined),
    );
    final destinations = [
      // Search lives in the document list itself.
      (icon: const Icon(Icons.description_outlined), label: 'Documents'),
      (icon: const Icon(Icons.account_tree_outlined), label: 'Indexes'),
      (icon: inboxIcon, label: 'Inbox'),
      // Admin area is gated on is_superuser (spec §7 M4).
      if (isAdmin)
        (icon: const Icon(Icons.admin_panel_settings_outlined), label: 'Admin'),
    ];
    if (_tab >= destinations.length) _tab = 0;

    final logoutButton = IconButton(
      tooltip: 'Sign out${session != null ? ' (${session.user.username})' : ''}',
      icon: const Icon(Icons.logout),
      onPressed: () => ref.read(sessionProvider.notifier).logout(),
    );

    final body = IndexedStack(
      index: _tab,
      children: [
        for (var i = 0; i < destinations.length; i++) _tabNavigator(i),
      ],
    );

    // Route the system/back button to the active tab's nested Navigator first,
    // so it pops the pushed detail route rather than exiting the shell.
    final content = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _navKey(_tab).currentState?.maybePop();
      },
      child: body,
    );

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _tab,
              onDestinationSelected: _onDestinationSelected,
              labelType: NavigationRailLabelType.all,
              leading: const SizedBox(height: 8),
              trailing: Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: logoutButton,
                  ),
                ),
              ),
              destinations: [
                for (final d in destinations)
                  NavigationRailDestination(
                    icon: d.icon,
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: content),
          ],
        ),
      );
    }

    return Scaffold(
      body: content,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _onDestinationSelected,
        destinations: [
          for (final d in destinations)
            NavigationDestination(icon: d.icon, label: d.label),
        ],
      ),
    );
  }
}
