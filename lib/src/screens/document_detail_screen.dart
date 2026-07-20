import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/edit_sessions.dart';
import '../state/permissions.dart';
import '../state/session.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import '../widgets/timeline.dart';
import 'edit_document_screen.dart';

class DocumentDetailScreen extends ConsumerStatefulWidget {
  final String uuid;

  const DocumentDetailScreen({super.key, required this.uuid});

  @override
  ConsumerState<DocumentDetailScreen> createState() =>
      _DocumentDetailScreenState();
}

class _DocumentDetailScreenState extends ConsumerState<DocumentDetailScreen> {
  Document? _doc;
  List<TimelineEvent>? _events;
  Object? _error;
  Timer? _pollTimer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final api = ref.read(apiProvider);
      final doc = await api.document(widget.uuid);
      List<TimelineEvent>? events;
      try {
        events = await api.timeline(widget.uuid);
      } on ApiException {
        events = null; // timeline may be forbidden; the rest still works
      }
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _events = events;
      });
      _schedulePollIfExtracting();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  /// Poll while any visible version is pending/running OCR (spec §3).
  void _schedulePollIfExtracting() {
    _pollTimer?.cancel();
    final extracting =
        _doc?.versions.any(
          (v) =>
              !v.isHidden &&
              (v.extractionStatus == ExtractionStatus.pending ||
                  v.extractionStatus == ExtractionStatus.running),
        ) ??
        false;
    if (extracting) {
      _pollTimer = Timer(const Duration(seconds: 4), _load);
    }
  }

  Future<void> _toggleArchive() async {
    final doc = _doc!;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiProvider);
      if (doc.archived) {
        await api.unarchiveDocument(doc.uuid);
      } else {
        await api.archiveDocument(doc.uuid);
      }
      if (mounted) {
        showSnack(context, doc.archived ? 'Unarchived.' : 'Archived.');
      }
      await _load();
    } on ApiException catch (e) {
      if (e.isForbidden) _recordDenied('archive');
      if (mounted) showSnack(context, e.detail);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final doc = _doc!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete document?'),
        content: Text('"${doc.title}" will be permanently deleted.'),
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
      await ref.read(apiProvider).deleteDocument(doc.uuid);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isComplianceLocked) {
        _showComplianceDialog();
      } else {
        if (e.isForbidden) _recordDenied('delete');
        showSnack(context, e.detail);
      }
    }
  }

  void _showComplianceDialog() {
    final doc = _doc!;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: const Text('Under retention'),
        content: Text(
          'This document is in compliance mode'
          '${doc.retentionUntil != null ? ' until ${formatDate(doc.retentionUntil)}' : ''} '
          'and cannot be deleted or have its file replaced.\n\n'
          'You can still upload a new version, edit metadata, or archive it '
          'to get it out of the default lists.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
          if (!doc.archived)
            FilledButton.tonal(
              onPressed: () {
                Navigator.pop(context);
                _toggleArchive();
              },
              child: const Text('Archive instead'),
            ),
        ],
      ),
    );
  }

  Future<void> _downloadAndOpen(DocumentVersion v) async {
    final doc = _doc!;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiProvider);
      final bytes = await api.downloadVersion(doc.uuid, v.number);
      final dir = await getTemporaryDirectory();
      final safeName = v.originalFilename.isNotEmpty
          ? v.originalFilename.replaceAll(RegExp(r'[/\\]'), '_')
          : 'document';
      final file = File('${dir.path}/dms/${doc.uuid}/v${v.number}/$safeName');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      final result = await OpenFilex.open(file.path);
      if (mounted && result.type != ResultType.done) {
        showSnack(context, 'Saved to ${file.path}');
      }
    } on ApiException catch (e) {
      if (e.isForbidden) _recordDenied('download');
      if (mounted) showSnack(context, e.detail);
    } catch (e) {
      if (mounted) showSnack(context, 'Download failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _recordDenied(String action) {
    final doc = _doc;
    if (doc != null) {
      ref.read(deniedActionsProvider.notifier).deny(doc.documentType, action);
    }
  }

  Future<void> _editDocument() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EditDocumentScreen(document: _doc!)),
    );
    if (changed == true) _load();
  }

  Future<MultipartFile?> _pickMultipart() async {
    final result = await FilePicker.pickFiles(withData: false);
    final f = result?.files.firstOrNull;
    if (f == null) return null;
    if (f.path != null) {
      return MultipartFile.fromFileSync(f.path!, filename: f.name);
    }
    final bytes = f.bytes;
    if (bytes == null) return null;
    return MultipartFile.fromBytes(bytes, filename: f.name);
  }

  Future<void> _uploadNewVersion({
    MultipartFile? file,
    bool force = false,
  }) async {
    final picked = file ?? await _pickMultipart();
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(apiProvider)
          .uploadVersion(_doc!.uuid, picked, force: force);
      if (mounted) showSnack(context, 'New version uploaded.');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isDuplicateFile) {
        _showVersionDuplicateDialog(e, picked);
      } else {
        if (e.isForbidden) _recordDenied('upload_version');
        showSnack(context, e.detail);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Same bytes exist already; a retry must re-read the file since a
  /// MultipartFile stream can only be consumed once.
  void _showVersionDuplicateDialog(ApiException e, MultipartFile sent) {
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
              TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(
                  uuid,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.of(this.context).push(
                    MaterialPageRoute(
                      builder: (_) => DocumentDetailScreen(uuid: uuid),
                    ),
                  );
                },
              ),
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
              _uploadNewVersion(file: sent.clone(), force: true);
            },
            child: const Text('Upload anyway'),
          ),
        ],
      ),
    );
  }

  static bool get _isDesktop =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  /// Hide a version ("wrong upload") with an optional reason (M4).
  Future<void> _hideVersion(DocumentVersion v) async {
    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hide version ${v.number}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The version stays stored but is struck through in the '
              'timeline and no longer counts as "the document".',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'e.g. wrong upload',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hide version'),
          ),
        ],
      ),
    );
    final reason = reasonCtrl.text.trim();
    reasonCtrl.dispose();
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(apiProvider)
          .hideVersion(
            _doc!.uuid,
            v.number,
            reason: reason.isEmpty ? null : reason,
          );
      await _load();
    } on ApiException catch (e) {
      // e.g. "cannot hide the only visible version"
      if (mounted) showSnack(context, e.detail);
    }
  }

  Future<void> _unhideVersion(DocumentVersion v) async {
    try {
      await ref.read(apiProvider).unhideVersion(_doc!.uuid, v.number);
      await _load();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    }
  }

  Future<void> _reExtract(DocumentVersion v) async {
    try {
      await ref.read(apiProvider).reExtract(_doc!.uuid, v.number);
      if (mounted) showSnack(context, 'Re-extraction queued.');
      await _load(); // status back to pending → polling resumes
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    }
  }

  /// Change the document type (409s in compliance mode; not offered there).
  Future<void> _changeType() async {
    final doc = _doc!;
    final types =
        ref.read(documentTypesProvider).value ?? const <DocumentType>[];
    String? selected;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change document type'),
        content: StatefulBuilder(
          builder: (context, setState) => DropdownButtonFormField<String>(
            initialValue: selected,
            decoration: const InputDecoration(
              labelText: 'New type',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final t in types.where(
                (t) => t.isActive && t.slug != doc.documentType,
              ))
                DropdownMenuItem(
                  value: t.slug,
                  child: Text('${'    ' * t.depth}${t.name}'),
                ),
            ],
            onChanged: (v) => setState(() => selected = v),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Change type'),
          ),
        ],
      ),
    );
    if (confirmed != true || selected == null || !mounted) return;
    try {
      await ref.read(apiProvider).changeType(doc.uuid, selected!);
      if (mounted) showSnack(context, 'Type changed.');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isComplianceLocked) {
        _showComplianceDialog();
      } else if (e.isInvalidMetadata) {
        showSnack(
          context,
          '${e.detail} — adjust the metadata first, then change the type.',
        );
      } else {
        if (e.isForbidden) _recordDenied('edit_metadata');
        showSnack(context, e.detail);
      }
    }
  }

  /// M3 round-trip editing: download, open externally, watch for changes.
  Future<void> _openAndEdit(DocumentVersion v) async {
    setState(() => _busy = true);
    try {
      await ref.read(editSessionsProvider.notifier).start(_doc!, v);
      if (mounted) {
        showSnack(
          context,
          'Opened ${v.originalFilename} — watching for changes.',
        );
      }
    } on ApiException catch (e) {
      if (e.isForbidden) _recordDenied('download');
      if (mounted) showSnack(context, e.detail);
    } catch (e) {
      if (mounted) showSnack(context, 'Could not open the file: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editUploadNewVersion() async {
    try {
      await ref
          .read(editSessionsProvider.notifier)
          .uploadAsNewVersion(_doc!.uuid);
      if (mounted) showSnack(context, 'Uploaded as new version.');
      await _load();
    } on ApiException catch (e) {
      if (e.isForbidden) _recordDenied('upload_version');
      if (mounted) showSnack(context, e.detail);
    } catch (e) {
      if (mounted) showSnack(context, 'Upload failed: $e');
    }
  }

  Future<void> _editReplaceFile() async {
    try {
      await ref.read(editSessionsProvider.notifier).replaceFile(_doc!.uuid);
      if (mounted) showSnack(context, 'File replaced.');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isComplianceLocked) {
        _showComplianceDialog();
      } else {
        if (e.isForbidden) _recordDenied('upload_version');
        showSnack(context, e.detail);
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Upload failed: $e');
    }
  }

  /// Replace bytes in place — never offered in compliance mode (spec §3).
  Future<void> _replaceFile(DocumentVersion v) async {
    final picked = await _pickMultipart();
    if (picked == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Replace file of version ${v.number}?'),
        content: const Text(
          'The stored bytes will be overwritten in place. To keep history, '
          'upload a new version instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(apiProvider)
          .replaceVersionFile(_doc!.uuid, v.number, picked);
      if (mounted) showSnack(context, 'File replaced.');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isComplianceLocked) {
        _showComplianceDialog();
      } else {
        if (e.isForbidden) _recordDenied('upload_version');
        showSnack(context, e.detail);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: ErrorRetry(error: _error!, onRetry: _load),
      );
    }
    if (doc == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final current = doc.currentVersion;
    final bySlug = ref.watch(documentTypesBySlugProvider);
    final typeName = bySlug[doc.documentType]?.name ?? doc.documentType;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final denied = ref.watch(deniedActionsProvider.notifier);
    final canEdit = !denied.isDenied(doc.documentType, 'edit_metadata');
    final canUpload = !denied.isDenied(doc.documentType, 'upload_version');
    final editSession = ref.watch(editSessionsProvider)[doc.uuid];

    final infoColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (editSession != null) ...[
          _EditSessionBanner(
            session: editSession,
            canUpload: canUpload,
            onUploadNewVersion: _editUploadNewVersion,
            onReplaceFile: _editReplaceFile,
            onStop: () =>
                ref.read(editSessionsProvider.notifier).stop(doc.uuid),
          ),
          const SizedBox(height: 12),
        ],
        _MetadataCard(doc: doc, typeName: typeName, bySlug: bySlug),
        const SizedBox(height: 12),
        _VersionsCard(
          doc: doc,
          onDownload: _busy ? null : _downloadAndOpen,
          onOpenEdit: (_busy || !_isDesktop) ? null : _openAndEdit,
          onUploadVersion: (_busy || !canUpload)
              ? null
              : () => _uploadNewVersion(),
          // Replace-in-place is never offered in compliance mode (§3).
          onReplaceFile: (_busy || doc.inComplianceMode || !canUpload)
              ? null
              : _replaceFile,
          onHide: (_busy || !canUpload) ? null : _hideVersion,
          onUnhide: (_busy || !canUpload) ? null : _unhideVersion,
          onReExtract: (_busy || !canUpload) ? null : _reExtract,
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Timeline',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                if (_events == null)
                  const Text('Timeline not available.')
                else
                  DocumentTimeline(events: _events!),
              ],
            ),
          ),
        ),
      ],
    );

    final preview = current != null
        ? _PreviewPager(
            api: ref.read(apiProvider),
            uuid: doc.uuid,
            version: current,
          )
        : const SizedBox.shrink();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Flexible(child: Text(doc.title, overflow: TextOverflow.ellipsis)),
            if (doc.inComplianceMode)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: ComplianceBadge(retentionUntil: doc.retentionUntil),
              ),
          ],
        ),
        actions: [
          if (canEdit)
            IconButton(
              tooltip: 'Edit metadata',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _busy ? null : _editDocument,
            ),
          if (current != null)
            IconButton(
              tooltip: 'Download & open',
              icon: const Icon(Icons.open_in_new),
              onPressed: _busy ? null : () => _downloadAndOpen(current),
            ),
          IconButton(
            tooltip: doc.archived ? 'Unarchive' : 'Archive',
            icon: Icon(
              doc.archived
                  ? Icons.unarchive_outlined
                  : Icons.inventory_2_outlined,
            ),
            onPressed: _busy ? null : _toggleArchive,
          ),
          // In compliance mode the server 409s deletes — don't offer the
          // button; the lock badge explains why.
          if (!doc.inComplianceMode)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: _busy ? null : _delete,
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          if (!doc.inComplianceMode && canEdit)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'change_type') _changeType();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'change_type',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.swap_horiz),
                    title: Text('Change type'),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: preview,
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
                    child: infoColumn,
                  ),
                ),
              ],
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (current != null) SizedBox(height: 420, child: preview),
                  const SizedBox(height: 12),
                  infoColumn,
                ],
              ),
            ),
    );
  }
}

