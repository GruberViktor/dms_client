import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/widgets.dart' as pw;

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/permissions.dart';
import '../state/session.dart';
import '../util/format.dart';
import '../widgets/metadata_form.dart';
import 'document_detail_screen.dart';

/// Upload flow (spec §7 M2): file picker everywhere; on mobile additionally
/// multi-page camera capture combined into a single PDF client-side.
class UploadScreen extends ConsumerStatefulWidget {
  final String? initialTypeSlug;

  /// A file supplied by the caller (e.g. dropped onto the document list),
  /// pre-selected so the user only has to fill in the metadata.
  final PickedFile? initialFile;

  const UploadScreen({super.key, this.initialTypeSlug, this.initialFile});

  @override
  ConsumerState<UploadScreen> createState() => _UploadScreenState();
}

class PickedFile {
  final String filename;
  final Uint8List? bytes;
  final String? path;

  PickedFile({required this.filename, this.bytes, this.path});

  MultipartFile toMultipart() => bytes != null
      ? MultipartFile.fromBytes(bytes!, filename: filename)
      : MultipartFile.fromFileSync(path!, filename: filename);
}

class _UploadScreenState extends ConsumerState<UploadScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _metaCtrl = MetadataFormController();

  String? _typeSlug;
  PickedFile? _file;
  String? _documentDate;
  bool _busy = false;
  bool _titleEdited = false;

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _typeSlug = widget.initialTypeSlug;
    _file = widget.initialFile;
    if (_file != null && _titleCtrl.text.isEmpty) {
      _titleCtrl.text = _stripExtension(_file!.filename);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles(withData: !_isMobile);
    final f = result?.files.firstOrNull;
    if (f == null) return;
    setState(() {
      _file = PickedFile(filename: f.name, bytes: f.bytes, path: f.path);
      if (!_titleEdited && _titleCtrl.text.isEmpty) {
        _titleCtrl.text = _stripExtension(f.name);
      }
    });
  }

  /// Capture N photos and combine them into one PDF (spec §7 M2).
  Future<void> _captureFromCamera() async {
    final picker = ImagePicker();
    final pages = <Uint8List>[];
    while (mounted) {
      final shot = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 2400,
      );
      if (shot == null) break; // user cancelled the camera
      pages.add(await shot.readAsBytes());
      if (!mounted) return;
      final more = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Page ${pages.length} captured'),
          content: const Text('Capture another page?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Done'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Add page'),
            ),
          ],
        ),
      );
      if (more != true) break;
    }
    if (pages.isEmpty || !mounted) return;

    final doc = pw.Document();
    for (final page in pages) {
      final image = pw.MemoryImage(page);
      doc.addPage(pw.Page(
        build: (context) => pw.Center(child: pw.Image(image)),
      ));
    }
    final bytes = Uint8List.fromList(await doc.save());
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    setState(() {
      _file = PickedFile(filename: 'scan-$stamp.pdf', bytes: bytes);
      if (!_titleEdited && _titleCtrl.text.isEmpty) {
        _titleCtrl.text = 'Scan $stamp';
      }
    });
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

  Future<void> _submit({bool force = false}) async {
    if (_file == null) {
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('No file selected'),
          content: const Text('Pick a file or capture pages first.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    _metaCtrl.serverErrors.clear();
    if (!_formKey.currentState!.validate()) return;

    setState(() => _busy = true);
    try {
      final api = ref.read(apiProvider);
      final doc = await api.uploadDocument(
        file: _file!.toMultipart(),
        title: _titleCtrl.text.trim(),
        documentType: _typeSlug!,
        documentDate: _documentDate,
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        metadata: _metaCtrl.createPayload(),
        force: force,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => DocumentDetailScreen(uuid: doc.uuid),
      ));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (e.isDuplicateFile) {
        _showDuplicateDialog(e);
      } else if (e.isInvalidMetadata) {
        final field = e.extras['field'] as String?;
        if (field != null) {
          _metaCtrl.serverErrors[field] = e.detail;
          _formKey.currentState!.validate();
        } else {
          _showError(e.detail);
        }
      } else if (e.isForbidden) {
        ref
            .read(deniedActionsProvider.notifier)
            .deny(_typeSlug!, 'upload_version');
        _showError(e.detail);
      } else {
        _showError(e.detail);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError('Upload failed: $e');
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// duplicate_file 409: show the linkified duplicates and offer
  /// "Upload anyway" (force=true).
  void _showDuplicateDialog(ApiException e) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.copy_all_outlined),
        title: const Text('Identical file already exists'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('The same bytes are already stored in:'),
            const SizedBox(height: 8),
            for (final uuid in e.duplicateOf)
              _DuplicateLink(uuid: uuid, onOpen: () {
                Navigator.pop(context);
                Navigator.of(this.context).push(MaterialPageRoute(
                  builder: (_) => DocumentDetailScreen(uuid: uuid),
                ));
              }),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () {
              Navigator.pop(context);
              _submit(force: true);
            },
            child: const Text('Upload anyway'),
          ),
        ],
      ),
    );
  }

  static String _stripExtension(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  @override
  Widget build(BuildContext context) {
    final types = ref.watch(documentTypesProvider).value ?? const <DocumentType>[];
    final bySlug = ref.watch(documentTypesBySlugProvider);
    final fields =
        _typeSlug != null ? mergedMetadataFields(bySlug, _typeSlug!) : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Upload document')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // --- File source ---
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: _busy ? null : _pickFile,
                              icon: const Icon(Icons.attach_file),
                              label: const Text('Choose file'),
                            ),
                            if (_isMobile) ...[
                              const SizedBox(width: 8),
                              FilledButton.tonalIcon(
                                onPressed: _busy ? null : _captureFromCamera,
                                icon: const Icon(Icons.photo_camera_outlined),
                                label: const Text('Camera'),
                              ),
                            ],
                          ],
                        ),
                        if (_file != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Row(
                              children: [
                                const Icon(Icons.insert_drive_file_outlined,
                                    size: 18),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    _file!.bytes != null
                                        ? '${_file!.filename} · ${formatBytes(_file!.bytes!.length)}'
                                        : _file!.filename,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // --- Type ---
                DropdownButtonFormField<String>(
                  initialValue: _typeSlug,
                  decoration: const InputDecoration(
                    labelText: 'Document type *',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final t in types.where((t) => t.isActive))
                      DropdownMenuItem(
                        value: t.slug,
                        child: Text('${'    ' * t.depth}${t.name}'),
                      ),
                  ],
                  validator: (v) => v == null ? 'Required' : null,
                  onChanged: _busy
                      ? null
                      : (slug) => setState(() => _typeSlug = slug),
                ),
                const SizedBox(height: 12),

                TextFormField(
                  controller: _titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Title *',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                  onChanged: (_) => _titleEdited = true,
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
                    child: Text(
                        _documentDate != null ? formatDate(_documentDate) : ' '),
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

                // --- Typed metadata (from the type's merged definitions) ---
                if (fields != null && fields.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text('Metadata',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  MetadataFormFields(
                    key: ValueKey(_typeSlug),
                    fields: fields,
                    controller: _metaCtrl,
                  ),
                ],

                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _submit(),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_file),
                  label: const Text('Upload'),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DuplicateLink extends StatelessWidget {
  final String uuid;
  final VoidCallback onOpen;

  const _DuplicateLink({required this.uuid, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onOpen,
      icon: const Icon(Icons.open_in_new, size: 16),
      label: Text(uuid, style: const TextStyle(fontFamily: 'monospace')),
    );
  }
}
