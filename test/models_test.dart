import 'package:flutter_test/flutter_test.dart';

import 'package:dms_client/src/models/models.dart';

void main() {
  group('mergedMetadataFields', () {
    DocumentType type(
            String slug, String? parent, List<MetadataFieldDef> fields) =>
        DocumentType(
          slug: slug,
          name: slug,
          parentSlug: parent,
          depth: parent == null ? 0 : 1,
          retentionPolicy: null,
          isActive: true,
          metadataFields: fields,
        );

    MetadataFieldDef field(String key,
            {FieldType t = FieldType.text, int ord = 0}) =>
        MetadataFieldDef(
          key: key,
          label: key,
          fieldType: t,
          required: false,
          defaultValue: null,
          ordering: ord,
          indexed: false,
        );

    test('child inherits ancestor fields, child keys override', () {
      final bySlug = {
        'root': type('root', null, [
          field('amount', t: FieldType.monetary, ord: 1),
          field('vendor', ord: 0),
        ]),
        'child': type('child', 'root', [
          field('amount', t: FieldType.float, ord: 2),
          field('due', t: FieldType.date, ord: 3),
        ]),
      };
      final merged = mergedMetadataFields(bySlug, 'child');
      expect(merged.map((f) => f.key), ['vendor', 'amount', 'due']);
      // Child's definition wins over the ancestor's.
      expect(
          merged.firstWhere((f) => f.key == 'amount').fieldType, FieldType.float);
    });

    test('handles unknown slug and cycles safely', () {
      expect(mergedMetadataFields({}, 'nope'), isEmpty);
      final bySlug = {
        'a': type('a', 'b', [field('x')]),
        'b': type('b', 'a', [field('y')]),
      };
      final merged = mergedMetadataFields(bySlug, 'a');
      expect(merged.map((f) => f.key).toSet(), {'x', 'y'});
    });
  });

  test('Document parses and finds newest visible version', () {
    final doc = Document.fromJson({
      'uuid': 'u1',
      'title': 'Invoice',
      'document_type': 'invoice',
      'document_date': '2026-01-15',
      'date_added': '2026-01-15T10:00:00Z',
      'added_by': 'alice',
      'metadata': {'amount': '12.50'},
      'archived': 'false',
      'in_compliance_mode': true,
      'versions': [
        {
          'number': 1,
          'original_filename': 'a.pdf',
          'mime_type': 'application/pdf',
          'size': 100,
          'checksum_sha256': 'x',
          'uploaded_by': 'alice',
          'uploaded_at': '2026-01-15T10:00:00Z',
          'extraction_status': 'done',
          'is_hidden': false,
        },
        {
          'number': 2,
          'original_filename': 'b.pdf',
          'mime_type': 'application/pdf',
          'size': 100,
          'checksum_sha256': 'y',
          'uploaded_by': 'bob',
          'uploaded_at': '2026-01-16T10:00:00Z',
          'extraction_status': 'pending',
          'is_hidden': true,
        },
      ],
    });
    expect(doc.archived, false);
    expect(doc.inComplianceMode, true);
    // Newest *visible* version is v1 — v2 is hidden.
    expect(doc.currentVersion?.number, 1);
  });

  test('TimelineEvent parses both kinds', () {
    final v = TimelineEvent.fromJson({
      'kind': 'version',
      'timestamp': '2026-01-16T10:00:00Z',
      'number': 2,
      'original_filename': 'b.pdf',
      'mime_type': 'application/pdf',
      'size': 10,
      'uploaded_by': 'bob',
      'extraction_status': 'done',
      'is_hidden': false,
      'diff': {
        'from_version': 1,
        'added_lines': 2,
        'removed_lines': 4,
        'too_large': false,
        'unified_diff': '--- v1\n+++ v2\n@@ -1 +1 @@\n-a\n+b'
      },
    });
    expect(v, isA<VersionEvent>());
    expect((v as VersionEvent).diff?.addedLines, 2);

    final a = TimelineEvent.fromJson({
      'kind': 'audit',
      'timestamp': '2026-01-16T10:00:00Z',
      'action': 'edit_metadata',
      'actor': null,
      'changes': {
        'title': {'old': 'A', 'new': 'B'}
      },
    });
    expect(a, isA<AuditEvent>());
    expect((a as AuditEvent).actor, isNull);
  });
}
