import 'package:flutter/material.dart';

import '../models/models.dart';

/// How a key compares, which is all the UI needs it for: it picks the
/// direction wording and the direction a freshly chosen key starts in.
enum SortKind { text, date, number, relevance }

/// One key the server's `ordering` parameter accepts (result-ordering
/// hand-off). [key] is the wire name — `metadata__<field>` for metadata.
class SortKey {
  final String key;
  final String label;
  final SortKind kind;

  const SortKey(this.key, this.label, this.kind);

  /// Text reads best A→Z; everything else is most interesting at the top.
  bool get defaultDescending => kind != SortKind.text;

  String directionLabel({required bool descending}) => switch (kind) {
    SortKind.date => descending ? 'Neueste zuerst' : 'Älteste zuerst',
    SortKind.number => descending ? 'Höchste zuerst' : 'Niedrigste zuerst',
    SortKind.relevance =>
      descending ? 'Beste Treffer zuerst' : 'Schwächste zuerst',
    SortKind.text => descending ? 'Z → A' : 'A → Z',
  };

  static SortKind kindOf(FieldType t) => switch (t) {
    FieldType.integer || FieldType.float || FieldType.monetary =>
      SortKind.number,
    FieldType.date => SortKind.date,
    _ => SortKind.text,
  };

  /// A metadata field as a sort key; numeric and date fields sort by value,
  /// not as strings, server-side.
  factory SortKey.metadata(MetadataFieldDef f) =>
      SortKey('metadata__${f.key}', f.label, kindOf(f.fieldType));

  @override
  bool operator ==(Object other) => other is SortKey && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// Search-only relevance key; the default ordering of `/search/`.
const relevanceSortKey = SortKey('rank', 'Relevanz', SortKind.relevance);

/// Default ordering of the list endpoint.
const dateAddedSortKey = SortKey('date_added', 'Hinzugefügt am', SortKind.date);

/// The keys every document-returning endpoint accepts, in menu order.
const commonSortKeys = <SortKey>[
  dateAddedSortKey,
  SortKey('document_date', 'Dokumentdatum', SortKind.date),
  SortKey('title', 'Titel', SortKind.text),
  SortKey('document_type', 'Typ', SortKind.text),
  SortKey('added_by', 'Hinzugefügt von', SortKind.text),
  SortKey('mime_type', 'Dateityp', SortKind.text),
  SortKey('retention_until', 'Aufbewahrung bis', SortKind.date),
  SortKey('archived_at', 'Archiviert am', SortKind.date),
];

/// A chosen ordering, ready for the `ordering` query parameter.
class DocumentSort {
  final SortKey key;
  final bool descending;

  const DocumentSort(this.key, {this.descending = true});

  /// Mirrors the server defaults, so both are sent explicitly rather than
  /// relying on the parameter being absent.
  static const browseDefault = DocumentSort(dateAddedSortKey);
  static const searchDefault = DocumentSort(relevanceSortKey);

  String get ordering => descending ? '-${key.key}' : key.key;

  String get directionLabel => key.directionLabel(descending: descending);

  DocumentSort get reversed => DocumentSort(key, descending: !descending);

  /// A newly picked key starts in its natural direction.
  static DocumentSort of(SortKey key) =>
      DocumentSort(key, descending: key.defaultDescending);

  @override
  bool operator ==(Object other) =>
      other is DocumentSort &&
      other.key == key &&
      other.descending == descending;

  @override
  int get hashCode => Object.hash(key, descending);
}

/// Filter-bar sort control: a chip opening the key menu, plus a one-tap
/// direction toggle. Nulls sort last server-side in both directions.
class SortControl extends StatelessWidget {
  final DocumentSort sort;

  /// Metadata fields of the selected type (merged, inherited included);
  /// empty when no type is selected — there is nothing to suggest then.
  final List<MetadataFieldDef> metadataFields;

  /// Relevance only exists on the search endpoint.
  final bool searching;

  final ValueChanged<DocumentSort> onChanged;

  const SortControl({
    super.key,
    required this.sort,
    required this.onChanged,
    required this.searching,
    this.metadataFields = const [],
  });

  List<SortKey> get _keys => [
    if (searching) relevanceSortKey,
    ...commonSortKeys,
    for (final f in metadataFields) SortKey.metadata(f),
    // The active key survives a type change that drops it from the menu.
    if (!_offered.contains(sort.key)) sort.key,
  ];

  Set<SortKey> get _offered => {
    if (searching) relevanceSortKey,
    ...commonSortKeys,
    for (final f in metadataFields) SortKey.metadata(f),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metadataStart = (searching ? 1 : 0) + commonSortKeys.length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MenuAnchor(
          alignmentOffset: const Offset(0, 4),
          menuChildren: [
            for (final (i, k) in _keys.indexed) ...[
              if (i == metadataStart && metadataFields.isNotEmpty)
                _sectionLabel(context, 'Metadaten'),
              MenuItemButton(
                leadingIcon: Icon(
                  Icons.check,
                  size: 18,
                  color: k == sort.key ? null : Colors.transparent,
                ),
                // Re-picking the active key keeps its direction, so the menu
                // never silently flips what you are looking at.
                onPressed: () =>
                    onChanged(k == sort.key ? sort : DocumentSort.of(k)),
                child: Text(k.label),
              ),
            ],
          ],
          builder: (context, controller, _) => ActionChip(
            avatar: const Icon(Icons.sort, size: 18),
            label: Text(sort.key.label),
            tooltip: 'Sortieren nach',
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
        ),
        IconButton(
          icon: Icon(
            sort.descending ? Icons.arrow_downward : Icons.arrow_upward,
            size: 18,
          ),
          visualDensity: VisualDensity.compact,
          tooltip: '${sort.directionLabel} — zum Umkehren klicken',
          color: theme.colorScheme.onSurfaceVariant,
          onPressed: () => onChanged(sort.reversed),
        ),
      ],
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
