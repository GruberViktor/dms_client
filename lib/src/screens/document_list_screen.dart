import 'dart:async';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../state/session.dart';
import '../widgets/common.dart';
import '../widgets/date_range_dropdown.dart';
import '../widgets/document_card.dart';
import '../widgets/type_tree.dart';
import 'document_detail_screen.dart';
import 'upload_screen.dart';

enum ArchivedFilter { active, all, archived }

class DocumentFilters {
  final String query;
  final String? typeSlug;
  final ArchivedFilter archived;
  final DateTimeRange? dateRange;
  final Map<String, String> metadata;

  const DocumentFilters({
    this.query = '',
    this.typeSlug,
    this.archived = ArchivedFilter.active,
    this.dateRange,
    this.metadata = const {},
  });

  DocumentFilters copyWith({
    String? query,
    String? Function()? typeSlug,
    ArchivedFilter? archived,
    DateTimeRange? Function()? dateRange,
    Map<String, String>? metadata,
  }) =>
      DocumentFilters(
        query: query ?? this.query,
        typeSlug: typeSlug != null ? typeSlug() : this.typeSlug,
        archived: archived ?? this.archived,
        dateRange: dateRange != null ? dateRange() : this.dateRange,
        metadata: metadata ?? this.metadata,
      );

  bool get searching => query.isNotEmpty;

  String? get archivedParam => switch (archived) {
        ArchivedFilter.active => null,
        ArchivedFilter.all => 'true',
        ArchivedFilter.archived => 'only',
      };
}

class DocumentListScreen extends ConsumerStatefulWidget {
  const DocumentListScreen({super.key});

  @override
  ConsumerState<DocumentListScreen> createState() => _DocumentListScreenState();
}

class _DocumentListScreenState extends ConsumerState<DocumentListScreen> {
  DocumentFilters _filters = const DocumentFilters();
  final _scrollCtrl = ScrollController();
  final _queryCtrl = TextEditingController();
  final _showClear = ValueNotifier<bool>(false);
  Timer? _debounce;

  // Browsing fills `_docs`, searching fills `_hits`; only one is live at a
  // time (see `_filters.searching`).
  final List<Document> _docs = [];
  final List<SearchHit> _hits = [];
  int _count = 0;
  bool _loading = false;
  bool _initialLoaded = false;
  Object? _error;
  int _requestGen = 0;
  bool _dragging = false;

