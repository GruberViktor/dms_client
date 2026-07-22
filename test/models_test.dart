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

  test('DocumentComment parses, including moderation edits', () {
    final c = DocumentComment.fromJson({
      'id': 42,
      'author': 'alice',
      'author_id': 7,
      'body': 'Rechnung geprüft',
      'created_at': '2026-07-22T09:14:03.512098Z',
      'edited_at': '2026-07-22T10:00:00Z',
      'edited_by': 'root',
      'is_edited': true,
      'can_edit': 'true', // booleans may arrive as strings
      'can_delete': false,
    });
    expect(c.id, 42);
    expect(c.author, 'alice');
    expect(c.isEdited, true);
    expect(c.editedBy, 'root');
    expect(c.canEdit, true);
    expect(c.canDelete, false);
  });

  test('TimelineEvent parses comment kind', () {
    final e = TimelineEvent.fromJson({
      'kind': 'comment',
      'timestamp': '2026-07-22T09:14:03.512098Z',
      'id': 42,
      'author': 'alice',
      'body': 'Rechnung geprüft',
      'edited_at': null,
      'edited_by': null,
    });
    expect(e, isA<CommentEvent>());
    expect((e as CommentEvent).author, 'alice');
    expect(e.editedAt, isNull);
    expect(e.isDeleted, false);

    final d = TimelineEvent.fromJson({
      'kind': 'comment',
      'timestamp': '2026-07-22T09:14:03.512098Z',
      'id': 43,
      'author': 'alice',
      'body': 'gone',
      'is_deleted': true,
      'deleted_at': '2026-07-22T10:02:11.483920Z',
      'deleted_by': 'root',
    });
    expect((d as CommentEvent).isDeleted, true);
    expect(d.deletedBy, 'root');
    expect(d.deletedAt, isNotNull);
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

  test('SearchHit parses mime_type (null when all versions hidden)', () {
    final hit = SearchHit.fromJson({
      'uuid': 'u1',
      'title': 'Report',
      'document_type': 'scratch',
      'mime_type': 'application/vnd.oasis.opendocument.text',
      'headline': 'x',
    });
    expect(hit.mimeType, 'application/vnd.oasis.opendocument.text');
    expect(
      SearchHit.fromJson({'uuid': 'u2', 'mime_type': null}).mimeType,
      isNull,
    );
  });

  test('NotificationItem parses payload and tolerates sparse rows', () {
    final n = NotificationItem.fromJson({
      'id': 17,
      'kind': 'mention',
      'action': 'comment_add',
      'actor': 'alice',
      'document': '9e4a4d95-0000-0000-0000-000000000000',
      'payload': {
        'document_uuid': '9e4a4d95-0000-0000-0000-000000000000',
        'document_title': 'Invoice 47',
        'comment_id': 42,
        'body_excerpt': '@bob check this',
      },
      'created_at': '2026-07-22T09:14:03.512098Z',
      'read_at': null,
      'is_read': false,
    });
    expect(n.isRead, isFalse);
    expect(n.payloadDocumentTitle, 'Invoice 47');
    expect(n.commentId, 42);
    expect(n.bodyExcerpt, '@bob check this');
    expect(n.asRead().isRead, isTrue);

    // Delete event: document FK nulled, unknown kind must not crash (§2).
    final gone = NotificationItem.fromJson({
      'id': 18,
      'kind': 'workflow',
      'action': '',
      'actor': null,
      'document': null,
      'payload': {'document_uuid': 'x', 'document_title': 'Old doc'},
      'created_at': '2026-07-22T09:14:03Z',
      'read_at': '2026-07-22T10:00:00Z',
      'is_read': true,
    });
    expect(gone.documentUuid, isNull);
    expect(gone.actor, isNull);
    expect(gone.isRead, isTrue);
    expect(gone.changedFields, isEmpty);
    expect(gone.version, isNull);
  });

  test('Watch parses both variants (exactly one target set)', () {
    final docWatch = Watch.fromJson({
      'id': 1,
      'document': 'uuid-1',
      'document_title': 'Invoice 47',
      'document_type': null,
      'created_at': '2026-07-22T09:00:00Z',
    });
    expect(docWatch.documentUuid, 'uuid-1');
    expect(docWatch.documentType, isNull);

    final typeWatch = Watch.fromJson({
      'id': 2,
      'document': null,
      'document_title': null,
      'document_type': 'invoices',
      'created_at': '2026-07-22T09:00:00Z',
    });
    expect(typeWatch.documentUuid, isNull);
    expect(typeWatch.documentType, 'invoices');
  });

  test('NotificationPreferences and UserSuggestion parse', () {
    final p = NotificationPreferences.fromJson(
        {'email_mentions': true, 'email_watches': false, 'email_workflow': true});
    expect(p.emailMentions, isTrue);
    expect(p.emailWatches, isFalse);
    expect(p.emailWorkflow, isTrue);

    final u = UserSuggestion.fromJson({'username': 'bodo', 'can_view': false});
    expect(u.username, 'bodo');
    expect(u.canView, isFalse);
    // can_view is only advisory and defaults to true when absent.
    expect(UserSuggestion.fromJson({'username': 'bob'}).canView, isTrue);
  });
}
