import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/session.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import 'document_detail_screen.dart';
import 'index_edit_screen.dart';

/// Lists the user-defined index tree views (§4 /indexes/).
class IndexListScreen extends ConsumerStatefulWidget {
  const IndexListScreen({super.key});

  @override
  ConsumerState<IndexListScreen> createState() => _IndexListScreenState();
}

class _IndexListScreenState extends ConsumerState<IndexListScreen> {
  List<DmsIndex>? _indexes;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final list = await ref.read(apiProvider).indexes();
      if (mounted) setState(() => _indexes = list);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _delete(DmsIndex ix) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete index "${ix.name}"?'),
        content: const Text('Only the view is removed — documents stay.'),
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
      await ref.read(apiProvider).deleteIndex(ix.slug);
      _load();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    }
  }

  Future<void> _openEditor([DmsIndex? existing]) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => IndexEditScreen(existing: existing),
    ));
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Indexes')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New index'),
        onPressed: () => _openEditor(),
      ),
      body: _error != null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : _indexes == null
              ? const Center(child: CircularProgressIndicator())
              : _indexes!.isEmpty
                  ? const Center(child: Text('No indexes defined yet.'))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          for (final ix in _indexes!)
                            ListTile(
                              leading:
                                  const Icon(Icons.account_tree_outlined),
                              title: Text(ix.name),
                              subtitle: Text(
                                [
                                  for (final l in ix.levels)
                                    l.source == 'metadata'
                                        ? (l.sourceKey ?? 'metadata')
                                        : l.source,
                                ].join(' › '),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (ix.shared)
                                    const Tooltip(
                                      message: 'Shared',
                                      child: Icon(Icons.group_outlined,
                                          size: 18),
                                    ),
                                  PopupMenuButton<String>(
                                    onSelected: (a) => a == 'edit'
                                        ? _openEditor(ix)
                                        : _delete(ix),
                                    itemBuilder: (context) => const [
                                      PopupMenuItem(
                                          value: 'edit',
                                          child: Text('Edit')),
                                      PopupMenuItem(
                                          value: 'delete',
                                          child: Text('Delete')),
                                    ],
                                  ),
                                ],
                              ),
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => IndexDrillScreen(
                                      index: ix, path: const []),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
    );
  }
}

/// One drill level: shows {value, count} nodes, or the document list at
/// leaf depth.
class IndexDrillScreen extends ConsumerStatefulWidget {
  final DmsIndex index;
  final List<String> path;

  const IndexDrillScreen({super.key, required this.index, required this.path});

  @override
  ConsumerState<IndexDrillScreen> createState() => _IndexDrillScreenState();
}

class _IndexDrillScreenState extends ConsumerState<IndexDrillScreen> {
  List<IndexNode>? _nodes;
  final List<Document> _docs = [];
  int _count = 0;
  bool _isLeaf = false;
  bool _loading = false;
  bool _loaded = false;
  Object? _error;
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(() {
      if (_isLeaf &&
          _scrollCtrl.position.extentAfter < 400 &&
          !_loading &&
          _docs.length < _count) {
        _load(offset: _docs.length);
      }
    });
    _load();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({int offset = 0}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiProvider).indexNodes(
            widget.index.slug,
            path: widget.path.join('/'),
            offset: offset,
          );
      if (!mounted) return;
      setState(() {
        if (res.nodes != null) {
          _nodes = res.nodes;
          _isLeaf = false;
        } else {
          _isLeaf = true;
          if (offset == 0) _docs.clear();
          _docs.addAll(res.documents!.results);
          _count = res.documents!.count;
        }
        _loaded = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.path.isEmpty
        ? widget.index.name
        : '${widget.index.name} · ${widget.path.join(" / ")}';
    return Scaffold(
      appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
      body: _error != null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : !_loaded
              ? const Center(child: CircularProgressIndicator())
              : _isLeaf
                  ? _buildDocuments()
                  : _buildNodes(),
    );
  }

  Widget _buildNodes() {
    final nodes = _nodes ?? const <IndexNode>[];
    if (nodes.isEmpty) {
      return const Center(child: Text('Empty.'));
    }
    return ListView.builder(
      itemCount: nodes.length,
      itemBuilder: (context, i) {
        final n = nodes[i];
        return ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(n.value.isEmpty ? '—' : n.value),
          trailing: Text(
            '${n.count}',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => IndexDrillScreen(
              index: widget.index,
              path: [...widget.path, n.value],
            ),
          )),
        );
      },
    );
  }

  Widget _buildDocuments() {
    if (_docs.isEmpty) {
      return const Center(child: Text('No documents.'));
    }
    final api = ref.read(apiProvider);
    final bySlug = ref.watch(documentTypesBySlugProvider);
    return ListView.separated(
      controller: _scrollCtrl,
      itemCount: _docs.length + (_docs.length < _count ? 1 : 0),
      separatorBuilder: (context, i) => const Divider(height: 1, indent: 76),
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
              api: api, uuid: d.uuid, mime: d.mimeType, size: 52),
          title: Text(d.title, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${bySlug[d.documentType]?.name ?? d.documentType}'
            ' · ${formatDate(d.documentDate)}',
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => DocumentDetailScreen(uuid: d.uuid),
          )),
        );
      },
    );
  }
}
