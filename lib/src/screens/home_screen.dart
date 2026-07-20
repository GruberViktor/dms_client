import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/session.dart';
import 'admin/admin_screen.dart';
import 'document_list_screen.dart';
import 'index_browser_screen.dart';
import 'search_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 0;

  Widget _body() => switch (_tab) {
        0 => const DocumentListScreen(),
        1 => const SearchScreen(),
        2 => const IndexListScreen(),
        _ => const AdminScreen(),
      };

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).session;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final isAdmin = session?.user.isSuperuser ?? false;
    final destinations = [
      (icon: Icons.description_outlined, label: 'Documents'),
      (icon: Icons.search, label: 'Search'),
      (icon: Icons.account_tree_outlined, label: 'Indexes'),
      // Admin area is gated on is_superuser (spec §7 M4).
      if (isAdmin)
        (icon: Icons.admin_panel_settings_outlined, label: 'Admin'),
    ];
    if (_tab >= destinations.length) _tab = 0;

    final logoutButton = IconButton(
      tooltip: 'Sign out${session != null ? ' (${session.user.username})' : ''}',
      icon: const Icon(Icons.logout),
      onPressed: () => ref.read(sessionProvider.notifier).logout(),
    );

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
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
                    icon: Icon(d.icon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _body()),
          ],
        ),
      );
    }

    return Scaffold(
      body: _body(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          for (final d in destinations)
            NavigationDestination(icon: Icon(d.icon), label: d.label),
        ],
      ),
    );
  }
}
