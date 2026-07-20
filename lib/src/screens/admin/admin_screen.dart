import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../models/models.dart';
import '../../state/session.dart';
import '../../widgets/common.dart';
import 'type_editor_screen.dart';

/// Admin area (M4), gated on is_superuser: document types (incl. metadata
/// fields + ACLs), retention policies, storages.
class AdminScreen extends ConsumerWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Administration'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Document types'),
            Tab(text: 'Retention policies'),
            Tab(text: 'Storages'),
          ]),
        ),
        body: const TabBarView(children: [
          _TypesTab(),
          _RetentionTab(),
          _StoragesTab(),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- types --

class _TypesTab extends ConsumerWidget {
  const _TypesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typesAsync = ref.watch(documentTypesProvider);
    return typesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorRetry(
        error: e,
        onRetry: () => ref.invalidate(documentTypesProvider),
      ),
      data: (types) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'admin-new-type',
          icon: const Icon(Icons.add),
          label: const Text('New type'),
          onPressed: () async {
            final changed =
                await Navigator.of(context).push<bool>(MaterialPageRoute(
              builder: (_) => const TypeEditorScreen(),
            ));
            if (changed == true) ref.invalidate(documentTypesProvider);
          },
        ),
        body: ListView(
          children: [
            for (final t in types)
              ListTile(
                contentPadding:
                    EdgeInsets.only(left: 16.0 + t.depth * 20, right: 8),
                leading: Icon(
                  t.depth == 0 ? Icons.folder_outlined : Icons.label_outline,
                ),
                title: Row(
                  children: [
                    Flexible(child: Text(t.name)),
                    if (!t.isActive)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text('inactive',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                    color:
                                        Theme.of(context).disabledColor)),
                      ),
                    if (t.retentionPolicy != null)
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Icon(Icons.lock_outline, size: 14),
                      ),
                  ],
                ),
                subtitle: Text(
                  '${t.slug} · ${t.metadataFields.length} own field(s)',
                ),
                onTap: () async {
                  final changed = await Navigator.of(context)
                      .push<bool>(MaterialPageRoute(
                    builder: (_) => TypeEditorScreen(existing: t),
                  ));
                  if (changed == true) {
                    ref.invalidate(documentTypesProvider);
                  }
                },
              ),
            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ retention --

final _retentionProvider = FutureProvider<List<RetentionPolicy>>(
    (ref) => ref.watch(apiProvider).retentionPolicies());

class _RetentionTab extends ConsumerWidget {
  const _RetentionTab();

  Future<void> _edit(BuildContext context, WidgetRef ref,
      [RetentionPolicy? existing]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _RetentionDialog(existing: existing),
    );
    if (saved == true) ref.invalidate(_retentionProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncPolicies = ref.watch(_retentionProvider);
    return asyncPolicies.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorRetry(
        error: e,
        onRetry: () => ref.invalidate(_retentionProvider),
      ),
      data: (policies) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'admin-new-policy',
          icon: const Icon(Icons.add),
          label: const Text('New policy'),
          onPressed: () => _edit(context, ref),
        ),
        body: ListView(
          children: [
            for (final p in policies)
              ListTile(
                leading: Icon(p.isCompliance
                    ? Icons.lock_outline
                    : Icons.lock_open_outlined),
                title: Text(p.name),
                subtitle: Text(p.retentionYears != null
                    ? '${p.retentionYears} years from '
                        '${p.anchor == 'date_added' ? 'upload date' : 'document date'}'
                        '${p.isCompliance ? ' · compliance' : ''}'
                    : 'No retention (freely editable)'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  onPressed: () async {
                    try {
                      await ref
                          .read(apiProvider)
                          .deleteRetentionPolicy(p.id);
                      ref.invalidate(_retentionProvider);
                    } on ApiException catch (e) {
                      if (context.mounted) showSnack(context, e.detail);
                    }
                  },
                ),
                onTap: () => _edit(context, ref, p),
              ),
            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }
}

class _RetentionDialog extends ConsumerStatefulWidget {
  final RetentionPolicy? existing;

  const _RetentionDialog({this.existing});

  @override
  ConsumerState<_RetentionDialog> createState() => _RetentionDialogState();
}

class _RetentionDialogState extends ConsumerState<_RetentionDialog> {
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _yearsCtrl = TextEditingController(
      text: widget.existing?.retentionYears?.toString() ?? '');
  late String _anchor = widget.existing?.anchor ?? 'document_date';
  bool _busy = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _yearsCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    final years = _yearsCtrl.text.trim();
    final body = {
      'name': name,
      'retention_years': years.isEmpty ? null : int.tryParse(years),
      'anchor': _anchor,
    };
    setState(() => _busy = true);
    try {
      final api = ref.read(apiProvider);
      if (widget.existing != null) {
        await api.patchRetentionPolicy(widget.existing!.id, body);
      } else {
        await api.createRetentionPolicy(body);
      }
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, e.detail);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing != null
          ? 'Edit retention policy'
          : 'New retention policy'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Name *',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              enabled: !_busy,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _yearsCtrl,
              decoration: const InputDecoration(
                labelText: 'Retention years',
                helperText: 'Empty = no compliance, freely editable',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              enabled: !_busy,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _anchor,
              decoration: const InputDecoration(
                labelText: 'Anchor',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                    value: 'document_date', child: Text('Document date')),
                DropdownMenuItem(
                    value: 'date_added', child: Text('Upload date')),
              ],
              onChanged:
                  _busy ? null : (v) => setState(() => _anchor = v!),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------- storages --

final _storagesProvider =
    FutureProvider<List<Storage>>((ref) => ref.watch(apiProvider).storages());

class _StoragesTab extends ConsumerWidget {
  const _StoragesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncStorages = ref.watch(_storagesProvider);
    return asyncStorages.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorRetry(
        error: e,
        onRetry: () => ref.invalidate(_storagesProvider),
      ),
      data: (storages) => ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Storages are listed read-only here — backend/config changes '
              'affect stored files and belong in a controlled server-side '
              'rollout. Only the flags below can be toggled.',
            ),
          ),
          for (final s in storages)
            ListTile(
              leading: Icon(s.backend == 's3'
                  ? Icons.cloud_outlined
                  : Icons.storage_outlined),
              title: Row(
                children: [
                  Flexible(child: Text(s.name)),
                  if (s.isDefault)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Chip(
                        label: const Text('default'),
                        visualDensity: VisualDensity.compact,
                        labelStyle:
                            Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                ],
              ),
              subtitle: Text([
                s.backend,
                if (s.objectLockEnabled)
                  'object lock${s.defaultLockMode != null ? ' (${s.defaultLockMode})' : ''}',
                if (s.readOnly) 'read-only',
                if (!s.isActive) 'inactive',
              ].join(' · ')),
              trailing: s.isDefault
                  ? null
                  : TextButton(
                      child: const Text('Make default'),
                      onPressed: () async {
                        try {
                          await ref
                              .read(apiProvider)
                              .patchStorage(s.id, {'is_default': true});
                          ref.invalidate(_storagesProvider);
                        } on ApiException catch (e) {
                          if (context.mounted) {
                            showSnack(context, e.detail);
                          }
                        }
                      },
                    ),
            ),
        ],
      ),
    );
  }
}
