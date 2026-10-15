import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dms_client/src/api/api_client.dart';
import 'package:dms_client/src/models/models.dart';

void main() {
  test('parseDocumentFeed reads events and skips keepalives', () async {
    // Chunk borders fall mid-line on purpose: the parser must not care.
    const raw =
        'retry: 5000\n\n: keepalive\n\n'
        'event: document_changed\ndata: {"document": "u1", "action": "comm'
        'ent_add"}\n\nevent: other\ndata: {}\n\n'
        'event: document_editing\ndata: {"document": "u2", "user": "bob", '
        '"editing": true, "expires_in": 60}\n\n'
        'event: document_changed\ndata: {"document": "u2", "action": "delete"}\n\n';
    final chunks = [
      raw.substring(0, 40),
      raw.substring(40, 90),
      raw.substring(90),
    ].map(utf8.encode);
    final changes = await parseDocumentFeed(
      // Stream<Uint8List>, exactly what Dio delivers.
      Stream<Uint8List>.fromIterable(chunks),
    ).toList();
    expect(
      changes.map(
        (e) => switch (e) {
          DocumentChange() => '${e.uuid}:${e.action}',
          DocumentEditing() =>
            '${e.uuid}:${e.user}:${e.editing}:${e.expiresIn.inSeconds}',
        },
      ),
      ['u1:comment_add', 'u2:bob:true:60', 'u2:delete'],
    );
  });
}
