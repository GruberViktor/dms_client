import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/session.dart';

/// Create or edit a user-defined index tree view (M4).
class IndexEditScreen extends ConsumerStatefulWidget {
  final DmsIndex? existing;

  const IndexEditScreen({super.key, this.existing});

  @override
  ConsumerState<IndexEditScreen> createState() => _IndexEditScreenState();
}

class _LevelDraft {
  String source;
  String sourceKey;
  String transform;
  bool descending;

  _LevelDraft({
    this.source = 'metadata',
    this.sourceKey = '',
    this.transform = 'none',
    this.descending = false,
  });

  factory _LevelDraft.from(IndexLevel l) => _LevelDraft(
        source: l.source,
        sourceKey: l.sourceKey ?? '',
        transform: l.transform,
        descending: l.descending,
      );
}

class _IndexEditScreenState extends ConsumerState<IndexEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _slugCtrl =
      TextEditingController(text: widget.existing?.slug ?? '');
  late String? _rootType = widget.existing?.rootDocumentType;
  late bool _shared = widget.existing?.shared ?? false;
  late final List<_LevelDraft> _levels = widget.existing != null
      ? widget.existing!.levels.map(_LevelDraft.from).toList()
      : [_LevelDraft()];
  bool _busy = false;

  static const _sources = {
    'metadata': 'Metadata key',
    'document_date': 'Document date',
    'document_type': 'Document type',
    'added_by': 'Added by',
  };
  static const _transforms = {
    'none': 'As-is',
    'year': 'Year',
    'year_month': 'Year + month',
    'first_letter': 'First letter',
  };

  @override
  void dispose() {
    _nameCtrl.dispose();
    _slugCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_levels.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add at least one level.')));
      return;
    }
    final body = {
      'name': _nameCtrl.text.trim(),
      'slug': _slugCtrl.text.trim(),
      'root_document_type': _rootType,
      'shared': _shared,
      'levels': [
        for (var i = 0; i < _levels.length; i++)
          {
            'position': i,
            'source': _levels[i].source,
            if (_levels[i].source == 'metadata')
              'source_key': _levels[i].sourceKey.trim(),
            'transform': _levels[i].transform,
            'descending': _levels[i].descending,
          },
      ],
    };
    setState(() => _busy = true);
    try {
      final api = ref.read(apiProvider);
      if (widget.existing != null) {
        await api.patchIndex(widget.existing!.slug, body);
      } else {
        await api.createIndex(body);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.detail)));
    }
  }

  static String _slugify(String name) => name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  @override
  Widget build(BuildContext context) {
    final types = ref.watch(documentTypesProvider).value ?? const <DocumentType>[];
    // Merged (ancestor-inherited) metadata fields of the restricted type, so
    // levels can suggest keys that actually exist on those documents (e.g.
    // "partner" on an invoice). Empty when indexing all documents.
    final bySlug = {for (final t in types) t.slug: t};
    final rootFields = _rootType != null
        ? mergedMetadataFields(bySlug, _rootType!)
        : const <MetadataFieldDef>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing != null ? 'Edit index' : 'New index'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
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
                  onChanged: (v) {
                    if (widget.existing == null) {
                      _slugCtrl.text = _slugify(v);
                    }
                  },
                  enabled: !_busy,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _slugCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Slug *',
                    helperText: 'API identifier, e.g. by-vendor',
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
                  // The slug is the URL identifier — changing it on an
                  // existing index would break saved links.
                  enabled: !_busy && widget.existing == null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: _rootType,
                  decoration: const InputDecoration(
                    labelText: 'Restrict to type (optional)',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('All documents')),
                    for (final t in types)
                      DropdownMenuItem<String?>(
                        value: t.slug,
                        child: Text('${'    ' * t.depth}${t.name}'),
                      ),
                  ],
                  onChanged:
                      _busy ? null : (v) => setState(() => _rootType = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Shared'),
                  subtitle: const Text('Visible to all users'),
                  value: _shared,
                  onChanged:
                      _busy ? null : (v) => setState(() => _shared = v),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text('Levels',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _levels.add(_LevelDraft())),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add level'),
                    ),
                  ],
                ),
                for (var i = 0; i < _levels.length; i++)
                  _buildLevelCard(context, i, rootFields),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The "Metadata key" input for a level. When the index is restricted to a
  /// type, the type's (inherited) metadata fields are offered as suggestions
  /// while still allowing a free-typed key.
  Widget _buildMetadataKeyField(
      _LevelDraft level, List<MetadataFieldDef> rootFields) {
    const decoration = InputDecoration(
      labelText: 'Metadata key *',
      border: OutlineInputBorder(),
      isDense: true,
    );
    String? validate(String? v) =>
        (v == null || v.trim().isEmpty) ? 'Required' : null;

    if (rootFields.isEmpty) {
      return TextFormField(
        initialValue: level.sourceKey,
        decoration: decoration,
        validator: validate,
        onChanged: (v) => level.sourceKey = v,
        enabled: !_busy,
      );
    }

    return Autocomplete<MetadataFieldDef>(
      initialValue: TextEditingValue(text: level.sourceKey),
      displayStringForOption: (f) => f.key,
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        if (q.isEmpty) return rootFields;
        return rootFields.where((f) =>
            f.key.toLowerCase().contains(q) ||
            f.label.toLowerCase().contains(q));
      },
      onSelected: (f) => level.sourceKey = f.key,
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240, maxWidth: 320),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [
                for (final f in options)
                  ListTile(
                    dense: true,
                    title: Text(f.label),
                    subtitle: f.label == f.key ? null : Text(f.key),
                    onTap: () => onSelected(f),
                  ),
              ],
            ),
          ),
        ),
      ),
      fieldViewBuilder:
          (context, controller, focusNode, onFieldSubmitted) => TextFormField(
        controller: controller,
        focusNode: focusNode,
        decoration: decoration,
        validator: validate,
        onChanged: (v) => level.sourceKey = v,
        enabled: !_busy,
      ),
    );
  }

  Widget _buildLevelCard(
      BuildContext context, int i, List<MetadataFieldDef> rootFields) {
    final level = _levels[i];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(radius: 12, child: Text('${i + 1}')),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: level.source,
                    decoration: const InputDecoration(
                      labelText: 'Group by',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final e in _sources.entries)
                        DropdownMenuItem(
                            value: e.key, child: Text(e.value)),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => level.source = v!),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove level',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed:
                      _busy ? null : () => setState(() => _levels.removeAt(i)),
                ),
                IconButton(
                  tooltip: 'Move up',
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: (_busy || i == 0)
                      ? null
                      : () => setState(() =>
                          _levels.insert(i - 1, _levels.removeAt(i))),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (level.source == 'metadata') ...[
                  Expanded(
                    child: _buildMetadataKeyField(level, rootFields),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: level.transform,
                    decoration: const InputDecoration(
                      labelText: 'Transform',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final e in _transforms.entries)
                        DropdownMenuItem(
                            value: e.key, child: Text(e.value)),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => level.transform = v!),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  children: [
                    const Text('Desc', style: TextStyle(fontSize: 11)),
                    Checkbox(
                      value: level.descending,
                      onChanged: _busy
                          ? null
                          : (v) =>
                              setState(() => level.descending = v == true),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
