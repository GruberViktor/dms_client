import 'package:flutter/material.dart';

import '../models/models.dart';

/// Renders the document-type tree (built from parent_slug) as an expandable
/// list. Selecting a node filters by that type (server includes descendants).
/// When [onToggleWatch] is set, each node gets a bell to watch the category —
/// a type watch covers the whole subtree (notifications hand-off §2).
class TypeTree extends StatefulWidget {
  final List<DocumentType> types;
  final String? selectedSlug;
  final ValueChanged<String?> onSelected;
  final Set<String> watchedSlugs;
  final ValueChanged<String>? onToggleWatch;

  const TypeTree({
    super.key,
    required this.types,
    required this.selectedSlug,
    required this.onSelected,
    this.watchedSlugs = const {},
    this.onToggleWatch,
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
        rows.add(
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            minTileHeight: 32,
            minVerticalPadding: 0,
            // Gap from icon to label is max(minLeadingWidth, iconWidth) +
            // horizontalTitleGap, and compact density already shaves 4 off
            // the latter — so 8 here lands at an effective 4.
            minLeadingWidth: 10,
            horizontalTitleGap: 12,
            selected: widget.selectedSlug == t.slug,
            contentPadding: EdgeInsets.only(left: 0 + t.depth * 10, right: 8),
            leading: Icon(
              kids.isEmpty ? Icons.label_outline : Icons.folder_outlined,
              size: 20,
            ),
            title: Text(
              t.name,
              overflow: TextOverflow.ellipsis,
              style:
                  (t.isActive
                          ? const TextStyle()
                          : TextStyle(color: Theme.of(context).disabledColor))
                      .copyWith(height: 1.15),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onToggleWatch != null)
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 30,
                      height: 30,
                    ),
                    visualDensity: VisualDensity.compact,
                    tooltip: widget.watchedSlugs.contains(t.slug)
                        ? 'Stop watching this category'
                        : 'Watch this category (incl. subtypes)',
                    icon: Icon(
                      widget.watchedSlugs.contains(t.slug)
                          ? Icons.notifications_active
                          : Icons.notifications_none_outlined,
                      size: 18,
                      color: widget.watchedSlugs.contains(t.slug)
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outline,
                    ),
                    onPressed: () => widget.onToggleWatch!(t.slug),
                  ),
                if (kids.isNotEmpty)
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 30,
                      height: 30,
                    ),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      collapsed ? Icons.chevron_right : Icons.expand_more,
                      size: 20,
                    ),
                    onPressed: () => setState(() {
                      collapsed
                          ? _collapsed.remove(t.slug)
                          : _collapsed.add(t.slug);
                    }),
                  ),
              ],
            ),
            onTap: () => widget.onSelected(t.slug),
          ),
        );
        if (!collapsed) addNodes(t.slug);
      }
    }

    addNodes(null);
    return ListView(children: rows);
  }
}
