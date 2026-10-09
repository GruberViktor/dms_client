import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../models/models.dart';
import '../../state/session.dart';
import '../../widgets/common.dart';

/// Create/edit a document type: base fields, own metadata field definitions,
/// and the type's ACL entries (M4 admin).
class TypeEditorScreen extends ConsumerStatefulWidget {
  final DocumentType? existing;

  const TypeEditorScreen({super.key, this.existing});

  @override
  ConsumerState<TypeEditorScreen> createState() => _TypeEditorScreenState();
}

class _TypeEditorScreenState extends ConsumerState<TypeEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _descriptionCtrl =
      TextEditingController(text: widget.existing?.description ?? '');
  late final TextEditingController _slugCtrl =
      TextEditingController(text: widget.existing?.slug ?? '');
  late String? _parentSlug = widget.existing?.parentSlug;
  late int? _retentionPolicy = widget.existing?.retentionPolicy;
  late int? _storage = widget.existing?.storage;
  late bool _isActive = widget.existing?.isActive ?? true;
  // null = inherit from parent (approvals hand-off §2).
  late String? _approvalMode = widget.existing?.approvalMode;
  bool _busy = false;
  bool _changed = false;

  // Own metadata fields (existing types only; created types get them after
  // the first save).
  List<MetadataFieldDef>? _ownFields;

  // ACL editor state (existing types only).
  List<AclEntry>? _aclEntries;
  Object? _aclError;

  List<RetentionPolicy> _policies = const [];
  List<Storage> _storages = const [];

  @override
  void initState() {
    super.initState();
    _loadSecondary();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descriptionCtrl.dispose();
    _slugCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSecondary() async {
    final api = ref.read(apiProvider);
    try {
      final policies = await api.retentionPolicies();
      if (mounted) setState(() => _policies = policies);
    } catch (_) {/* dropdown just stays id-only */}
    try {
      final storages = await api.storages();
      if (mounted) setState(() => _storages = storages);
    } catch (_) {/* dropdown just stays id-only */}
    if (widget.existing != null) {
      _reloadFields();
      _reloadAcls();
    }
  }

  Future<void> _reloadFields() async {
    final api = ref.read(apiProvider);
    try {
      final fields = await api.metadataFields(widget.existing!.slug);
      if (mounted) setState(() => _ownFields = fields);
    } catch (_) {
      if (mounted) setState(() => _ownFields = const []);
    }
  }

  Future<void> _reloadAcls() async {
    final api = ref.read(apiProvider);
    try {
      final data = await api.acls(widget.existing!.slug);
      if (!mounted) return;
      setState(() {
        _aclEntries = ((data['own'] as List?) ?? const [])
            .map((e) => AclEntry.fromJson((e as Map).cast<String, dynamic>()))
            .toList();
        _aclError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _aclError = e);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final body = {
      'name': _nameCtrl.text.trim(),
      'description': _descriptionCtrl.text.trim(),
      if (widget.existing == null) 'slug': _slugCtrl.text.trim(),
      'parent': _parentSlug,
      'retention_policy': _retentionPolicy,
      'storage': _storage,
      'is_active': _isActive,
      'approval_mode': _approvalMode,
    };
    setState(() => _busy = true);
    try {
      final api = ref.read(apiProvider);
      if (widget.existing != null) {
        await api.patchDocumentType(widget.existing!.slug, body);
      } else {
        await api.createDocumentType(body);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, e.detail);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Typ „${widget.existing!.name}“ löschen?'),
        content: const Text(
            'Das schlägt fehl, solange Dokumente dieses Typs existieren. '
            'Setzen Sie den Typ stattdessen besser auf inaktiv.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(apiProvider).deleteDocumentType(widget.existing!.slug);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    }
  }

  // ---- metadata fields ----

  Future<void> _editField([MetadataFieldDef? field]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _FieldDialog(
        typeSlug: widget.existing!.slug,
        existing: field,
        existingId: field?.id,
      ),
    );
    if (saved == true) {
      _changed = true;
      _reloadFields();
    }
  }

  Future<void> _deleteField(MetadataFieldDef field) async {
    final id = field.id;
    if (id == null) return;
    try {
      await ref
          .read(apiProvider)
          .deleteMetadataField(widget.existing!.slug, id);
      _changed = true;
      _reloadFields();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    }
  }

  // ---- ACLs ----

  Future<void> _saveAcls() async {
    try {
      await ref
          .read(apiProvider)
          .putAcls(widget.existing!.slug, _aclEntries ?? const []);
      _changed = true;
      if (mounted) showSnack(context, 'Berechtigungen gespeichert.');
      _reloadAcls();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    }
  }

  Future<void> _addAclGroup() async {
    final ctrl = TextEditingController();
    final groupId = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Gruppe hinzufügen'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'Gruppen-ID',
            helperText: 'Numerische Django-Gruppen-ID — es gibt noch keine '
                'API zum Auflisten von Gruppen (serverseitige Lücke, §10).',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(ctrl.text.trim())),
            child: const Text('Hinzufügen'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (groupId == null) return;
    setState(() {
      _aclEntries = [
        ...?_aclEntries,
        AclEntry(group: groupId, permissions: {'view'}),
      ];
    });
  }

  static String _modeLabel(String mode) => switch (mode) {
        'none' => 'Keine (Versionen sofort aktiv)',
        'required' => 'Freigabe erforderlich',
        'four_eyes' => 'Vier Augen (Hochladende dürfen nicht freigeben)',
        _ => mode,
      };

  @override
  Widget build(BuildContext context) {
    final types = ref.watch(documentTypesProvider).value ?? const <DocumentType>[];
    final isNew = widget.existing == null;

    // Guard the dropdown values against async-loaded item lists: feeding a
    // value with no matching (or duplicate) DropdownMenuItem trips a Material
    // assertion. Fall back to null until the backing list arrives — the field
    // resets to the real value on the next build.
    final parentOptions =
        types.where((t) => t.slug != widget.existing?.slug).toList();
    final selectedParent =
        parentOptions.any((t) => t.slug == _parentSlug) ? _parentSlug : null;
    final selectedPolicy =
        _policies.any((p) => p.id == _retentionPolicy) ? _retentionPolicy : null;
    final selectedStorage =
        _storages.any((s) => s.id == _storage) ? _storage : null;

    // Storage routing (storage hand-off §4): a retention policy — own or
    // inherited from an ancestor — decides where documents land; the type's
    // own storage is only the fallback for types no policy applies to.
    final effectivePolicyId = _retentionPolicy ??
        effectiveRetentionPolicy(
            {for (final t in types) t.slug: t}, _parentSlug);
    final effectivePolicy = effectivePolicyId == null
        ? null
        : _policies.cast<RetentionPolicy?>().firstWhere(
            (p) => p!.id == effectivePolicyId,
            orElse: () => null);
    final policyInherited =
        _retentionPolicy == null && effectivePolicyId != null;
    final fallbackTarget = selectedStorage == null
        ? 'Standard-Speicher'
        : storageName(_storages, selectedStorage);
    final policyTarget = storageName(_storages, effectivePolicy?.storage);
    final policyLabel = effectivePolicy?.name ?? '#$effectivePolicyId';

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        // Field/ACL edits happen immediately — make sure the caller refreshes.
        if (didPop && result == null && _changed) {
          ref.invalidate(documentTypesProvider);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(isNew ? 'Neuer Dokumenttyp' : widget.existing!.name),
          actions: [
            if (!isNew)
              IconButton(
                tooltip: 'Typ löschen',
                icon: const Icon(Icons.delete_outline),
                onPressed: _busy ? null : _delete,
              ),
            TextButton(
              onPressed: _busy ? null : _save,
              child: const Text('Speichern'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextFormField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Name *',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Pflichtfeld' : null,
                    enabled: !_busy,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _descriptionCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Beschreibung',
                      helperText: 'Woran man Dokumente dieses Typs erkennt — '
                          'verbessert die Vorschläge im Eingang.',
                      helperMaxLines: 2,
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 3,
                    enabled: !_busy,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _slugCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Slug *',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) {
                      final t = (v ?? '').trim();
                      if (t.isEmpty) return 'Pflichtfeld';
                      if (!RegExp(r'^[-a-zA-Z0-9_]+$').hasMatch(t)) {
                        return 'Nur Buchstaben, Ziffern, - und _';
                      }
                      return null;
                    },
                    enabled: !_busy && isNew,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: selectedParent,
                    decoration: const InputDecoration(
                      labelText: 'Übergeordneter Typ',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('— oberste Ebene —')),
                      for (final t in parentOptions)
                        DropdownMenuItem<String?>(
                          value: t.slug,
                          child: Text('${'    ' * t.depth}${t.name}'),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _parentSlug = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int?>(
                    initialValue: selectedPolicy,
                    decoration: const InputDecoration(
                      labelText: 'Aufbewahrungsregel',
                      helperText:
                          'Wird an Untertypen vererbt; Regeln mit '
                          'Aufbewahrungspflicht sperren Löschen/Ersetzen '
                          'ihrer Dokumente',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<int?>(
                          value: null, child: Text('— erben / keine —')),
                      for (final p in _policies)
                        DropdownMenuItem<int?>(
                          value: p.id,
                          child: Text(
                              '${p.name}${p.isCompliance ? ' 🔒' : ''}'),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _retentionPolicy = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int?>(
                    initialValue: selectedStorage,
                    decoration: InputDecoration(
                      labelText: 'Ausweich-Speicher',
                      helperText: effectivePolicyId != null
                          ? 'Ohne Wirkung, solange eine Aufbewahrungsregel '
                              'greift — dann bestimmt deren Speicher das Ziel.'
                          : 'Ziel für Dokumente dieses Typs, solange keine '
                              'Aufbewahrungsregel greift (leer = Standard).',
                      helperMaxLines: 3,
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<int?>(
                          value: null, child: Text('— Standard-Speicher —')),
                      for (final s in _storages)
                        DropdownMenuItem<int?>(
                          value: s.id,
                          child: Text([
                            s.name,
                            if (s.canHoldRetention) 'Object Lock',
                            if (!s.isActive) 'inaktiv',
                          ].join(' · ')),
                        ),
                    ],
                    onChanged:
                        _busy ? null : (v) => setState(() => _storage = v),
                  ),
                  // Say plainly where documents of this type actually land —
                  // the field above does nothing while a policy applies,
                  // inherited ones included.
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          effectivePolicyId != null
                              ? Icons.lock_outline
                              : Icons.info_outline,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            effectivePolicyId == null
                                ? 'Tatsächliches Ziel: $fallbackTarget'
                                : 'Tatsächliches Ziel: $policyTarget '
                                    '(aus Regel „$policyLabel“'
                                    '${policyInherited ? ', geerbt' : ''})',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: _approvalMode,
                    decoration: InputDecoration(
                      labelText: 'Versionsfreigabe',
                      // The server has no effective-mode endpoint — resolve
                      // the inherited value by walking the parent chain
                      // (approvals hand-off §2).
                      helperText: _approvalMode == null
                          ? 'Geerbt: '
                              '${_modeLabel(effectiveApprovalMode({
                                for (final t in types) t.slug: t,
                              }, _parentSlug))}'
                          : 'Neue Uploads in diesem Teilbaum '
                              '${_approvalMode == 'none' ? 'werden sofort aktiv' : 'warten zuerst auf Freigabe'}',
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('— erben —')),
                      for (final m in const ['none', 'required', 'four_eyes'])
                        DropdownMenuItem<String?>(
                            value: m, child: Text(_modeLabel(m))),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _approvalMode = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Aktiv'),
                    subtitle: const Text(
                        'Inaktive Typen werden beim Hochladen ausgeblendet'),
                    value: _isActive,
                    onChanged:
                        _busy ? null : (v) => setState(() => _isActive = v),
                  ),

                  if (!isNew) ...[
                    const Divider(height: 32),
                    Row(
                      children: [
                        Expanded(
                          child: Text('Eigene Metadatenfelder',
                              style:
                                  Theme.of(context).textTheme.titleMedium),
                        ),
                        TextButton.icon(
                          onPressed: () => _editField(),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Feld hinzufügen'),
                        ),
                      ],
                    ),
                    Text(
                      'Untertypen erben diese; Schlüssel im Untertyp haben '
                      'Vorrang.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    if (_ownFields == null)
                      const Center(
                          child: Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(),
                      ))
                    else if (_ownFields!.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('Keine eigenen Felder.'),
                      )
                    else
                      for (final f in _ownFields!)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.short_text),
                          title: Text('${f.label}  ·  ${f.key}'),
                          subtitle: Text(
                              '${f.fieldType.label}${f.required ? ' · Pflicht' : ''}'
                              '${f.indexed ? ' · indiziert' : ''}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined,
                                    size: 18),
                                onPressed: () => _editField(f),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 18),
                                onPressed: () => _deleteField(f),
                              ),
                            ],
                          ),
                        ),

                    const Divider(height: 32),
                    Row(
                      children: [
                        Expanded(
                          child: Text('Berechtigungen (ACL)',
                              style:
                                  Theme.of(context).textTheme.titleMedium),
                        ),
                        TextButton.icon(
                          onPressed: _addAclGroup,
                          icon: const Icon(Icons.group_add_outlined,
                              size: 18),
                          label: const Text('Gruppe hinzufügen'),
                        ),
                      ],
                    ),
                    Text(
                      'Pro Gruppe, wird an Untertypen vererbt.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    if (_aclError != null)
                      Text('Berechtigungen konnten nicht geladen werden: $_aclError')
                    else if (_aclEntries == null)
                      const Center(
                          child: Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(),
                      ))
                    else ...[
                      if (_aclEntries!.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text('Keine eigenen ACL-Einträge.'),
                        ),
                      for (final entry in _aclEntries!)
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        entry.groupName != null
                                            ? '${entry.groupName} (id ${entry.group})'
                                            : 'Gruppe ${entry.group}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Gruppe entfernen',
                                      icon: const Icon(Icons.close,
                                          size: 18),
                                      onPressed: () => setState(() =>
                                          _aclEntries!.remove(entry)),
                                    ),
                                  ],
                                ),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final perm in aclPermissions)
                                      FilterChip(
                                        label: Text(aclPermissionLabel(perm)),
                                        visualDensity:
                                            VisualDensity.compact,
                                        selected: entry.permissions
                                            .contains(perm),
                                        onSelected: (sel) => setState(() {
                                          sel
                                              ? entry.permissions.add(perm)
                                              : entry.permissions
                                                  .remove(perm);
                                        }),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonal(
                          onPressed: _saveAcls,
                          child: const Text('Berechtigungen speichern'),
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Create/edit one metadata field definition of a type.
class _FieldDialog extends ConsumerStatefulWidget {
  final String typeSlug;
  final MetadataFieldDef? existing;
  final int? existingId;

  const _FieldDialog({
    required this.typeSlug,
    this.existing,
    this.existingId,
  });

  @override
  ConsumerState<_FieldDialog> createState() => _FieldDialogState();
}

class _FieldDialogState extends ConsumerState<_FieldDialog> {
  late final TextEditingController _keyCtrl =
      TextEditingController(text: widget.existing?.key ?? '');
  late final TextEditingController _labelCtrl =
      TextEditingController(text: widget.existing?.label ?? '');
  late String _fieldType = switch (widget.existing?.fieldType) {
    FieldType.date => 'date',
    FieldType.integer => 'integer',
    FieldType.float => 'float',
    FieldType.monetary => 'monetary',
    FieldType.boolean => 'bool',
    FieldType.url => 'url',
    _ => 'text',
  };
  late bool _required = widget.existing?.required ?? false;
  late bool _indexed = widget.existing?.indexed ?? false;
  bool _busy = false;

  @override
  void dispose() {
    _keyCtrl.dispose();
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _keyCtrl.text.trim();
    final label = _labelCtrl.text.trim();
    if (key.isEmpty || label.isEmpty) return;
    final body = {
      'key': key,
      'label': label,
      'field_type': _fieldType,
      'required': _required,
      'indexed': _indexed,
    };
    setState(() => _busy = true);
    try {
      final api = ref.read(apiProvider);
      if (widget.existingId != null) {
        await api.patchMetadataField(widget.typeSlug, widget.existingId!, body);
      } else {
        await api.createMetadataField(widget.typeSlug, body);
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
      title: Text(widget.existing != null ? 'Feld bearbeiten' : 'Neues Feld'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _keyCtrl,
              decoration: const InputDecoration(
                labelText: 'Schlüssel *',
                helperText: 'Name auf der Schnittstelle, z. B. invoice_number',
                border: OutlineInputBorder(),
              ),
              enabled: !_busy && widget.existing == null,
              autofocus: widget.existing == null,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _labelCtrl,
              decoration: const InputDecoration(
                labelText: 'Beschriftung *',
                border: OutlineInputBorder(),
              ),
              enabled: !_busy,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _fieldType,
              decoration: const InputDecoration(
                labelText: 'Typ',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'text', child: Text('Text')),
                DropdownMenuItem(value: 'date', child: Text('Datum')),
                DropdownMenuItem(value: 'integer', child: Text('Ganzzahl')),
                DropdownMenuItem(value: 'float', child: Text('Dezimalzahl')),
                DropdownMenuItem(value: 'monetary', child: Text('Betrag')),
                DropdownMenuItem(value: 'bool', child: Text('Ja/Nein')),
                DropdownMenuItem(value: 'url', child: Text('URL')),
              ],
              onChanged:
                  _busy ? null : (v) => setState(() => _fieldType = v!),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Pflichtfeld'),
              value: _required,
              onChanged:
                  _busy ? null : (v) => setState(() => _required = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Indiziert'),
              subtitle: const Text('Für Baumansichten / Sortierung'),
              value: _indexed,
              onChanged:
                  _busy ? null : (v) => setState(() => _indexed = v),
            ),
          ],
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
