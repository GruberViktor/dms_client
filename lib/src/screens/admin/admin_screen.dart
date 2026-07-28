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
            Tab(text: 'Dokumenttypen'),
            Tab(text: 'Aufbewahrungsregeln'),
            Tab(text: 'Speicher'),
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
          label: const Text('Neuer Typ'),
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
                        child: Text('inaktiv',
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
                  '${t.slug} · ${t.metadataFields.length} eigene Felder',
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
    if (saved == true) {
      ref.invalidate(_retentionProvider);
      // The storage tab lists the compliance policies pinned to each storage —
      // that set just changed.
      ref.invalidate(_storagesProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncPolicies = ref.watch(_retentionProvider);
    final storages = ref.watch(_storagesProvider).value ?? const <Storage>[];
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
          label: const Text('Neue Regel'),
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
                subtitle: Text([
                  if (p.retentionYears != null)
                    '${p.retentionYears} Jahre ab '
                        '${p.anchor == 'date_added' ? 'Upload-Datum' : 'Dokumentdatum'}'
                  else
                    'Keine Aufbewahrung (frei bearbeitbar)',
                  if (p.isCompliance) 'Aufbewahrungspflicht',
                  'Speicher: ${storageName(storages, p.storage)}',
                ].join(' · ')),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Löschen',
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
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _yearsCtrl = TextEditingController(
      text: widget.existing?.retentionYears?.toString() ?? '');
  late String _anchor = widget.existing?.anchor ?? 'document_date';
  late int? _storage = widget.existing?.storage;
  bool _busy = false;

  /// Name of a storage that was dropped from the selection because retention
  /// years just made it ineligible — shown so the pick isn't lost silently.
  String? _clearedStorage;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _yearsCtrl.dispose();
    super.dispose();
  }

  bool get _hasYears => _yearsCtrl.text.trim().isNotEmpty;

  /// Storages this policy may bind to: with retention years set only
  /// object-locked S3, otherwise anything (storage hand-off §2).
  List<Storage> _eligible(List<Storage> all) =>
      _hasYears ? all.where((s) => s.canHoldRetention).toList() : all;

  /// Years changed → the current storage pick may just have become invalid.
  void _onYearsChanged(List<Storage> storages) {
    setState(() {
      // Without the storage list there is nothing to judge eligibility
      // against — leave the pick alone and let the server have the last word.
      if (storages.isEmpty) return;
      if (_storage != null &&
          !_eligible(storages).any((s) => s.id == _storage)) {
        _clearedStorage = storageName(storages, _storage);
        _storage = null;
      } else if (_storage != null || !_hasYears) {
        _clearedStorage = null;
      }
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final years = _yearsCtrl.text.trim();
    final body = {
      'name': _nameCtrl.text.trim(),
      'retention_years': years.isEmpty ? null : int.parse(years),
      'anchor': _anchor,
      'storage': _storage,
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
    final asyncStorages = ref.watch(_storagesProvider);
    final storages = asyncStorages.value ?? const <Storage>[];
    final eligible = _eligible(storages);
    // Storages unreachable but the policy already has one: keep that binding
    // selectable instead of forcing a re-pick that cannot be made here.
    final unresolved = storages.isEmpty ? widget.existing?.storage : null;
    // Guard the dropdown value against the async-loaded list (see the type
    // editor): a value without a matching item trips a Material assertion.
    final selectedStorage =
        eligible.any((s) => s.id == _storage) || _storage == unresolved
            ? _storage
            : null;
    // Nothing a compliance policy could bind to → don't let the user type
    // years that cannot be saved. A policy that already has years keeps its
    // field usable.
    final yearsLocked = storages.isNotEmpty &&
        !_hasYears &&
        !storages.any((s) => s.canHoldRetention);

    return AlertDialog(
      title: Text(widget.existing != null
          ? 'Aufbewahrungsregel bearbeiten'
          : 'Neue Aufbewahrungsregel'),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Name *',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Pflichtfeld' : null,
                  autofocus: true,
                  enabled: !_busy,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _yearsCtrl,
                  decoration: InputDecoration(
                    labelText: 'Aufbewahrungsjahre',
                    helperText: yearsLocked
                        ? 'Legen Sie zuerst einen S3-Speicher mit Object Lock '
                            'an, bevor Sie eine Regel mit Aufbewahrungspflicht '
                            'anlegen.'
                        : 'Leer = keine Aufbewahrungspflicht, frei '
                            'bearbeitbar. Mit Jahren nur auf S3 mit '
                            'Object Lock möglich.',
                    helperMaxLines: 3,
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  enabled: !_busy && !yearsLocked,
                  onChanged: (_) => _onYearsChanged(storages),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return null;
                    final n = int.tryParse(t);
                    return (n == null || n <= 0)
                        ? 'Ganze Zahl größer 0 oder leer'
                        : null;
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int?>(
                  initialValue: selectedStorage,
                  decoration: InputDecoration(
                    labelText: 'Speicher *',
                    helperText: _clearedStorage != null
                        ? 'Auswahl „$_clearedStorage“ entfernt: mit '
                            'Aufbewahrungsjahren ist nur S3 mit Object Lock '
                            'zulässig.'
                        : _hasYears
                            ? 'Nur S3 mit Object Lock — das '
                                'Aufbewahrungsdatum wird am Objekt selbst '
                                'gestempelt.'
                            : 'Dokumente dieser Regel landen hier.',
                    helperMaxLines: 3,
                    helperStyle: _clearedStorage != null
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    if (unresolved != null)
                      DropdownMenuItem<int?>(
                        value: unresolved,
                        child: Text('Speicher #$unresolved'),
                      ),
                    for (final s in eligible)
                      DropdownMenuItem<int?>(
                        value: s.id,
                        child: Text([
                          s.name,
                          if (s.canHoldRetention) 'Object Lock',
                          if (!s.isActive) 'inaktiv',
                        ].join(' · ')),
                      ),
                  ],
                  validator: (v) => v == null ? 'Pflichtfeld' : null,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() {
                            _storage = v;
                            _clearedStorage = null;
                          }),
                ),
                if (asyncStorages.isLoading)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(),
                  ),
                if (asyncStorages.hasError)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Speicher konnten nicht geladen werden.',
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _anchor,
                  decoration: const InputDecoration(
                    labelText: 'Stichtag',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: 'document_date', child: Text('Dokumentdatum')),
                    DropdownMenuItem(
                        value: 'date_added', child: Text('Upload-Datum')),
                  ],
                  onChanged: _busy ? null : (v) => setState(() => _anchor = v!),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Speichern'),
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
    // Compliance policies pinned to each storage: the server refuses to switch
    // Object Lock off (or the backend away from S3) while any of them point at
    // it (storage hand-off §3). Neither is editable in this client, so this is
    // an explanation rather than a disabled control.
    final policies =
        ref.watch(_retentionProvider).value ?? const <RetentionPolicy>[];
    final boundPolicies = <int, List<String>>{};
    for (final p in policies) {
      if (p.storage != null && p.retentionYears != null) {
        boundPolicies.putIfAbsent(p.storage!, () => []).add(p.name);
      }
    }
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
              'Speicher werden hier nur lesend angezeigt — Änderungen an '
              'Backend oder Konfiguration betreffen gespeicherte Dateien und '
              'gehören in einen kontrollierten serverseitigen Rollout. Nur '
              'die Schalter unten lassen sich umstellen.',
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
                        label: const Text('Standard'),
                        visualDensity: VisualDensity.compact,
                        labelStyle:
                            Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  if (boundPolicies.containsKey(s.id))
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.lock_outline, size: 14),
                    ),
                ],
              ),
              isThreeLine: boundPolicies.containsKey(s.id),
              subtitle: Text([
                [
                  s.backend,
                  if (s.objectLockEnabled)
                    'Object Lock${s.defaultLockMode != null ? ' (${s.defaultLockMode})' : ''}',
                  if (s.readOnly) 'schreibgeschützt',
                  if (!s.isActive) 'inaktiv',
                ].join(' · '),
                if (boundPolicies.containsKey(s.id))
                  'Object Lock gebunden durch Aufbewahrungsregeln mit Pflicht: '
                      '${boundPolicies[s.id]!.join(', ')} — solange diese '
                      'bestehen, lässt der Server das Abschalten nicht zu.',
              ].join('\n')),
              trailing: s.isDefault
                  ? null
                  : TextButton(
                      child: const Text('Als Standard setzen'),
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