class _MetadataCard extends StatelessWidget {
  final Document doc;
  final String typeName;
  final Map<String, DocumentType> bySlug;

  const _MetadataCard({
    required this.doc,
    required this.typeName,
    required this.bySlug,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fieldDefs = {
      for (final f in mergedMetadataFields(bySlug, doc.documentType)) f.key: f,
    };
    final extracting = doc.versions.any(
      (v) =>
          !v.isHidden &&
          (v.extractionStatus == ExtractionStatus.pending ||
              v.extractionStatus == ExtractionStatus.running),
    );

    Widget row(String label, Widget value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: value),
        ],
      ),
    );

    Widget textRow(String label, String value) =>
        row(label, Text(value, style: theme.textTheme.bodyMedium));

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Details', style: theme.textTheme.titleMedium),
                ),
                if (extracting)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'processing…',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            textRow('Type', typeName),
            textRow('Document date', formatDate(doc.documentDate)),
            textRow('Added', formatDateTime(doc.dateAdded)),
            textRow('Added by', doc.addedBy),
            if (doc.retentionUntil != null)
              textRow('Retention until', formatDate(doc.retentionUntil)),
            if (doc.notes?.isNotEmpty ?? false) textRow('Notes', doc.notes!),
            if (doc.metadata.isNotEmpty) ...[
              const Divider(height: 20),
              for (final e in doc.metadata.entries)
                textRow(
                  fieldDefs[e.key]?.label ?? e.key,
                  _formatMetadataValue(fieldDefs[e.key], e.value),
                ),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatMetadataValue(MetadataFieldDef? def, Object? value) {
    if (value == null) return '—';
    switch (def?.fieldType) {
      case FieldType.date:
        return formatDate('$value');
      case FieldType.boolean:
        return value == true ? 'Yes' : 'No';
      case FieldType.monetary:
        return '$value'; // decimal string from the server, shown verbatim
      default:
        return '$value';
    }
  }
}

