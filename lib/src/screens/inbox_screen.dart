import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/permissions.dart';
import '../state/session.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import '../widgets/metadata_form.dart';
import 'document_detail_screen.dart';
import 'upload_screen.dart';

/// No push events for inbox items exist yet — poll while one is processing.
const _pollInterval = Duration(seconds: 4);

const _statusLabels = {
  'processing': 'In Verarbeitung',
  'ready': 'Bereit',
  'failed': 'Fehlgeschlagen',
  'accepted': 'Übernommen',
  'rejected': 'Verworfen',
};

/// Shared document inbox (inbox hand-off): uploaded files wait here until a
/// user accepts (→ normal document) or rejects them.
class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  final _scroll = ScrollController();
  List<InboxItem> _items = [];
  int _count = 0;
  Object? _error;
  bool _loading = true;
  bool _loadingMore = false;
  bool _uploading = false;
  bool _dragging = false;
  String? _status; // null = all
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    var processing = false;
    try {
      final api = ref.read(apiProvider);
      // Ask the server, not the visible rows: under the "Bereit" filter the
      // processing items are not listed, yet must show up once ready. Count
      // first, list second — an item finishing in between is then listed.
      processing =
          (await api.inboxItems(status: 'processing', limit: 1)).count > 0;
      final page = await api.inboxItems(status: _status);
      if (!mounted) return;
      setState(() {
        _items = page.results;
        _count = page.count;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (!quiet) _error = e;
        _loading = false;
      });
    }
    // ponytail: the poll refetches page 1 only; items loaded further down
    // drop out until the user scrolls again.
    if (processing && _poll == null) {
      _poll = Timer.periodic(_pollInterval, (_) => _load(quiet: true));
    } else if (!processing) {
      _poll?.cancel();
      _poll = null;
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
          .inboxItems(status: _status, offset: _items.length);
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

  Future<void> _pickFiles() async {
    final mobile = Platform.isAndroid || Platform.isIOS;
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: !mobile,
    );
    if (result == null) return;
    _upload([
      for (final f in result.files)
        PickedFile(filename: f.name, bytes: f.bytes, path: f.path),
    ]);
  }

  Future<void> _onDrop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    // Desktop drops carry a real path; read bytes where they do not.
    final files = [
      for (final x in details.files)
        PickedFile(
          filename: x.name,
          path: x.path.isEmpty ? null : x.path,
          bytes: x.path.isEmpty ? await x.readAsBytes() : null,
        ),
    ];
    _upload(files);
  }

  Future<void> _upload(List<PickedFile> files) async {
    if (files.isEmpty || _uploading) return;
    setState(() => _uploading = true);
    try {
      await ref.read(apiProvider).uploadInboxFiles([
        for (final f in files) f.toMultipart(),
      ]);
      if (!mounted) return;
      showSnack(context, '${files.length} Datei(en) hochgeladen.');
      _load();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _open(InboxItem item) async {
    final nav = Navigator.of(context);
    if (item.status == 'accepted' && item.document != null) {
      await nav.push(
        MaterialPageRoute(
          builder: (_) => DocumentDetailScreen(uuid: item.document!),
        ),
      );
    } else if (item.isOpen) {
      await nav.push(
        MaterialPageRoute(builder: (_) => InboxReviewScreen(uuid: item.uuid)),
      );
    } else {
      return; // rejected: nothing to open
    }
    if (mounted) _load(quiet: true);
  }

  @override
  Widget build(BuildContext context) {
    final bySlug = ref.watch(documentTypesBySlugProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dokumenteingang'),
        actions: [
          IconButton(
            tooltip: 'Aktualisieren',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploading ? null : _pickFiles,
        icon: _uploading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.upload_file),
        label: const Text('Dateien hochladen'),
      ),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: _onDrop,
        child: Stack(
          children: [
            _buildList(bySlug),
            if (_dragging)
              const DropOverlay(label: 'Dateien in den Eingang ablegen'),
          ],
        ),
      ),
    );
  }

  Widget _buildList(Map<String, DocumentType> bySlug) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Wrap(
              spacing: 8,
              children: [
                for (final s in [
                  null,
                  'ready',
                  'processing',
                  'failed',
                  'accepted',
                  'rejected',
                ])
                  ChoiceChip(
                    label: Text(s == null ? 'Alle' : _statusLabels[s]!),
                    selected: _status == s,
                    onSelected: (_) {
                      setState(() => _status = s);
                      _load();
                    },
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : _loading
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
              ? Center(
                  child: Text(
                    'Keine Einträge.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: _items.length + (_loadingMore ? 1 : 0),
                    itemBuilder: (context, i) => i >= _items.length
                        ? const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        : _InboxTile(
                            item: _items[i],
                            bySlug: bySlug,
                            onTap: () => _open(_items[i]),
                          ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _InboxTile extends StatelessWidget {
  final InboxItem item;
  final Map<String, DocumentType> bySlug;
  final VoidCallback onTap;

  const _InboxTile({
    required this.item,
    required this.bySlug,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final suggested = item.suggestion?.documentType;
    final details = [
      formatDateTime(item.uploadedAt),
      ?item.uploadedBy,
      formatBytes(item.size),
      if (item.status == 'ready' && suggested != null)
        'Vorschlag: ${bySlug[suggested]?.name ?? suggested}',
      if (item.reviewedBy != null) 'geprüft von ${item.reviewedBy}',
    ];
    final statusColor = switch (item.status) {
      'ready' => scheme.primary,
      'failed' => scheme.error,
      _ => scheme.onSurfaceVariant,
    };
    return ListTile(
      enabled: item.status != 'rejected',
      leading: Icon(mimeIcon(item.mimeType)),
      title: Text(item.originalFilename, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(details.join(' · ')),
          if (item.duplicateOf.isNotEmpty && item.isOpen)
            Text(
              'Identische Datei bereits vorhanden',
              style: TextStyle(color: scheme.error),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (item.status == 'processing')
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Text(
            _statusLabels[item.status] ?? item.status,
            style: theme.textTheme.labelMedium?.copyWith(color: statusColor),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Review one item: file preview next to a form pre-filled from the
/// suggestion; accept files it as a document, reject discards it.
class InboxReviewScreen extends ConsumerStatefulWidget {
  final String uuid;

  const InboxReviewScreen({super.key, required this.uuid});

  @override
  ConsumerState<InboxReviewScreen> createState() => _InboxReviewScreenState();
}

class _InboxReviewScreenState extends ConsumerState<InboxReviewScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  MetadataFormController _metaCtrl = MetadataFormController();

  InboxItem? _item;
  Object? _error;
  Timer? _poll;
  bool _busy = false;
  bool? _acceptingNext; // which accept button is running (spinner)

  // Form state, filled once from the suggestion when the item is ready.
  bool _prefilled = false;
  String? _typeSlug;
  String? _documentDate;
  Map<String, dynamic> _metaInitial = const {};
  bool _titleSuggested = false;
  bool _dateSuggested = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final item = await ref.read(apiProvider).inboxItem(widget.uuid);
      if (!mounted) return;
      _apply(item);
    } catch (e) {
      if (mounted && _item == null) setState(() => _error = e);
    }
  }

  void _apply(InboxItem item) {
    setState(() {
      _item = item;
      _error = null;
      if (item.status == 'ready' && !_prefilled) _prefill(item);
    });
    if (item.status == 'processing') {
      _poll ??= Timer.periodic(_pollInterval, (_) => _load());
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  void _prefill(InboxItem item) {
    _prefilled = true;
    final s = item.suggestion;
    final bySlug = ref.read(documentTypesBySlugProvider);
    final type = s?.documentType;
    _typeSlug = type != null && bySlug[type]?.isActive == true ? type : null;
    _metaCtrl = MetadataFormController();
    _metaInitial = _typeSlug != null ? s!.metadata : const {};
    _titleSuggested = (s?.title ?? '').isNotEmpty;
    _titleCtrl.text = _titleSuggested
        ? s!.title
        : _stripExtension(item.originalFilename);
    _documentDate = s?.documentDate;
    _dateSuggested = _documentDate != null;
  }

  static String _stripExtension(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// Rebuilds the metadata form; values whose keys exist in the new type
  /// carry over (the form ignores the others).
  void _setType(String? slug) {
    if (slug == _typeSlug) return;
    setState(() {
      _metaInitial = _metaCtrl.createPayload();
      _metaCtrl = MetadataFormController();
      _typeSlug = slug;
    });
  }

  Future<void> _pickDocumentDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_documentDate ?? '') ?? now,
      firstDate: DateTime(1990),
      lastDate: DateTime(now.year + 10),
    );
    if (picked != null) {
      setState(() {
        _documentDate = picked.toIso8601String().substring(0, 10);
        _dateSuggested = false;
      });
    }
  }

  /// [next]: go on to the next ready item ("save and next"); otherwise
  /// open the created document.
  Future<void> _accept({required bool next}) async {
    final item = _item!;
    _metaCtrl.serverErrors.clear();
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _acceptingNext = next;
    });
    final api = ref.read(apiProvider);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final doc = await api.acceptInboxItem(
        item.uuid,
        documentType: _typeSlug!,
        title: _titleCtrl.text.trim(),
        documentDate: _documentDate,
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        metadata: _metaCtrl.createPayload(),
        // The duplicate warning is on screen; accepting means "file anyway".
        force: item.duplicateOf.isNotEmpty,
      );
      if (!next) {
        nav.pushReplacement(
          MaterialPageRoute(
            builder: (_) => DocumentDetailScreen(uuid: doc.uuid),
          ),
        );
        return;
      }
      String? nextUuid;
      try {
        final page = await api.inboxItems(status: 'ready', limit: 2);
        nextUuid = page.results
            .map((i) => i.uuid)
            .where((u) => u != item.uuid)
            .firstOrNull;
      } catch (_) {
        /* back to the list */
      }
      if (nextUuid == null) {
        nav.pop();
      } else {
        nav.pushReplacement(
          MaterialPageRoute(builder: (_) => InboxReviewScreen(uuid: nextUuid!)),
        );
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              nextUuid == null
                  ? '„${doc.title}“ übernommen. Keine weiteren Einträge bereit.'
                  : '„${doc.title}“ übernommen.',
            ),
            action: SnackBarAction(
              label: 'Öffnen',
              onPressed: () => nav.push(
                MaterialPageRoute(
                  builder: (_) => DocumentDetailScreen(uuid: doc.uuid),
                ),
              ),
            ),
          ),
        );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _acceptingNext = null;
      });
      if (e.isInvalidMetadata && e.extras['field'] is String) {
        _metaCtrl.serverErrors[e.extras['field'] as String] = e.detail;
        _formKey.currentState!.validate();
        return;
      }
      if (e.isForbidden) {
        ref
            .read(deniedActionsProvider.notifier)
            .deny(_typeSlug!, 'upload_version');
      }
      showSnack(context, e.detail);
      // 409 duplicate_file / 400 wrong status: the reload shows why.
      if (e.isDuplicateFile || e.statusCode == 400) _load();
    }
  }

  Future<void> _reject() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eintrag verwerfen?'),
        content: const Text('Die Datei wird gelöscht.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Verwerfen'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).rejectInboxItem(widget.uuid);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, e.detail);
      _load();
    }
  }

  Future<void> _reprocess() async {
    setState(() => _busy = true);
    try {
      final item = await ref.read(apiProvider).reprocessInboxItem(widget.uuid);
      if (!mounted) return;
      _prefilled = false; // take the new suggestion once it is ready
      _apply(item);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      appBar: AppBar(
        title: Text(item?.originalFilename ?? 'Eingang'),
        actions: [
          if (item != null &&
              (item.status == 'ready' || item.status == 'failed'))
            IconButton(
              tooltip: 'Neu vorschlagen lassen',
              icon: const Icon(Icons.auto_awesome_outlined),
              onPressed: _busy ? null : _reprocess,
            ),
          if (item != null && item.isOpen)
            IconButton(
              tooltip: 'Verwerfen',
              icon: const Icon(Icons.delete_outline),
              onPressed: _busy ? null : _reject,
            ),
        ],
      ),
      body: _error != null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : item == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, c) {
                final preview = _InboxFilePreview(item: item);
                final side = _buildSide(item);
                if (c.maxWidth >= 900) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: preview,
                        ),
                      ),
                      SizedBox(width: 440, child: side),
                    ],
                  );
                }
                return ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(height: 480, child: preview),
                    ),
                    side,
                  ],
                );
              },
            ),
    );
  }

  Widget _buildSide(InboxItem item) {
    final scheme = Theme.of(context).colorScheme;
    final children = <Widget>[
      if (item.duplicateOf.isNotEmpty && item.isOpen)
        _DuplicateWarning(uuids: item.duplicateOf),
      switch (item.status) {
        'processing' => const ListTile(
          leading: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text('Wird verarbeitet …'),
          subtitle: Text('Text wird erkannt und ein Vorschlag erstellt.'),
        ),
        'failed' => ListTile(
          leading: Icon(Icons.error_outline, color: scheme.error),
          title: const Text('Verarbeitung fehlgeschlagen'),
          subtitle: Text(item.error ?? ''),
        ),
        'ready' => _buildForm(item),
        _ => ListTile(title: Text(_statusLabels[item.status] ?? item.status)),
      },
    ];
    // Wide layout: the side panel scrolls on its own.
    return LayoutBuilder(
      builder: (context, c) => c.hasBoundedHeight
          ? ListView(padding: const EdgeInsets.all(16), children: children)
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: children),
            ),
    );
  }

  Widget _buildForm(InboxItem item) {
    final types =
        ref.watch(documentTypesProvider).value ?? const <DocumentType>[];
    final bySlug = ref.watch(documentTypesBySlugProvider);
    final s = item.suggestion;
    final fields = _typeSlug != null
        ? mergedMetadataFields(bySlug, _typeSlug!)
        : null;
    final selected = bySlug[_typeSlug];
    final active = types.where((t) => t.isActive).toList();
    // Suggested type first, then the model's runners-up, as one-click chips.
    final alternatives = [
      ?s?.documentType,
      ...?s?.alternatives,
    ].where((slug) => bySlug[slug]?.isActive == true).toList();
    final typeHelp = [
      if (s?.documentType != null && _typeSlug == s!.documentType)
        'Vorschlag${s.confidence != null ? ' (${(s.confidence! * 100).round()} %)' : ''}',
      if (selected != null && selected.description.isNotEmpty)
        selected.description,
    ].join(' · ');
    final suggestedKeys = {
      if (s != null && _typeSlug == s.documentType)
        for (final e in s.metadata.entries)
          if (_metaInitial[e.key] == e.value) e.key,
    };

    const spinner = SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (s == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Kein Vorschlag vorhanden – bitte manuell ausfüllen.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          DropdownButtonFormField<String>(
            key: ValueKey(_typeSlug),
            initialValue: _typeSlug,
            isExpanded: true,
            itemHeight: null,
            decoration: InputDecoration(
              labelText: 'Dokumenttyp *',
              border: const OutlineInputBorder(),
              helperText: typeHelp.isEmpty ? null : typeHelp,
              helperMaxLines: 3,
            ),
            selectedItemBuilder: (_) => [
              for (final t in active)
                Text(t.name, overflow: TextOverflow.ellipsis),
            ],
            items: [
              for (final t in active)
                DropdownMenuItem(
                  value: t.slug,
                  child: Padding(
                    padding: EdgeInsets.only(left: 16.0 * t.depth),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(t.name),
                        if (t.description.isNotEmpty)
                          Text(
                            t.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ),
            ],
            validator: (v) => v == null ? 'Pflichtfeld' : null,
            onChanged: _busy ? null : _setType,
          ),
          if (alternatives.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final slug in alternatives)
                    ChoiceChip(
                      label: Text(bySlug[slug]!.name),
                      selected: slug == _typeSlug,
                      onSelected: _busy ? null : (_) => _setType(slug),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _titleCtrl,
            decoration: InputDecoration(
              labelText: 'Titel *',
              border: const OutlineInputBorder(),
              helperText: _titleSuggested ? suggestionHint : null,
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Pflichtfeld' : null,
            onChanged: (_) {
              if (_titleSuggested) setState(() => _titleSuggested = false);
            },
            enabled: !_busy,
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: _busy ? null : _pickDocumentDate,
            borderRadius: BorderRadius.circular(4),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Dokumentdatum',
                border: const OutlineInputBorder(),
                helperText: _dateSuggested ? suggestionHint : null,
                suffixIcon: _documentDate != null
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setState(() {
                          _documentDate = null;
                          _dateSuggested = false;
                        }),
                      )
                    : const Icon(Icons.calendar_today_outlined, size: 18),
              ),
              child: Text(
                _documentDate != null ? formatDate(_documentDate) : ' ',
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _notesCtrl,
            decoration: const InputDecoration(
              labelText: 'Notizen',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
            enabled: !_busy,
          ),
          if (fields != null && fields.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Metadaten', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            MetadataFormFields(
              key: ValueKey(_typeSlug),
              fields: fields,
              controller: _metaCtrl,
              initialValues: _metaInitial,
              suggestedKeys: suggestedKeys,
            ),
          ],
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _accept(next: false),
                icon: _acceptingNext == false
                    ? spinner
                    : const Icon(Icons.open_in_new),
                label: const Text('Übernehmen & öffnen'),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : () => _accept(next: true),
                icon: _acceptingNext == true
                    ? spinner
                    : const Icon(Icons.skip_next),
                label: const Text('Übernehmen & weiter'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DuplicateWarning extends StatelessWidget {
  final List<String> uuids;

  const _DuplicateWarning({required this.uuids});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Genau diese Datei ist bereits gespeichert in:',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
            for (final uuid in uuids)
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DocumentDetailScreen(uuid: uuid),
                  ),
                ),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(
                  uuid,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            Text(
              'Übernehmen legt sie trotzdem als neues Dokument an.',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ],
        ),
      ),
    );
  }
}

