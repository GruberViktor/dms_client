import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/notifications.dart';
import '../state/session.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import 'document_detail_screen.dart';

/// The in-app inbox (notifications hand-off §2). The list is the source of
/// truth (email is best-effort on top); rows for documents the user can no
/// longer view disappear server-side, so we always refetch instead of caching.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  final _scroll = ScrollController();
  List<NotificationItem> _items = [];
  int _count = 0;
  Object? _error;
  bool _loading = true;
  bool _loadingMore = false;
  bool _unreadOnly = false;
  // Set while we change the unread count ourselves (mark read / read-all) so
  // the count listener doesn't refetch a list we already updated locally.
  bool _localCountChange = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(apiProvider)
          .notifications(unreadOnly: _unreadOnly);
      if (!mounted) return;
      setState(() {
        _items = page.results;
        _count = page.count;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _maybeLoadMore() async {
    if (_loadingMore ||
        _loading ||
        _items.length >= _count ||
        _scroll.position.extentAfter > 400) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(apiProvider)
          .notifications(unreadOnly: _unreadOnly, offset: _items.length);
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...page.results];
        _count = page.count;
      });
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _markRead(NotificationItem n) async {
    if (n.isRead) return;
    // Optimistic — the endpoint is idempotent and failure only costs the
    // read tick until the next refetch.
    setState(() {
      _items = [for (final x in _items) x.id == n.id ? x.asRead() : x];
    });
    final unread = ref.read(unreadNotificationsProvider.notifier);
    _localCountChange = true;
    unread.setLocal(ref.read(unreadNotificationsProvider) - 1);
    _localCountChange = false;
    try {
      await ref.read(apiProvider).markNotificationRead(n.id);
    } on ApiException {
      unread.refresh();
    }
  }

  Future<void> _markAllRead() async {
    try {
      await ref.read(apiProvider).markAllNotificationsRead();
      _localCountChange = true;
      ref.read(unreadNotificationsProvider.notifier).setLocal(0);
      _localCountChange = false;
      await _load();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    }
  }

  void _open(NotificationItem n) {
    _markRead(n);
    // `document` is nulled once the document is gone (e.g. delete events) —
    // then there is nowhere to link; the row still renders from the payload.
    final uuid = n.documentUuid;
    if (uuid == null || n.action == 'delete') return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DocumentDetailScreen(uuid: uuid)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Refetch when the polled unread count moves (new rows, or rows marked
    // read / hidden by an ACL change elsewhere). The callback can fire while
    // the widget tree is mid-build (provider rebuilds cascade synchronously),
    // so defer — calling setState directly here throws "setState during
    // build".
    ref.listen(unreadNotificationsProvider, (prev, next) {
      if (prev == null || prev == next || _localCountChange) return;
      Future.microtask(() {
        if (mounted && !_loading) _load();
      });
    });
    final unread = ref.watch(unreadNotificationsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Inbox'),
        actions: [
          IconButton(
            tooltip: _unreadOnly ? 'Show all' : 'Show unread only',
            isSelected: _unreadOnly,
            icon: const Icon(Icons.mark_email_unread_outlined),
            selectedIcon: const Icon(Icons.mark_email_unread),
            onPressed: () {
              setState(() => _unreadOnly = !_unreadOnly);
              _load();
            },
          ),
          IconButton(
            tooltip: 'Mark all as read',
            icon: const Icon(Icons.done_all),
            onPressed: unread > 0 ? _markAllRead : null,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          IconButton(
            tooltip: 'Email preferences',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const _PreferencesDialog(),
            ),
          ),
        ],
      ),
      body: _error != null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
                  ? Center(
                      child: Text(
                        _unreadOnly
                            ? 'No unread notifications.'
                            : 'No notifications.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        controller: _scroll,
                        itemCount: _items.length + (_loadingMore ? 1 : 0),
                        itemBuilder: (context, i) => i >= _items.length
                            ? const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            : _NotificationTile(
                                item: _items[i],
                                onTap: () => _open(_items[i]),
                                onMarkRead: () => _markRead(_items[i]),
                              ),
                      ),
                    ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final NotificationItem item;
  final VoidCallback onTap;
  final VoidCallback onMarkRead;

  const _NotificationTile({
    required this.item,
    required this.onTap,
    required this.onMarkRead,
  });

  // Audit actions phrased for "<actor> <phrase> <title>" (same vocabulary as
  // the timeline's _AuditLine labels).
  static const _actionPhrases = {
    'create': 'created',
    'edit_metadata': 'edited metadata on',
    'edit_fields': 'edited fields on',
    'version_upload': 'uploaded a new version of',
    'version_replace_file': 'replaced a file in',
    'version_hide': 'hid a version of',
    'version_unhide': 'unhid a version of',
    'version_release': 'released a version of',
    'archive': 'archived',
    'unarchive': 'unarchived',
    'type_change': 'changed the type of',
    'delete': 'deleted',
    'comment_add': 'commented on',
    'comment_edit': 'edited a comment on',
    'comment_delete': 'deleted a comment on',
  };

  IconData get _icon => switch (item.kind) {
        'mention' => Icons.alternate_email,
        'watched_document' => Icons.visibility_outlined,
        'watched_type' => Icons.account_tree_outlined,
        'workflow' => Icons.schema_outlined,
        _ => Icons.notifications_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final actor = item.actor ?? 'someone';
    final title = item.payloadDocumentTitle;

    final TextSpan headline;
    switch (item.kind) {
      case 'mention':
        headline = _span(actor, 'mentioned you on', title);
      case 'watched_document' || 'watched_type':
        final phrase = _actionPhrases[item.action] ??
            item.action.replaceAll('_', ' ');
        headline = _span(actor, phrase, title);
      default:
        // Unknown/reserved kinds (e.g. workflow): generic fallback (§2).
        headline = TextSpan(
          text: [
            if (item.actor != null) actor,
            if (item.action.isNotEmpty) item.action.replaceAll('_', ' '),
            if (title.isNotEmpty) title,
          ].join(' · '),
        );
    }

    final details = <String>[
      formatDateTime(item.createdAt),
      if (item.kind == 'watched_type') 'watched category',
      if (item.version != null) 'v${item.version}',
      if (item.changedFields.isNotEmpty) item.changedFields.join(', '),
    ];

    return ListTile(
      leading: Icon(
        _icon,
        color: item.isRead ? scheme.onSurfaceVariant : scheme.primary,
      ),
      title: Text.rich(
        headline,
        style: item.isRead
            ? null
            : const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item.bodyExcerpt?.isNotEmpty ?? false)
            Text(
              item.bodyExcerpt!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          Text(
            details.join(' · '),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      trailing: item.isRead
          ? null
          : IconButton(
              tooltip: 'Mark as read',
              icon: Icon(Icons.circle, size: 10, color: scheme.primary),
              onPressed: onMarkRead,
            ),
      onTap: onTap,
    );
  }

  static TextSpan _span(String actor, String phrase, String title) => TextSpan(
        children: [
          TextSpan(
            text: actor,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextSpan(text: ' $phrase '),
          TextSpan(
            text: title,
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        ],
      );
}

/// Three email gates (§4) — they only gate email; the inbox always gets the
/// row. PATCH is partial, so each switch saves on its own.
class _PreferencesDialog extends ConsumerStatefulWidget {
  const _PreferencesDialog();

  @override
  ConsumerState<_PreferencesDialog> createState() =>
      _PreferencesDialogState();
}

class _PreferencesDialogState extends ConsumerState<_PreferencesDialog> {
  NotificationPreferences? _prefs;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final prefs = await ref.read(apiProvider).notificationPreferences();
      if (mounted) setState(() => _prefs = prefs);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _set(String key, bool value) async {
    try {
      final prefs = await ref
          .read(apiProvider)
          .patchNotificationPreferences({key: value});
      if (mounted) setState(() => _prefs = prefs);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    return AlertDialog(
      title: const Text('Email notifications'),
      content: SizedBox(
        width: 400,
        child: _error != null
            ? ErrorRetry(error: _error!, onRetry: _load)
            : prefs == null
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'The inbox always receives every notification; these '
                        'only control the emails sent on top.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        title: const Text('Mentions'),
                        value: prefs.emailMentions,
                        onChanged: (v) => _set('email_mentions', v),
                      ),
                      SwitchListTile(
                        title: const Text('Watched documents & categories'),
                        value: prefs.emailWatches,
                        onChanged: (v) => _set('email_watches', v),
                      ),
                      SwitchListTile(
                        title: const Text('Workflows (future)'),
                        value: prefs.emailWorkflow,
                        onChanged: (v) => _set('email_workflow', v),
                      ),
                    ],
                  ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
