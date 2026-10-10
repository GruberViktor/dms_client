import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/app_update.dart';
import '../state/deep_links.dart';
import '../state/editors.dart';
import '../state/notifications.dart';
import '../state/session.dart';
import 'admin/admin_screen.dart';
import 'document_detail_screen.dart';
import 'document_list_screen.dart';
import 'inbox_screen.dart';
import 'index_browser_screen.dart';
import 'notifications_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 0;
  bool _updateDismissed = false;
  bool _updating = false;

  Future<void> _installUpdate(String tarball) async {
    setState(() => _updating = true);
    try {
      await installLinuxUpdate(tarball); // exits the app on success
    } catch (e) {
      if (!mounted) return;
      setState(() => _updating = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Update fehlgeschlagen: $e')));
    }
  }

  // Each tab gets its own nested Navigator so that pushing a detail / browser
  // route stays inside the content area — the rail (or bottom nav) persists
  // instead of being overlaid — and each tab keeps its own navigation stack.
  // Keyed by label: the inbox tab appears only after its permission probe,
  // which shifts the indices of the tabs behind it.
  final Map<String, GlobalKey<NavigatorState>> _navKeys = {};

  GlobalKey<NavigatorState> _navKey(String label) =>
      _navKeys.putIfAbsent(label, () => GlobalKey<NavigatorState>());

  // Tab labels of the last build, for deep links arriving between builds.
  List<String> _labels = [];

  static const _linkTabs = {
    'doc': 'Dokumente',
    'documents': 'Dokumente',
    'indexes': 'Indizes',
    'inbox': 'Eingang',
    'notifications': 'Posteingang',
    'admin': 'Verwaltung',
  };

  @override
  void initState() {
    super.initState();
    // fireImmediately: a link may have arrived before login. Applied after
    // the frame — providers must not change during the widget build.
    ref.listenManual(pendingDeepLinkProvider, (_, uri) {
      if (uri == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openLink(uri));
    }, fireImmediately: true);
  }

  void _openLink(Uri uri) {
    if (!mounted) return;
    ref.read(pendingDeepLinkProvider.notifier).clear();
    final label = _linkTabs[uri.host];
    final i = _labels.indexOf(label ?? '');
    // Unknown target, or a tab this user does not have (inbox, admin).
    if (i < 0) return;
    setState(() => _tab = i);
    if (uri.host == 'doc' && uri.pathSegments.isNotEmpty) {
      _navKey(label!).currentState?.push(
        MaterialPageRoute(
          builder: (_) => DocumentDetailScreen(uuid: uri.pathSegments.first),
        ),
      );
    }
  }

  Widget _tabNavigator(String label, Widget root) => Navigator(
    key: _navKey(label),
    onGenerateRoute: (settings) => MaterialPageRoute(builder: (_) => root),
  );

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).session;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final isAdmin = session?.user.isSuperuser ?? false;
    // No push channel exists — the badge count is polled (~45 s) while
    // logged in (notifications hand-off §1).
    final unread = ref.watch(unreadNotificationsProvider);
    // Collect editing notices from login on, not only once a banner exists.
    ref.listen(documentEditorsProvider, (_, _) {});
    final inboxIcon = Badge.count(
      count: unread,
      isLabelVisible: unread > 0,
      child: const Icon(Icons.notifications_outlined),
    );
    final hasInbox = ref.watch(inboxAvailableProvider).value ?? false;
    final destinations = [
      // Search lives in the document list itself.
      (
        icon: const Icon(Icons.description_outlined),
        label: 'Dokumente',
        root: const DocumentListScreen(),
      ),
      if (hasInbox)
        (
          icon: const Icon(Icons.move_to_inbox_outlined),
          label: 'Eingang',
          root: const InboxScreen(),
        ),
      (
        icon: const Icon(Icons.account_tree_outlined),
        label: 'Indizes',
        root: const IndexListScreen(),
      ),
      // Document inbox; hidden when `GET inbox/` is refused.
      (
        icon: inboxIcon,
        label: 'Posteingang',
        root: const NotificationsScreen(),
      ),
      // Admin area is gated on is_superuser (spec §7 M4).
      if (isAdmin)
        (
          icon: const Icon(Icons.admin_panel_settings_outlined),
          label: 'Verwaltung',
          root: const AdminScreen(),
        ),
    ];
    if (_tab >= destinations.length) _tab = 0;
    _labels = [for (final d in destinations) d.label];

    void onDestinationSelected(int i) {
      // Re-tapping the active tab pops it back to its root, matching the
      // usual bottom-nav / rail convention.
      if (i == _tab) {
        _navKey(destinations[i].label).currentState?.popUntil((r) => r.isFirst);
      } else {
        setState(() => _tab = i);
      }
    }

    final logoutButton = IconButton(
      tooltip:
          'Abmelden${session != null ? ' (${session.user.username})' : ''}',
      icon: const Icon(Icons.logout),
      onPressed: () => ref.read(sessionProvider.notifier).logout(),
    );

    final body = IndexedStack(
      index: _tab,
      // Hidden tabs stay mounted; TickerMode off marks them inactive so their
      // DropTargets ignore drops (desktop_drop only checks bounds).
      children: [
        for (final (i, d) in destinations.indexed)
          TickerMode(enabled: i == _tab, child: _tabNavigator(d.label, d.root)),
      ],
    );

    // Route the system/back button to the active tab's nested Navigator first,
    // so it pops the pushed detail route rather than exiting the shell.
    final tabs = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _navKey(destinations[_tab].label).currentState?.maybePop();
      },
      child: body,
    );
    final update = ref.watch(appUpdateProvider).value;
    final content = update == null || _updateDismissed
        ? tabs
        : Column(
            children: [
              // One row: MaterialBanner moves two actions onto a second line.
              Material(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.system_update_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'LUVI Docs ${update.version} ist verfügbar.',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_updating)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else if (update.tarball case final tarball?)
                        FilledButton(
                          onPressed: () => _installUpdate(tarball),
                          child: const Text('Aktualisieren'),
                        )
                      else
                        FilledButton(
                          onPressed: () => launchUrl(
                            Uri.parse(update.url),
                            mode: LaunchMode.externalApplication,
                          ),
                          child: const Text('Herunterladen'),
                        ),
                      IconButton(
                        tooltip: 'Später',
                        icon: const Icon(Icons.close),
                        onPressed: () =>
                            setState(() => _updateDismissed = true),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(child: tabs),
            ],
          );

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _tab,
              onDestinationSelected: onDestinationSelected,
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
                  NavigationRailDestination(icon: d.icon, label: Text(d.label)),
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
        onDestinationSelected: onDestinationSelected,
        destinations: [
          for (final d in destinations)
            NavigationDestination(icon: d.icon, label: d.label),
        ],
      ),
    );
  }
}
