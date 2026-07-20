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
  late final TextEditingController _slugCtrl =
      TextEditingController(text: widget.existing?.slug ?? '');
  late String? _parentSlug = widget.existing?.parentSlug;
  late int? _retentionPolicy = widget.existing?.retentionPolicy;
  late bool _isActive = widget.existing?.isActive ?? true;
  bool _busy = false;
  bool _changed = false;

  // Own metadata fields (existing types only; created types get them after
  // the first save).
  List<MetadataFieldDef>? _ownFields;

  // ACL editor state (existing types only).
  List<AclEntry>? _aclEntries;
  Object? _aclError;

  List<RetentionPolicy> _policies = const [];

  @override
  void initState() {
    super.initState();
    _loadSecondary();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _slugCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSecondary() async {
    final api = ref.read(apiProvider);
    try {
      final policies = await api.retentionPolicies();
      if (mounted) setState(() => _policies = policies);
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
      if (widget.existing == null) 'slug': _slugCtrl.text.trim(),
      'parent': _parentSlug,
      'retention_policy': _retentionPolicy,
      'is_active': _isActive,
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
        title: Text('Delete type "${widget.existing!.name}"?'),
        content: const Text(
            'This fails if documents of this type exist. Consider marking '
            'the type inactive instead.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
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
      if (mounted) showSnack(context, 'Permissions saved.');
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
        title: const Text('Add group'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'Group ID',
            helperText: 'Numeric Django group id — there is no group '
                'listing API yet (server-side gap, spec §10).',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(ctrl.text.trim())),
            child: const Text('Add'),
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
          title: Text(isNew ? 'New document type' : widget.existing!.name),
          actions: [
            if (!isNew)
              IconButton(
                tooltip: 'Delete type',
                icon: const Icon(Icons.delete_outline),
                onPressed: _busy ? null : _delete,
              ),
            TextButton(
              onPressed: _busy ? null : _save,
              child: const Text('Save'),
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
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
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
                      if (t.isEmpty) return 'Required';
                      if (!RegExp(r'^[-a-zA-Z0-9_]+$').hasMatch(t)) {
                        return 'Only letters, digits, - and _';
                      }
                      return null;
                    },
                    enabled: !_busy && isNew,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: selectedParent,
                    decoration: const InputDecoration(
                      labelText: 'Parent type',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('— root —')),
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
                      labelText: 'Retention policy',
                      helperText:
                          'Inherited by descendants; compliance policies '
                          'lock delete/replace on their documents',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<int?>(
                          value: null, child: Text('— inherit / none —')),
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
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    subtitle:
                        const Text('Inactive types are hidden on upload'),
                    value: _isActive,
                    onChanged:
                        _busy ? null : (v) => setState(() => _isActive = v),
                  ),

                  if (!isNew) ...[
                    const Divider(height: 32),
                    Row(
                      children: [
                        Expanded(
                          child: Text('Own metadata fields',
                              style:
                                  Theme.of(context).textTheme.titleMedium),
                        ),
                        TextButton.icon(
                          onPressed: () => _editField(),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add field'),
                        ),
                      ],
                    ),
                    Text(
                      'Descendant types inherit these; child keys override.',
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
                        child: Text('No own fields.'),
                      )
                    else
                      for (final f in _ownFields!)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.short_text),
                          title: Text('${f.label}  ·  ${f.key}'),
                          subtitle: Text(
                              '${f.fieldType.name}${f.required ? ' · required' : ''}'
                              '${f.indexed ? ' · indexed' : ''}'),
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
                          child: Text('Permissions (ACL)',
                              style:
                                  Theme.of(context).textTheme.titleMedium),
                        ),
                        TextButton.icon(
                          onPressed: _addAclGroup,
                          icon: const Icon(Icons.group_add_outlined,
                              size: 18),
                          label: const Text('Add group'),
                        ),
                      ],
                    ),
                    Text(
                      'Per group, inherited by descendant types.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    if (_aclError != null)
                      Text('Could not load ACLs: $_aclError')
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
                          child: Text('No own ACL entries.'),
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
                                            : 'Group ${entry.group}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Remove group',
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
                                        label: Text(perm),
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
                          child: const Text('Save permissions'),
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
      title: Text(widget.existing != null ? 'Edit field' : 'New field'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _keyCtrl,
              decoration: const InputDecoration(
                labelText: 'Key *',
                helperText: 'Wire name, e.g. invoice_number',
                border: OutlineInputBorder(),
              ),
              enabled: !_busy && widget.existing == null,
              autofocus: widget.existing == null,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _labelCtrl,
              decoration: const InputDecoration(
                labelText: 'Label *',
                border: OutlineInputBorder(),
              ),
              enabled: !_busy,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _fieldType,
              decoration: const InputDecoration(
                labelText: 'Type',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'text', child: Text('Text')),
                DropdownMenuItem(value: 'date', child: Text('Date')),
                DropdownMenuItem(value: 'integer', child: Text('Integer')),
                DropdownMenuItem(value: 'float', child: Text('Float')),
                DropdownMenuItem(
                    value: 'monetary', child: Text('Monetary')),
                DropdownMenuItem(value: 'bool', child: Text('Boolean')),
                DropdownMenuItem(value: 'url', child: Text('URL')),
              ],
              onChanged:
                  _busy ? null : (v) => setState(() => _fieldType = v!),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Required'),
              value: _required,
              onChanged:
                  _busy ? null : (v) => setState(() => _required = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Indexed'),
              subtitle: const Text('For tree views / sorting'),
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