  int get _resultCount => _filters.searching ? _hits.length : _docs.length;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_maybeLoadMore);
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryCtrl.dispose();
    _showClear.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (_scrollCtrl.position.extentAfter < 400 &&
        !_loading &&
        _resultCount < _count) {
      _loadPage(_resultCount);
    }
  }

  Future<void> _reload() async {
    setState(() {
      _docs.clear();
      _hits.clear();
      _count = 0;
      _initialLoaded = false;
      _error = null;
    });
    await _loadPage(0);
  }

  Future<void> _loadPage(int offset) async {
    final gen = ++_requestGen;
    setState(() => _loading = true);
    try {
      final api = ref.read(apiProvider);
      final f = _filters;
      if (f.searching) {
        // The search endpoint only knows q/type/archived — the date range and
        // metadata filters are hidden while a query is active.
        final page = await api.search(
          f.query,
          type: f.typeSlug,
          archived: f.archivedParam,
          offset: offset,
        );
        if (!mounted || gen != _requestGen) return;
        setState(() {
          if (offset == 0) _hits.clear();
          _hits.addAll(page.results);
          _count = page.count;
          _initialLoaded = true;
          _loading = false;
        });
      } else {
        final page = await api.documents(
          type: f.typeSlug,
          archived: f.archivedParam,
          dateFrom: f.dateRange?.start.toIso8601String().substring(0, 10),
          dateTo: f.dateRange?.end.toIso8601String().substring(0, 10),
          metadataFilters: f.metadata,
          offset: offset,
        );
        if (!mounted || gen != _requestGen) return;
        setState(() {
          if (offset == 0) _docs.clear();
          _docs.addAll(page.results);
          _count = page.count;
          _initialLoaded = true;
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted || gen != _requestGen) return;
      setState(() {
        _error = e;
        _loading = false;
        _initialLoaded = true;
      });
    }
  }

  void _applyFilters(DocumentFilters f) {
    setState(() => _filters = f);
    _reload();
  }

  void _onQueryChanged(String value) {
    // Only the clear button depends on the raw text; a ValueNotifier repaints
    // just that icon instead of the whole result list on every keystroke.
    _showClear.value = value.isNotEmpty;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      final q = value.trim();
      if (q == _filters.query) return;
      _applyFilters(_filters.copyWith(query: q));
    });
  }

  void _submitQuery() {
    _debounce?.cancel();
    _applyFilters(_filters.copyWith(query: _queryCtrl.text.trim()));
  }

  void _clearQuery() {
    _debounce?.cancel();
    _queryCtrl.clear();
    _showClear.value = false;
    _applyFilters(_filters.copyWith(query: ''));
  }

  Future<void> _editMetadataFilter() async {
    final result = await showDialog<MapEntry<String, String>?>(
      context: context,
      builder: (_) => const _MetadataFilterDialog(),
    );
    if (result != null) {
      _applyFilters(_filters.copyWith(
        metadata: {..._filters.metadata, result.key: result.value},
      ));
    }
  }

  Future<void> _onDrop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    final items = details.files;
    if (items.isEmpty) return;
    if (items.length > 1) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Drop one file at a time to upload.'),
        ));
      return;
    }
    final x = items.first;
    // On desktop the dropped file has a real path; read bytes as a fallback
    // for platforms where it does not (e.g. web).
    final Uint8List? bytes = x.path.isEmpty ? await x.readAsBytes() : null;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => UploadScreen(
        initialTypeSlug: _filters.typeSlug,
        initialFile: PickedFile(
          filename: x.name,
          path: x.path.isEmpty ? null : x.path,
          bytes: bytes,
        ),
      ),
    ));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final typesAsync = ref.watch(documentTypesProvider);
    final bySlug = ref.watch(documentTypesBySlugProvider);
    final typeName = _filters.typeSlug != null
        ? (bySlug[_filters.typeSlug]?.name ?? _filters.typeSlug!)
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(typeName ?? 'Documents'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
          if (MediaQuery.sizeOf(context).width < 700)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'logout') {
                  ref.read(sessionProvider.notifier).logout();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'logout', child: Text('Sign out')),
              ],
            ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: typesAsync.when(
            data: (types) => TypeTree(
              types: types,
              selectedSlug: _filters.typeSlug,
              onSelected: (slug) {
                Navigator.of(context).pop();
                _applyFilters(_filters.copyWith(typeSlug: () => slug));
              },
            ),
            error: (e, _) => ErrorRetry(
              error: e,
              onRetry: () => ref.invalidate(documentTypesProvider),
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
          ),
        ),
      ),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: _onDrop,
        child: Stack(
          children: [
            Column(
              children: [
                _buildSearchRow(context, typesAsync.value ?? const []),
                _buildFilterBar(context),
                const Divider(height: 1),
                Expanded(child: _buildResults(context, bySlug)),
              ],
            ),
            if (_dragging) _buildDropOverlay(context),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.upload_file),
        label: const Text('Upload'),
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => UploadScreen(initialTypeSlug: _filters.typeSlug),
          ));
          _reload();
        },
      ),
    );
  }

  Widget _buildDropOverlay(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.primary, width: 2),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.file_download_outlined,
                    size: 48, color: scheme.onPrimaryContainer),
                const SizedBox(height: 12),
                Text(
                  'Drop file to upload',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onPrimaryContainer,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Compact full-text search field plus the type picker, on one row.
  Widget _buildSearchRow(BuildContext context, List<DocumentType> types) {
    final theme = Theme.of(context);
    const height = 40.0;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(height / 2),
      borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: height,
              child: TextField(
                controller: _queryCtrl,
                style: theme.textTheme.bodyMedium,
                textInputAction: TextInputAction.search,
                onChanged: _onQueryChanged,
                onSubmitted: (_) => _submitQuery(),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest,
                  hintText: 'Search title, metadata, full text',
                  hintStyle: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.outline),
                  contentPadding: EdgeInsets.zero,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 38, minHeight: height),
                  suffixIcon: ValueListenableBuilder<bool>(
                    valueListenable: _showClear,
                    builder: (context, show, _) => show
                        ? IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Clear search',
                            onPressed: _clearQuery,
                          )
                        : const SizedBox.shrink(),
                  ),
                  suffixIconConstraints:
                      const BoxConstraints(minWidth: 38, minHeight: height),
                  border: border,
                  enabledBorder: border,
                  focusedBorder: border.copyWith(
                    borderSide: BorderSide(color: theme.colorScheme.primary),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: height,
            width: 190,
            child: DropdownMenu<String?>(
              // Rebuild when the drawer tree changes the selection, so the
              // field text stays in sync with the filter.
              key: ValueKey(_filters.typeSlug),
              initialSelection: _filters.typeSlug,
              hintText: 'All types',
              menuHeight: 420,
              expandedInsets: EdgeInsets.zero,
              textStyle: theme.textTheme.bodyMedium,
              trailingIcon: const Icon(Icons.arrow_drop_down, size: 20),
              selectedTrailingIcon: const Icon(Icons.arrow_drop_up, size: 20),
              inputDecorationTheme: InputDecorationTheme(
                isDense: true,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                hintStyle: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.outline),
                border: border,
                enabledBorder: border,
                focusedBorder: border.copyWith(
                  borderSide: BorderSide(color: theme.colorScheme.primary),
                ),
              ),
              dropdownMenuEntries: [
                const DropdownMenuEntry<String?>(
                    value: null, label: 'All types'),
                for (final t in types)
                  DropdownMenuEntry<String?>(
                    value: t.slug,
                    label: '${'  ' * t.depth}${t.name}',
                  ),
              ],
              onSelected: (slug) =>
                  _applyFilters(_filters.copyWith(typeSlug: () => slug)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          SegmentedButton<ArchivedFilter>(
            segments: const [
              ButtonSegment(
                  value: ArchivedFilter.active, label: Text('Active')),
              ButtonSegment(value: ArchivedFilter.all, label: Text('All')),
              ButtonSegment(
                  value: ArchivedFilter.archived, label: Text('Archived')),
            ],
            selected: {_filters.archived},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
            ),
            onSelectionChanged: (s) =>
                _applyFilters(_filters.copyWith(archived: s.first)),
          ),
          // Date range and metadata filters are list-only server-side.
          if (!_filters.searching) ...[
            const SizedBox(width: 8),
            DateRangeDropdown(
              value: _filters.dateRange,
              firstDate: DateTime(2000),
              lastDate: DateTime(DateTime.now().year + 1, 12, 31),
              onChanged: (range) =>
                  _applyFilters(_filters.copyWith(dateRange: () => range)),
            ),
            const SizedBox(width: 8),
            for (final e in _filters.metadata.entries) ...[
              InputChip(
                label: Text('${e.key} = ${e.value}'),
                onDeleted: () {
                  final m = {..._filters.metadata}..remove(e.key);
                  _applyFilters(_filters.copyWith(metadata: m));
                },
              ),
              const SizedBox(width: 8),
            ],
            ActionChip(
              avatar: const Icon(Icons.add, size: 18),
              label: const Text('Metadata filter'),
              onPressed: _editMetadataFilter,
            ),
          ],
          if (_filters.searching && _initialLoaded && _error == null) ...[
            const SizedBox(width: 12),
            Text(
              _count == 1 ? '1 result' : '$_count results',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context, Map<String, DocumentType> bySlug) {
    if (_error != null) {
      return ErrorRetry(error: _error!, onRetry: _reload);
    }
    if (!_initialLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_resultCount == 0) {
      return Center(
        child: Text(_filters.searching
            ? 'No documents match “${_filters.query}”.'
            : 'No documents match the filters.'),
      );
    }
    return RefreshIndicator(onRefresh: _reload, child: _buildGrid(bySlug));
  }

  /// One grid for both modes — search hits render as the same cards, minus the
  /// mime icon and lock badge the search payload does not carry.
  Widget _buildGrid(Map<String, DocumentType> bySlug) {
    final api = ref.read(apiProvider);
    return GridView.builder(
      controller: _scrollCtrl,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        mainAxisExtent: 340,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _resultCount + (_resultCount < _count ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _resultCount) {
          return const Center(child: CircularProgressIndicator());
        }
        if (_filters.searching) {
          final h = _hits[i];
          return DocumentCard.hit(
            api: api,
            hit: h,
            typeName: bySlug[h.documentType]?.name ?? h.documentType,
            onOpen: () => _openDocument(h.uuid),
          );
        }
        final d = _docs[i];
        return DocumentCard(
          api: api,
          document: d,
          typeName: bySlug[d.documentType]?.name ?? d.documentType,
          onOpen: () => _openDocument(d.uuid),
        );
      },
    );
  }

  Future<void> _openDocument(String uuid) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DocumentDetailScreen(uuid: uuid),
    ));
    // Archive state etc. may have changed.
    _reload();
  }
}

class _MetadataFilterDialog extends StatefulWidget {
  const _MetadataFilterDialog();

  @override
  State<_MetadataFilterDialog> createState() => _MetadataFilterDialogState();
}

class _MetadataFilterDialogState extends State<_MetadataFilterDialog> {
  final _keyCtrl = TextEditingController();
  final _valueCtrl = TextEditingController();

  @override
  void dispose() {
    _keyCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Filter by metadata'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _keyCtrl,
            decoration: const InputDecoration(
              labelText: 'Key',
              hintText: 'e.g. invoice_number',
            ),
            autofocus: true,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _valueCtrl,
            decoration: const InputDecoration(labelText: 'Value'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final k = _keyCtrl.text.trim();
            if (k.isEmpty) return;
            Navigator.pop(context, MapEntry(k, _valueCtrl.text.trim()));
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
