import 'dart:async';
import 'dart:math' as math;

import 'package:decimal/decimal.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/document_feed.dart';
import '../state/session.dart';
import '../state/watches.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import '../widgets/date_range_dropdown.dart';
import '../widgets/document_card.dart';
import '../widgets/sort_control.dart';
import '../widgets/type_tree.dart';
import 'document_detail_screen.dart';
import 'upload_screen.dart';

class DocumentFilters {
  final String query;
  final String? typeSlug;
  final bool archivedOnly;
  final DateTimeRange? dateRange;
  final Map<String, String> metadata;

  const DocumentFilters({
    this.query = '',
    this.typeSlug,
    this.archivedOnly = false,
    this.dateRange,
    this.metadata = const {},
  });

  DocumentFilters copyWith({
    String? query,
    String? Function()? typeSlug,
    bool? archivedOnly,
    DateTimeRange? Function()? dateRange,
    Map<String, String>? metadata,
  }) => DocumentFilters(
    query: query ?? this.query,
    typeSlug: typeSlug != null ? typeSlug() : this.typeSlug,
    archivedOnly: archivedOnly ?? this.archivedOnly,
    dateRange: dateRange != null ? dateRange() : this.dateRange,
    metadata: metadata ?? this.metadata,
  );

  bool get searching => query.isNotEmpty;

  String? get archivedParam => archivedOnly ? 'only' : null;
}

class DocumentListScreen extends ConsumerStatefulWidget {
  const DocumentListScreen({super.key});

  @override
  ConsumerState<DocumentListScreen> createState() => _DocumentListScreenState();
}

class _DocumentListScreenState extends ConsumerState<DocumentListScreen> {
  static const _pageSize = 50;

  /// Content width from which the type tree becomes an inline sidebar instead
  /// of an overlay drawer.
  static const _sidebarBreakpoint = 1000.0;
  static const _sidebarDefaultWidth = 300.0;
  static const _sidebarMinWidth = 180.0;

  /// Static so the expanded/collapsed choice and the dragged sidebar width
  /// survive leaving and re-entering the tab (the shell rebuilds this screen),
  /// for the app's lifetime.
  static bool _sidebarExpanded = true;
  static double _sidebarWidth = _sidebarDefaultWidth;

  DocumentFilters _filters = const DocumentFilters();

  /// Browsing and searching have different defaults (`-date_added` vs
  /// `-rank`); [_applyFilters] swaps them when the mode flips.
  DocumentSort _sort = DocumentSort.browseDefault;

  final _scrollCtrl = ScrollController();
  final _queryCtrl = TextEditingController();
  final _queryFocus = FocusNode();
  final _showClear = ValueNotifier<bool>(false);
  Timer? _debounce;
  Timer? _changeDebounce;

  // Browsing fills `_docs`, searching fills `_hits`; only one is live at a
  // time (see `_filters.searching`). Both hold exactly the current page.
  final List<Document> _docs = [];
  final List<SearchHit> _hits = [];
  int _count = 0;
  int _page = 0;
  bool _loading = false;
  bool _initialLoaded = false;
  Object? _error;
  int _requestGen = 0;
  bool _dragging = false;

  int get _resultCount => _filters.searching ? _hits.length : _docs.length;

  int get _pageCount => (_count + _pageSize - 1) ~/ _pageSize;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _changeDebounce?.cancel();
    _queryCtrl.dispose();
    _queryFocus.dispose();
    _showClear.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() => _loadPage(_page);

