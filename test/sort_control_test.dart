import 'package:dms_client/src/models/models.dart';
import 'package:dms_client/src/widgets/sort_control.dart';
import 'package:flutter_test/flutter_test.dart';

MetadataFieldDef _field(String key, FieldType type) => MetadataFieldDef(
  key: key,
  label: key,
  fieldType: type,
  required: false,
  defaultValue: null,
  ordering: 0,
  indexed: true,
);

void main() {
  group('DocumentSort', () {
    test('renders the ordering parameter with the direction prefix', () {
      expect(DocumentSort.browseDefault.ordering, '-date_added');
      expect(DocumentSort.searchDefault.ordering, '-rank');
      expect(
        const DocumentSort(
          SortKey('title', 'Title', SortKind.text),
          descending: false,
        ).ordering,
        'title',
      );
    });

    test('a newly picked key starts in its natural direction', () {
      expect(DocumentSort.of(dateAddedSortKey).descending, isTrue);
      expect(
        DocumentSort.of(const SortKey('title', 'Title', SortKind.text))
            .descending,
        isFalse,
      );
    });

    test('reversed flips only the direction', () {
      final s = DocumentSort.browseDefault.reversed;
      expect(s.key, dateAddedSortKey);
      expect(s.ordering, 'date_added');
      expect(s.reversed, DocumentSort.browseDefault);
    });
  });

  group('SortKey.metadata', () {
    test('prefixes the wire key', () {
      expect(
        SortKey.metadata(_field('net_amount', FieldType.monetary)).key,
        'metadata__net_amount',
      );
    });

    test('numeric and date fields keep their kind for direction wording', () {
      expect(
        SortKey.metadata(_field('n', FieldType.integer)).kind,
        SortKind.number,
      );
      expect(
        SortKey.metadata(_field('d', FieldType.date)).kind,
        SortKind.date,
      );
      expect(
        SortKey.metadata(_field('t', FieldType.text)).kind,
        SortKind.text,
      );
    });
  });
}
