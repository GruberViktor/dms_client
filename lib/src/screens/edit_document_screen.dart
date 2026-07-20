import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/permissions.dart';
import '../state/session.dart';
import '../util/format.dart';
import '../widgets/metadata_form.dart';

/// Edit title/notes/document_date/metadata via PATCH (spec §4).
/// Metadata is merged key-wise server-side; clearing a field sends null.
/// Allowed in compliance mode (edits are audited).
class EditDocumentScreen extends ConsumerStatefulWidget {
  final Document document;

  const EditDocumentScreen({super.key, required this.document});

  @override
  ConsumerState<EditDocumentScreen> createState() =>
      _EditDocumentScreenState();
}

class _EditDocumentScreenState extends ConsumerState<EditDocumentScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleCtrl =
      TextEditingController(text: widget.document.title);
  late final TextEditingController _notesCtrl =
      TextEditingController(text: widget.document.notes ?? '');
  final _metaCtrl = MetadataFormController();
  late String? _documentDate = widget.document.documentDate;
  bool _busy = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDocumentDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _documentDate != null
          ? DateTime.tryParse(_documentDate!) ?? now
          : now,
      firstDate: DateTime(1990),
      lastDate: DateTime(now.year + 10),
    );
    if (picked != null) {
      setState(
          () => _documentDate = picked.toIso8601String().substring(0, 10));
    }
  }

  Future<void> _save() async {
    _metaCtrl.serverErrors.clear();
    if (!_formKey.currentState!.validate()) return;

    final doc = widget.document;
    final patch = <String, dynamic>{};
    final title = _titleCtrl.text.trim();
    if (title != doc.title) patch['title'] = title;
    final notes = _notesCtrl.text.trim();
    if (notes != (doc.notes ?? '')) patch['notes'] = notes;
    if (_documentDate != doc.documentDate) {
      patch['document_date'] = _documentDate;
    }
    final metaPatch = _metaCtrl.patchPayload(doc.metadata);
    if (metaPatch.isNotEmpty) patch['metadata'] = metaPatch;

    if (patch.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }

    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).patchDocument(doc.uuid, patch);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (e.isInvalidMetadata) {
        final field = e.extras['field'] as String?;
        final unknown = (e.extras['unknown_keys'] as List?)?.join(', ');
        if (field != null) {
          _metaCtrl.serverErrors[field] = e.detail;
          _formKey.currentState!.validate();
          return;
        }
        _showError(unknown != null ? '${e.detail} ($unknown)' : e.detail);
      } else {
        if (e.isForbidden) {
          ref
              .read(deniedActionsProvider.notifier)
              .deny(doc.documentType, 'edit_metadata');
        }
        _showError(e.detail);
      }
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final bySlug = ref.watch(documentTypesBySlugProvider);
    final fields = mergedMetadataFields(bySlug, widget.document.documentType);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit document'),
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
                  controller: _titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Title *',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                  enabled: !_busy,
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: _busy ? null : _pickDocumentDate,
                  borderRadius: BorderRadius.circular(4),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Document date',
                      border: const OutlineInputBorder(),
                      suffixIcon: _documentDate != null
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () =>
                                  setState(() => _documentDate = null),
                            )
                          : const Icon(Icons.calendar_today_outlined,
                              size: 18),
                    ),
                    child: Text(_documentDate != null
                        ? formatDate(_documentDate)
                        : ' '),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notesCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                  enabled: !_busy,
                ),
                if (fields.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text('Metadata',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  // Required is not enforced on PATCH (spec §3).
                  MetadataFormFields(
                    fields: fields,
                    controller: _metaCtrl,
                    initialValues: widget.document.metadata,
                    enforceRequired: false,
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