  Future<void> _goToPage(int page) async {
    setState(() => _page = page);
    await _loadPage(page);
    if (mounted && _scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
  }

  Future<void> _loadPage(int page) async {
    final gen = ++_requestGen;
    setState(() {
      _loading = true;
      _error = null;
    });
    final offset = page * _pageSize;
    try {
      final api = ref.read(apiProvider);
      final f = _filters;
      if (f.searching) {
        // The search endpoint only knows q/type/archived — the date range and
        // metadata filters are hidden while a query is active.
        final res = await api.search(
          f.query,
          type: f.typeSlug,
          archived: f.archivedParam,
          ordering: _sort.ordering,
          limit: _pageSize,
          offset: offset,
        );
        if (!mounted || gen != _requestGen) return;
        setState(() {
          _hits
            ..clear()
            ..addAll(res.results);
          _docs.clear();
          _count = res.count;
          _initialLoaded = true;
          _loading = false;
        });
      } else {
        final res = await api.documents(
          type: f.typeSlug,
          archived: f.archivedParam,
          dateFrom: f.dateRange?.start.toIso8601String().substring(0, 10),
          dateTo: f.dateRange?.end.toIso8601String().substring(0, 10),
          metadataFilters: f.metadata,
          ordering: _sort.ordering,
          limit: _pageSize,
          offset: offset,
        );
        if (!mounted || gen != _requestGen) return;
        setState(() {
          _docs
            ..clear()
            ..addAll(res.results);
          _hits.clear();
          _count = res.count;
          _initialLoaded = true;
          _loading = false;
        });
      }
      // The page can fall off the end when documents are deleted or filters
      // shrink the set — snap back to the last page that still exists.
      if (_resultCount == 0 && _count > 0 && page > 0) {
        final last = (_count - 1) ~/ _pageSize;
        setState(() => _page = last);
        await _loadPage(last);
      }
    } on ApiException catch (e) {
      if (!mounted || gen != _requestGen) return;
      // Unknown ordering keys are rejected, not ignored — a metadata key can
      // stop existing when the type filter changes. Fall back instead of
      // stranding the list on an error.
      final fallback = _defaultSort(_filters.searching);
      if (e.code == 'invalid_ordering' && _sort != fallback) {
        final rejected = _sort.key.label;
        setState(() => _sort = fallback);
        showSnack(context, 'Sortierung nach „$rejected“ ist hier nicht möglich.');
        return _loadPage(page);
      }
      setState(() {
        _error = e;
        _loading = false;
        _initialLoaded = true;
      });
    } catch (e) {
      if (!mounted || gen != _requestGen) return;
      setState(() {
        _error = e;
        _loading = false;
        _initialLoaded = true;
      });
    }
  }

  static DocumentSort _defaultSort(bool searching) =>
      searching ? DocumentSort.searchDefault : DocumentSort.browseDefault;

  void _applyFilters(DocumentFilters f) {
    setState(() {
      // Relevance exists only while searching, and a search that inherits
      // "newest first" from browsing would hide its own ranking — so the two
      // defaults swap, while a sort the user picked deliberately survives.
      if (f.searching != _filters.searching) {
        if (_sort == _defaultSort(_filters.searching)) {
          _sort = _defaultSort(f.searching);
        } else if (_sort.key == relevanceSortKey) {
          _sort = DocumentSort.browseDefault;
        }
      }
      _filters = f;
      _page = 0;
    });
    _reload();
  }

  void _applySort(DocumentSort sort) {
    setState(() {
      _sort = sort;
      _page = 0;
    });
    _reload();
  }

  void _focusSearch() {
    _queryFocus.requestFocus();
    // Select the existing query so typing starts a fresh search.
    _queryCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _queryCtrl.text.length,
    );
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
    // Suggest the selected type's merged field set (inherited included); with
    // no type selected there is nothing type-specific to offer.
    final slug = _filters.typeSlug;
    final fields = slug == null
        ? const <MetadataFieldDef>[]
        : mergedMetadataFields(ref.read(documentTypesBySlugProvider), slug);
    final result = await showDialog<MapEntry<String, String>?>(
      context: context,
      builder: (_) => _MetadataFilterDialog(fields: fields),
    );
    if (result != null) {
      _applyFilters(
        _filters.copyWith(
          metadata: {..._filters.metadata, result.key: result.value},
        ),
      );
    }
  }