/// Round-trip editing status card: shows the watching/changed/uploading
/// state of an [EditSession] and the compliance-aware upload choices.
class _EditSessionBanner extends StatelessWidget {
  final EditSession session;
  final bool canUpload;
  final VoidCallback onUploadNewVersion;
  final VoidCallback onReplaceFile;
  final VoidCallback onStop;

  const _EditSessionBanner({
    required this.session,
    required this.canUpload,
    required this.onUploadNewVersion,
    required this.onReplaceFile,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final changed = session.phase == EditPhase.changed;
    final uploading = session.phase == EditPhase.uploading;

    return Card(
      margin: EdgeInsets.zero,
      color: changed ? scheme.tertiaryContainer : scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (uploading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    changed
                        ? Icons.upload_file_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    uploading
                        ? 'Uploading ${session.fileName}…'
                        : changed
                        ? '${session.fileName} changed on disk'
                        : 'Editing v${session.versionNumber} — watching '
                              '${session.fileName} for changes',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Stop watching',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: uploading ? null : onStop,
                ),
              ],
            ),
            if (changed) ...[
              const SizedBox(height: 8),
              Text(
                session.compliance
                    ? 'This document is under retention: the change can only '
                          'be uploaded as version ${session.versionNumber + 1}.'
                    : 'Upload the change as version '
                          '${session.versionNumber + 1}, or overwrite the file '
                          'of version ${session.versionNumber} in place.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: canUpload ? onUploadNewVersion : null,
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: Text('Upload as v${session.versionNumber + 1}'),
                  ),
                  if (!session.compliance)
                    OutlinedButton.icon(
                      onPressed: canUpload ? onReplaceFile : null,
                      icon: const Icon(Icons.find_replace, size: 18),
                      label: Text('Replace file in v${session.versionNumber}'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VersionsCard extends StatelessWidget {
  final Document doc;
  final void Function(DocumentVersion)? onDownload;
  final void Function(DocumentVersion)? onOpenEdit;
  final VoidCallback? onUploadVersion;
  final void Function(DocumentVersion)? onReplaceFile;
  final void Function(DocumentVersion)? onHide;
  final void Function(DocumentVersion)? onUnhide;
  final void Function(DocumentVersion)? onReExtract;

  const _VersionsCard({
    required this.doc,
    required this.onDownload,
    required this.onOpenEdit,
    required this.onUploadVersion,
    required this.onReplaceFile,
    required this.onHide,
    required this.onUnhide,
    required this.onReExtract,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final versions = [...doc.versions]
      ..sort((a, b) => b.number.compareTo(a.number));
    final currentNumber = doc.currentVersion?.number;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Versions', style: theme.textTheme.titleMedium),
                ),
                if (onUploadVersion != null)
                  FilledButton.tonalIcon(
                    onPressed: onUploadVersion,
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: const Text('New version'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (final v in versions)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  mimeIcon(v.mimeType),
                  color: v.isHidden
                      ? theme.colorScheme.outline
                      : theme.colorScheme.primary,
                ),
                title: Text(
                  'v${v.number} · ${v.originalFilename}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    decoration: v.isHidden ? TextDecoration.lineThrough : null,
                    color: v.isHidden ? theme.colorScheme.outline : null,
                    fontWeight: v.number == currentNumber
                        ? FontWeight.w600
                        : null,
                  ),
                ),
                subtitle: Text(
                  v.isHidden
                      ? 'Hidden${v.hiddenBy != null ? ' by ${v.hiddenBy}' : ''}'
                            '${(v.hiddenReason?.isNotEmpty ?? false) ? ': ${v.hiddenReason}' : ''}'
                      : '${formatBytes(v.size)} · ${v.uploadedBy}'
                            ' · ${formatDateTime(v.uploadedAt)}'
                            '${v.extractionStatus == ExtractionStatus.failed ? ' · OCR failed' : ''}',
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!v.isHidden) ...[
                      if (onOpenEdit != null)
                        IconButton(
                          tooltip: 'Open & edit (watch for changes)',
                          icon: const Icon(Icons.edit_document, size: 20),
                          onPressed: () => onOpenEdit!(v),
                        ),
                      if (onReplaceFile != null)
                        IconButton(
                          tooltip: 'Replace file in place',
                          icon: const Icon(Icons.find_replace, size: 20),
                          onPressed: () => onReplaceFile!(v),
                        ),
                      IconButton(
                        tooltip: 'Download & open',
                        icon: const Icon(Icons.file_download_outlined),
                        onPressed: onDownload != null
                            ? () => onDownload!(v)
                            : null,
                      ),
                    ],
                    if ((v.consoleUrl != null && v.consoleUrl!.isNotEmpty) ||
                        (v.isHidden
                            ? onUnhide != null
                            : (onHide != null || onReExtract != null)))
                      PopupMenuButton<String>(
                        onSelected: (action) => switch (action) {
                          'console' => launchUrl(
                            Uri.parse(v.consoleUrl!),
                            mode: LaunchMode.externalApplication,
                          ),
                          'hide' => onHide!(v),
                          'unhide' => onUnhide!(v),
                          're-extract' => onReExtract!(v),
                          _ => null,
                        },
                        itemBuilder: (context) => [
                          if (v.isHidden)
                            const PopupMenuItem(
                              value: 'unhide',
                              child: ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.visibility_outlined),
                                title: Text('Unhide'),
                              ),
                            )
                          else ...[
                            if (onHide != null)
                              const PopupMenuItem(
                                value: 'hide',
                                child: ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.visibility_off_outlined),
                                  title: Text('Hide (wrong upload)…'),
                                ),
                              ),
                            if (onReExtract != null)
                              const PopupMenuItem(
                                value: 're-extract',
                                child: ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.refresh),
                                  title: Text('Re-run text extraction'),
                                ),
                              ),
                          ],
                          if (v.consoleUrl != null && v.consoleUrl!.isNotEmpty)
                            const PopupMenuItem(
                              value: 'console',
                              child: ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.open_in_new),
                                title: Text('Open in console'),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Page-by-page viewer over the server-rendered preview endpoint.
/// Non-previewable formats (404) fall back to a mime icon + hint.
class _PreviewPager extends StatefulWidget {
  final ApiClient api;
  final String uuid;
  final DocumentVersion version;

  const _PreviewPager({
    required this.api,
    required this.uuid,
    required this.version,
  });

  @override
  State<_PreviewPager> createState() => _PreviewPagerState();
}

class _PreviewPagerState extends State<_PreviewPager> {
  late final PageController _controller;
  int _page = 1;

  int get _pageCount => widget.version.pageCount ?? 1;

  @override
  void initState() {
    super.initState();
    _controller = PageController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: PageView.builder(
              controller: _controller,
              itemCount: _pageCount,
              onPageChanged: (i) => setState(() => _page = i + 1),
              itemBuilder: (context, i) => InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: Image.network(
                    widget.api.versionPreviewUrl(
                      widget.uuid,
                      widget.version.number,
                      page: i + 1,
                    ),
                    headers: widget.api.authHeaders,
                    fit: BoxFit.contain,
                    // Lazy pages may take ~1s to render server-side.
                    loadingBuilder: (context, child, progress) =>
                        progress == null
                        ? child
                        : const Center(child: CircularProgressIndicator()),
                    errorBuilder: (context, e, st) => Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          mimeIcon(widget.version.mimeType),
                          size: 64,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No preview for this format.\nUse "Download & open".',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_pageCount > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _page > 1
                      ? () => _controller.previousPage(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                        )
                      : null,
                ),
                Text('$_page / $_pageCount'),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _page < _pageCount
                      ? () => _controller.nextPage(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                        )
                      : null,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
