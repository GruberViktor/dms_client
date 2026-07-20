import 'package:flutter/material.dart';

import '../models/models.dart';

/// Renders the document-type tree (built from parent_slug) as an expandable
/// list. Selecting a node filters by that type (server includes descendants).
class TypeTree extends StatefulWidget {
  final List<DocumentType> types;
  final String? selectedSlug;
  final ValueChanged<String?> onSelected;

  const TypeTree({
    super.key,
    required this.types,
    required this.selectedSlug,
    required this.onSelected,
  });

  @override
  State<TypeTree> createState() => _TypeTreeState();
}

class _TypeTreeState extends State<TypeTree> {
  final Set<String> _collapsed = {};

  @override
  Widget build(BuildContext context) {
    final childrenOf = <String?, List<DocumentType>>{};
    for (final t in widget.types) {
      childrenOf.putIfAbsent(t.parentSlug, () => []).add(t);
    }

    final rows = <Widget>[
      ListTile(
        dense: true,
        selected: widget.selectedSlug == null,
        leading: const Icon(Icons.all_inbox_outlined, size: 20),
        title: const Text('All documents'),
        onTap: () => widget.onSelected(null),
      ),
    ];
    void addNodes(String? parent) {
      for (final t in childrenOf[parent] ?? const <DocumentType>[]) {
        final kids = childrenOf[t.slug] ?? const [];
        final collapsed = _collapsed.contains(t.slug);
        rows.add(ListTile(
          dense: true,
          selected: widget.selectedSlug == t.slug,
          contentPadding: EdgeInsets.only(left: 16.0 + t.depth * 16, right: 8),
          leading: Icon(
            kids.isEmpty ? Icons.label_outline : Icons.folder_outlined,
            size: 20,
          ),
          title: Text(
            t.name,
            style: t.isActive
                ? null
                : TextStyle(color: Theme.of(context).disabledColor),
          ),
          trailing: kids.isEmpty
              ? null
              : IconButton(
                  icon: Icon(
                    collapsed ? Icons.chevron_right : Icons.expand_more,
                    size: 20,
                  ),
                  onPressed: () => setState(() {
                    collapsed ? _collapsed.remove(t.slug) : _collapsed.add(t.slug);
                  }),
                ),
          onTap: () => widget.onSelected(t.slug),
        ));
        if (!collapsed) addNodes(t.slug);
      }
    }

    addNodes(null);
    return ListView(children: rows);
  }
}