  Future<void> _onDrop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    final items = details.files;
    if (items.isEmpty) return;
    if (items.length > 1) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Bitte nur eine Datei auf einmal ablegen.'),
          ),
        );
      return;
    }
    final x = items.first;
    // On desktop the dropped file has a real path; read bytes as a fallback
    // for platforms where it does not (e.g. web).
    final Uint8List? bytes = x.path.isEmpty ? await x.readAsBytes() : null;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UploadScreen(
          initialTypeSlug: _filters.typeSlug,
          initialFile: PickedFile(
            filename: x.name,
            path: x.path.isEmpty ? null : x.path,
            bytes: bytes,
          ),
        ),
      ),
    );
    _reload();
  }

  /// Watch/unwatch a category — covers the whole subtree (notifications
  /// hand-off §2). Optimistic; the notifier reverts on failure.
  Future<void> _toggleTypeWatch(String slug) async {
    try {
      final on = await ref.read(watchesProvider.notifier).toggleType(slug);
      if (mounted) {
        showSnack(
          context,
          on
              ? 'Kategorie samt Unterkategorien wird beobachtet.'
              : 'Kategorie wird nicht mehr beobachtet.',
        );
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Any change can move a document into or out of the current page, so
    // every event reloads it (the page stays visible meanwhile).
    // ponytail: reloads on all changes server-wide; filter by the uuids on
    // the page plus create/type_change if busy servers make this noisy.
    ref.listen(documentFeedProvider, (_, next) {
      if (next.value is! DocumentChange) return;
      _changeDebounce?.cancel();
      _changeDebounce = Timer(const Duration(seconds: 1), _reload);
    });
    return LayoutBuilder(
      builder: (context, constraints) =>
          _build(context, wide: constraints.maxWidth >= _sidebarBreakpoint),
    );
  }

  Widget _build(BuildContext context, {required bool wide}) {
    final typesAsync = ref.watch(documentTypesProvider);
    final bySlug = ref.watch(documentTypesBySlugProvider);
    final typeName = _filters.typeSlug != null
        ? (bySlug[_filters.typeSlug]?.name ?? _filters.typeSlug!)
        : null;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusSearch,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            // Wide layout has no drawer, so Scaffold inserts no hamburger —
            // this is the sidebar expand/collapse toggle instead.
            leading: wide
                ? IconButton(
                    tooltip: _sidebarExpanded
                        ? 'Kategorien ausblenden'
                        : 'Kategorien einblenden',
                    icon: Icon(_sidebarExpanded ? Icons.menu_open : Icons.menu),
                    onPressed: () =>
                        setState(() => _sidebarExpanded = !_sidebarExpanded),
                  )
                : null,
            title: Text(typeName ?? 'Dokumente'),
            actions: [
              IconButton(
                tooltip: 'Aktualisieren',
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
                    PopupMenuItem(value: 'logout', child: Text('Abmelden')),
                  ],
                ),
            ],
          ),
          // Narrow layouts keep the overlay drawer; wide ones get the inline
          // sidebar below.
          drawer: wide
              ? null
              : Drawer(
                  child: SafeArea(
                    child: _buildTypeTree(
                      typesAsync,
                      onSelected: (slug) {
                        Navigator.of(context).pop();
                        _applyFilters(_filters.copyWith(typeSlug: () => slug));
                      },
                    ),
                  ),
                ),
          body: DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: _onDrop,
            child: Row(
              children: [
                if (wide) _buildSidebar(typesAsync),
                Expanded(
                  child: Stack(
                    children: [
                      Column(
                        children: [
                          _buildSearchRow(
                            context,
                            typesAsync.value ?? const [],
                          ),
                          _buildFilterBar(context),
                          // The progress bar takes over the rule's own band
                          // instead of being inserted above the grid — a
                          // re-sort or page load must not nudge the cards
                          // down and back up. The previous page stays
                          // visible underneath while the next one loads.
                          SizedBox(
                            height: 2,
                            child: _loading && _initialLoaded
                                ? const LinearProgressIndicator(minHeight: 2)
                                : const Divider(height: 2, thickness: 1),
                          ),
                          Expanded(child: _buildResults(context, bySlug)),
                          if (_pageCount > 1) ...[
                            const Divider(height: 1),
                            _buildPager(context),
                          ],
                        ],
                      ),
                      if (_dragging)
                        const DropOverlay(label: 'Datei zum Hochladen ablegen'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.upload_file),
            label: const Text('Hochladen'),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      UploadScreen(initialTypeSlug: _filters.typeSlug),
                ),
              );
              _reload();
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTypeTree(
    AsyncValue<List<DocumentType>> typesAsync, {
    required ValueChanged<String?> onSelected,
  }) {
    return typesAsync.when(
      data: (types) => TypeTree(
        types: types,
        selectedSlug: _filters.typeSlug,
        onSelected: onSelected,
        watchedSlugs: ref.watch(watchesProvider).types,
        onToggleWatch: _toggleTypeWatch,
      ),
      error: (e, _) => ErrorRetry(
        error: e,
        onRetry: () => ref.invalidate(documentTypesProvider),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
    );
  }

  /// Inline type-tree sidebar for wide layouts: collapses to zero width (and
  /// stays out of the layout) instead of overlaying the list like the drawer.
  Widget _buildSidebar(AsyncValue<List<DocumentType>> typesAsync) {
    final theme = Theme.of(context);
    // Never let the tree eat more than half the window, and re-clamp on every
    // build so shrinking the window pulls an over-wide sidebar back in.
    final maxWidth = math.max(
      _sidebarMinWidth,
      MediaQuery.sizeOf(context).width / 2,
    );
    final width = _sidebarWidth.clamp(_sidebarMinWidth, maxWidth);
    return ClipRect(
      child: AnimatedAlign(
        alignment: Alignment.centerLeft,
        widthFactor: _sidebarExpanded ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: SizedBox(
          width: width,
          child: Row(
            children: [
              Expanded(
                child: Material(
                  color: theme.colorScheme.surfaceContainerLow,
                  child: SafeArea(
                    right: false,
                    child: _buildTypeTree(
                      typesAsync,
                      onSelected: (slug) => _applyFilters(
                        _filters.copyWith(typeSlug: () => slug),
                      ),
                    ),
                  ),
                ),
              ),
              _SidebarResizeHandle(
                // Track from the clamped width, not the stored one, so a drag
                // that hit a bound doesn't have to "unwind" slack first.
                onDrag: (dx) => setState(
                  () => _sidebarWidth = (width + dx).clamp(
                    _sidebarMinWidth,
                    maxWidth,
                  ),
                ),
                onReset: () =>
                    setState(() => _sidebarWidth = _sidebarDefaultWidth),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPager(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.first_page),
              tooltip: 'Erste Seite',
              visualDensity: VisualDensity.compact,
              onPressed: _page > 0 ? () => _goToPage(0) : null,
            ),
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Vorherige Seite',
              visualDensity: VisualDensity.compact,
              onPressed: _page > 0 ? () => _goToPage(_page - 1) : null,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'Seite ${_page + 1} von $_pageCount',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Nächste Seite',
              visualDensity: VisualDensity.compact,
              onPressed: _page < _pageCount - 1
                  ? () => _goToPage(_page + 1)
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.last_page),
              tooltip: 'Letzte Seite',
              visualDensity: VisualDensity.compact,
              onPressed: _page < _pageCount - 1
                  ? () => _goToPage(_pageCount - 1)
                  : null,
            ),
          ],
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
                focusNode: _queryFocus,
                style: theme.textTheme.bodyMedium,
                textInputAction: TextInputAction.search,
                onChanged: _onQueryChanged,
                onSubmitted: (_) => _submitQuery(),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest,
                  hintText: 'Titel, Metadaten, Volltext durchsuchen',
                  hintStyle: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                  contentPadding: EdgeInsets.zero,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 38,
                    minHeight: height,
                  ),
                  suffixIcon: ValueListenableBuilder<bool>(
                    valueListenable: _showClear,
                    builder: (context, show, _) => show
                        ? IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Suche löschen',
                            onPressed: _clearQuery,
                          )
                        : const SizedBox.shrink(),
                  ),
                  suffixIconConstraints: const BoxConstraints(
                    minWidth: 38,
                    minHeight: height,
                  ),
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
              hintText: 'Alle Typen',
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
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
                border: border,
                enabledBorder: border,
                focusedBorder: border.copyWith(
                  borderSide: BorderSide(color: theme.colorScheme.primary),
                ),
              ),
              dropdownMenuEntries: [
                const DropdownMenuEntry<String?>(
                  value: null,
                  label: 'Alle Typen',
                ),
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
    // Metadata sort keys are offered for the selected type's merged field set,
    // the same suggestions the metadata filter dialog uses.
    final slug = _filters.typeSlug;
    final sortableMetadata = slug == null
        ? const <MetadataFieldDef>[]
        : mergedMetadataFields(ref.read(documentTypesBySlugProvider), slug);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          SortControl(
            sort: _sort,
            searching: _filters.searching,
            metadataFields: sortableMetadata,
            onChanged: _applySort,
          ),
          const SizedBox(width: 8),
          // Date range and metadata filters are list-only server-side.
          if (!_filters.searching) ...[
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
              label: const Text('Metadatenfilter'),
              onPressed: _editMetadataFilter,
            ),
            const SizedBox(width: 8),
          ],
          FilterChip(
            label: const Text('Archiviert'),
            selected: _filters.archivedOnly,
            visualDensity: VisualDensity.compact,
            showCheckmark: true,
            tooltip: 'Nur archivierte Dokumente anzeigen',
            onSelected: (on) =>
                _applyFilters(_filters.copyWith(archivedOnly: on)),
          ),
          if (_filters.searching && _initialLoaded && _error == null) ...[
            const SizedBox(width: 12),
            Text(
              _count == 1 ? '1 Treffer' : '$_count Treffer',
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
        child: Text(
          _filters.searching
              ? 'Keine Dokumente passen zu „${_filters.query}“.'
              : 'Keine Dokumente passen zu den Filtern.',
        ),
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
      itemCount: _resultCount,
      itemBuilder: (context, i) {
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
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => DocumentDetailScreen(uuid: uuid)));
    // Archive state etc. may have changed.
    _reload();
  }
}

/// Splitter on the sidebar's trailing edge: draws the same 1px rule the
/// [VerticalDivider] did, but widens and tints on hover/drag and carries an
/// 8px hit area so it can be grabbed without pixel-hunting. Double-tap resets.
class _SidebarResizeHandle extends StatefulWidget {
  final ValueChanged<double> onDrag;
  final VoidCallback onReset;

  const _SidebarResizeHandle({required this.onDrag, required this.onReset});

  @override
  State<_SidebarResizeHandle> createState() => _SidebarResizeHandleState();
}

class _SidebarResizeHandleState extends State<_SidebarResizeHandle> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = _hovered || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) => setState(() => _dragging = false),
        onHorizontalDragCancel: () => setState(() => _dragging = false),
        onDoubleTap: widget.onReset,
        child: SizedBox(
          width: 8,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: active ? 3 : 1,
              height: double.infinity,
              color: active ? theme.colorScheme.primary : theme.dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _MetadataFilterDialog extends StatefulWidget {
  const _MetadataFilterDialog({required this.fields});

  /// Merged field set of the selected type; empty when no type is selected,
  /// in which case the key is free text.
  final List<MetadataFieldDef> fields;

  @override
  State<_MetadataFilterDialog> createState() => _MetadataFilterDialogState();
}

class _MetadataFilterDialogState extends State<_MetadataFilterDialog> {
  final _keyCtrl = TextEditingController();
  final _keyFocus = FocusNode();
  final _valueCtrl = TextEditingController();

  /// The value as it goes on the wire. Text-ish types mirror `_valueCtrl`;
  /// bool and date are picked, so they only live here.
  String _value = '';
  String? _matchedKey;

  @override
  void initState() {
    super.initState();
    _keyCtrl.addListener(_onKeyChanged);
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _keyFocus.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  /// A different known key means a different value editor, so the old value
  /// (formatted for the previous type) is dropped.
  void _onKeyChanged() {
    final m = _matched;
    if (m?.key == _matchedKey) {
      setState(() {});
      return;
    }
    setState(() {
      _matchedKey = m?.key;
      _valueCtrl.clear();
      // A bool filter has only two values — start on the useful one.
      _value = m?.fieldType == FieldType.boolean ? 'true' : '';
    });
  }

  MetadataFieldDef? get _matched {
    final k = _keyCtrl.text.trim();
    for (final f in widget.fields) {
      if (f.key == k) return f;
    }
    return null;
  }

  void _submit() {
    final k = _keyCtrl.text.trim();
    if (k.isEmpty) return;
    Navigator.pop(context, MapEntry(k, _value.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final matched = _matched;
    return AlertDialog(
      title: const Text('Nach Metadaten filtern'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _keyField(),
            const SizedBox(height: 8),
            _valueField(matched),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Anwenden')),
      ],
    );
  }

  Widget _keyField() {
    final decoration = InputDecoration(
      labelText: 'Schlüssel',
      hintText: widget.fields.isEmpty ? 'z. B. invoice_number' : null,
      helperText: widget.fields.isEmpty
          ? 'Dokumenttyp wählen, um Schlüssel vorgeschlagen zu bekommen'
          : null,
      suffixIcon: widget.fields.isEmpty
          ? null
          : IconButton(
              icon: const Icon(Icons.arrow_drop_down),
              tooltip: 'Felder anzeigen',
              // Re-focusing an already focused field does not reopen the
              // options list, so drop focus first.
              onPressed: () {
                _keyFocus.unfocus();
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _keyFocus.requestFocus(),
                );
              },
            ),
    );
    if (widget.fields.isEmpty) {
      return TextField(
        controller: _keyCtrl,
        focusNode: _keyFocus,
        decoration: decoration,
        autofocus: true,
        onSubmitted: (_) => _submit(),
      );
    }
    return RawAutocomplete<MetadataFieldDef>(
      textEditingController: _keyCtrl,
      focusNode: _keyFocus,
      displayStringForOption: (f) => f.key,
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        if (q.isEmpty) return widget.fields;
        return widget.fields.where(
          (f) =>
              f.key.toLowerCase().contains(q) ||
              f.label.toLowerCase().contains(q),
        );
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) =>
          TextField(
            controller: controller,
            focusNode: focusNode,
            decoration: decoration,
            autofocus: true,
            onSubmitted: (_) => onFieldSubmitted(),
          ),
      // The key listener resets the value; nothing to do on selection.
      onSelected: (_) {},
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260, maxWidth: 360),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: options.length,
              itemBuilder: (context, i) {
                final f = options.elementAt(i);
                return ListTile(
                  dense: true,
                  title: Text(f.label),
                  subtitle: Text('${f.key} · ${f.fieldType.label}'),
                  onTap: () => onSelected(f),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// One editor per field type, each producing the wire form the server
  /// stores in `metadata` (bool → true/false, monetary → decimal string,
  /// date → YYYY-MM-DD). Unknown keys stay free text.
  Widget _valueField(MetadataFieldDef? f) {
    final helper = f != null ? '${f.label} · ${f.fieldType.label}' : null;
    switch (f?.fieldType) {
      case FieldType.boolean:
        return InputDecorator(
          decoration: InputDecoration(
            labelText: 'Wert',
            helperText: helper,
            border: const OutlineInputBorder(),
          ),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'true', label: Text('Ja')),
              ButtonSegment(value: 'false', label: Text('Nein')),
            ],
            selected: {if (_value == 'true' || _value == 'false') _value},
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: (s) => setState(() => _value = s.first),
          ),
        );
      case FieldType.date:
        return InkWell(
          onTap: _pickDate,
          borderRadius: BorderRadius.circular(4),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'Wert',
              helperText: helper,
              suffixIcon: _value.isEmpty
                  ? const Icon(Icons.calendar_today_outlined, size: 18)
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      tooltip: 'Löschen',
                      onPressed: () => setState(() => _value = ''),
                    ),
            ),
            child: Text(_value.isEmpty ? ' ' : formatDate(_value)),
          ),
        );
      case FieldType.integer:
        return _textValueField(
          helper: helper,
          hint: 'z. B. 42',
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9-]'))],
        );
      case FieldType.float:
      case FieldType.monetary:
        return _textValueField(
          helper: helper,
          hint: 'z. B. 1234,56',
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,-]'))],
          // Monetary values are compared as strings, so the comma form has to
          // be normalized the same way the upload form normalizes it.
          transform: f?.fieldType == FieldType.monetary
              ? _normalizeDecimal
              : null,
        );
      case FieldType.url:
        return _textValueField(
          helper: helper,
          hint: 'https://…',
          keyboardType: TextInputType.url,
        );
      default:
        return _textValueField(
          helper: helper,
          hint: f == null ? null : 'exakter Wert',
        );
    }
  }

  Widget _textValueField({
    String? helper,
    String? hint,
    TextInputType? keyboardType,
    List<TextInputFormatter>? formatters,
    String Function(String)? transform,
  }) {
    return TextField(
      controller: _valueCtrl,
      decoration: InputDecoration(
        labelText: 'Wert',
        hintText: hint,
        helperText: helper,
      ),
      keyboardType: keyboardType,
      inputFormatters: formatters,
      onChanged: (v) =>
          _value = transform != null ? transform(v.trim()) : v.trim(),
      onSubmitted: (_) => _submit(),
    );
  }

  static String _normalizeDecimal(String text) {
    try {
      return Decimal.parse(text.replaceAll(',', '.')).toString();
    } on FormatException {
      return text;
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_value) ?? now,
      firstDate: DateTime(1990),
      lastDate: DateTime(now.year + 10),
    );
    if (picked != null) {
      setState(() => _value = picked.toIso8601String().substring(0, 10));
    }
  }
}