/// The original file: PDF in pdfrx, images directly, anything else as the
/// extracted text. Inbox items have no server-rendered previews yet.
class _InboxFilePreview extends ConsumerStatefulWidget {
  final InboxItem item;

  const _InboxFilePreview({required this.item});

  @override
  ConsumerState<_InboxFilePreview> createState() => _InboxFilePreviewState();
}

class _InboxFilePreviewState extends ConsumerState<_InboxFilePreview> {
  final _controller = PdfViewerController();
  Uint8List? _bytes;
  bool _failed = false;

  bool get _isImage => (widget.item.mimeType ?? '').startsWith('image/');
  bool get _isPdf => isPdfMime(widget.item.mimeType);

  @override
  void initState() {
    super.initState();
    if (_isPdf || _isImage) _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await ref.read(apiProvider).inboxFile(widget.item.uuid);
      if (mounted) setState(() => _bytes = bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget child;
    if ((_isPdf || _isImage) && !_failed) {
      child = _bytes == null
          ? const Center(child: CircularProgressIndicator())
          : _isPdf
          ? PdfViewer.data(
              _bytes!,
              sourceName: 'inbox/${widget.item.uuid}',
              controller: _controller,
              params: PdfViewerParams(
                backgroundColor: scheme.surfaceContainerHighest,
                scrollByMouseWheel: 1.0,
                viewerOverlayBuilder: (context, size, handleLinkTap) => [
                  PdfViewerScrollThumb(controller: _controller),
                ],
              ),
            )
          : InteractiveViewer(
              maxScale: 5,
              child: Center(child: Image.memory(_bytes!)),
            );
    } else if (widget.item.content.isNotEmpty) {
      child = SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(widget.item.content),
      );
    } else {
      child = Center(
        child: Icon(
          mimeIcon(widget.item.mimeType),
          size: 64,
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
