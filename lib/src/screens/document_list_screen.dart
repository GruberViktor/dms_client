import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../state/session.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import '../widgets/type_tree.dart';
import 'document_detail_screen.dart';
import 'upload_screen.dart';

enum ArchivedFilter { active, all, archived }

class DocumentFilters {
  final String? typeSlug;
  final ArchivedFilter archived;
  final DateTimeRange? dateRange;
  final Map<String, String> metadata;

  const DocumentFilters({
    this.typeSlug,
    this.archived = ArchivedFilter.active,
    this.dateRange,
    this.metadata = const {},
  });

  DocumentFilters copyWith({
    String? Function()? typeSlug,
    ArchivedFilter? archived,
    DateTimeRange? Function()? dateRange,
    Map<String, String>? metadata,
  }) =>
      DocumentFilters(
        typeSlug: typeSlug != null ? typeSlug() : this.typeSlug,
        archived: archived ?? this.archived,
        dateRange: dateRange != null ? dateRange() : this.dateRange,
        metadata: metadata ?? this.metadata,
      );

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

  final List<Document> _docs = [];
  int _count = 0;
  bool _loading = false;
  bool _initialLoaded = false;
  Object? _error;
  int _requestGen = 0;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_maybeLoadMore);
    _reload();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (_scrollCtrl.position.extentAfter < 400 &&
        !_loading &&
        _docs.length < _count) {
      _loadPage(_docs.length);
    }
  }

  Future<void> _reload() async {
    setState(() {
      _docs.clear();
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

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _filters.dateRange,
    );
    if (range != null) {
      _applyFilters(_filters.copyWith(dateRange: () => range));
    }
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
      body: Column(
        children: [
          _buildFilterBar(context),
          const Divider(height: 1),
          Expanded(child: _buildList(context)),
        ],
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
          const SizedBox(width: 8),
          FilterChip(
            label: Text(_filters.dateRange == null
                ? 'Date range'
                : '${formatDate(_filters.dateRange!.start.toIso8601String())}'
                    ' – ${formatDate(_filters.dateRange!.end.toIso8601String())}'),
            selected: _filters.dateRange != null,
            onSelected: (_) => _pickDateRange(),
            onDeleted: _filters.dateRange != null
                ? () => _applyFilters(_filters.copyWith(dateRange: () => null))
                : null,
            avatar: _filters.dateRange == null
                ? const Icon(Icons.date_range, size: 18)
                : null,
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
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (_error != null) {
      return ErrorRetry(error: _error!, onRetry: _reload);
    }
    if (!_initialLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_docs.isEmpty) {
      return const Center(child: Text('No documents match the filters.'));
    }
    final api = ref.read(apiProvider);
    final bySlug = ref.watch(documentTypesBySlugProvider);
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        controller: _scrollCtrl,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _docs.length + (_docs.length < _count ? 1 : 0),
        separatorBuilder: (context, i) =>
            const Divider(height: 1, indent: 76),
        itemBuilder: (context, i) {
          if (i >= _docs.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final d = _docs[i];
          return ListTile(
            leading: DocumentThumbnail(
              api: api,
              uuid: d.uuid,
              mime: d.mimeType,
              size: 52,
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    d.title,
                    overflow: TextOverflow.ellipsis,
                    style: d.archived
                        ? TextStyle(
                            color: Theme.of(context).colorScheme.outline)
                        : null,
                  ),
                ),
                if (d.inComplianceMode)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(Icons.lock_outline, size: 15),
                  ),
                if (d.archived)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(Icons.inventory_2_outlined, size: 15),
                  ),
              ],
            ),
            subtitle: Text(
              '${bySlug[d.documentType]?.name ?? d.documentType}'
              ' · ${formatDate(d.documentDate)} · ${d.addedBy}',
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => DocumentDetailScreen(uuid: d.uuid),
              ));
              // Archive state etc. may have changed.
              _reload();
            },
          );
        },
      ),
    );
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
