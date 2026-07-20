import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../state/session.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import 'document_detail_screen.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _queryCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  Timer? _debounce;

  final List<SearchHit> _hits = [];
  int _count = 0;
  bool _loading = false;
  bool _searched = false;
  Object? _error;
  int _requestGen = 0;
  String? _typeSlug;
  bool _includeArchived = false;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(() {
      if (_scrollCtrl.position.extentAfter < 400 &&
          !_loading &&
          _hits.length < _count) {
        _runSearch(offset: _hits.length);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _runSearch());
  }

  Future<void> _runSearch({int offset = 0}) async {
    final q = _queryCtrl.text.trim();
    final gen = ++_requestGen;
    if (q.isEmpty) {
      setState(() {
        _hits.clear();
        _count = 0;
        _searched = false;
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref.read(apiProvider).search(
            q,
            type: _typeSlug,
            archived: _includeArchived ? 'true' : null,
            offset: offset,
          );
      if (!mounted || gen != _requestGen) return;
      setState(() {
        if (offset == 0) _hits.clear();
        _hits.addAll(page.results);
        _count = page.count;
        _searched = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _requestGen) return;
      setState(() {
        _error = e;
        _loading = false;
        _searched = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = ref.watch(documentTypesProvider).value ?? const <DocumentType>[];
    final bySlug = ref.watch(documentTypesBySlugProvider);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _queryCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search — "exact phrase", OR, -exclude',
            border: InputBorder.none,
            prefixIcon: Icon(Icons.search),
          ),
          textInputAction: TextInputAction.search,
          onChanged: _onQueryChanged,
          onSubmitted: (_) => _runSearch(),
        ),
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                DropdownMenu<String?>(
                  label: const Text('Type'),
                  initialSelection: _typeSlug,
                  dropdownMenuEntries: [
                    const DropdownMenuEntry<String?>(
                        value: null, label: 'All types'),
                    for (final t in types)
                      DropdownMenuEntry<String?>(
                        value: t.slug,
                        label: '${'  ' * t.depth}${t.name}',
                      ),
                  ],
                  onSelected: (slug) {
                    setState(() => _typeSlug = slug);
                    _runSearch();
                  },
                ),
                const SizedBox(width: 12),
                FilterChip(
                  label: const Text('Include archived'),
                  selected: _includeArchived,
                  onSelected: (v) {
                    setState(() => _includeArchived = v);
                    _runSearch();
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildResults(bySlug)),
        ],
      ),
    );
  }

  Widget _buildResults(Map<String, DocumentType> bySlug) {
    if (_error != null) {
      return ErrorRetry(error: _error!, onRetry: _runSearch);
    }
    if (_loading && _hits.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_searched) {
      return Center(
        child: Text(
          'Search titles, metadata and full text.',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    if (_hits.isEmpty) {
      return const Center(child: Text('No results.'));
    }
    final api = ref.read(apiProvider);
    return ListView.separated(
      controller: _scrollCtrl,
      itemCount: _hits.length + (_hits.length < _count ? 1 : 0),
      separatorBuilder: (context, i) => const Divider(height: 1, indent: 76),
      itemBuilder: (context, i) {
        if (i >= _hits.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final h = _hits[i];
        return ListTile(
          leading: DocumentThumbnail(
            api: api,
            uuid: h.uuid,
            mime: null,
            size: 52,
          ),
          title: Row(
            children: [
              Flexible(child: Text(h.title, overflow: TextOverflow.ellipsis)),
              if (h.archived)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.inventory_2_outlined, size: 15),
                ),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (h.headline.isNotEmpty) HeadlineText(h.headline),
              Text(
                '${bySlug[h.documentType]?.name ?? h.documentType}'
                ' · ${formatDate(h.documentDate)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          isThreeLine: h.headline.isNotEmpty,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => DocumentDetailScreen(uuid: h.uuid),
          )),
        );
      },
    );
  }
}
