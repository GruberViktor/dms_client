import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/editors.dart';

/// "Someone else is editing this document" notice; empty while nobody is.
/// It only informs — the server does not lock the document.
class EditorsBanner extends ConsumerWidget {
  final String uuid;
  final EdgeInsets padding;

  const EditorsBanner({
    super.key,
    required this.uuid,
    this.padding = const EdgeInsets.only(bottom: 12),
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editors = ref.watch(documentEditorsProvider)[uuid]?.keys.toList();
    if (editors == null || editors.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final names = editors.join(', ');
    final verb = editors.length == 1 ? 'bearbeitet' : 'bearbeiten';
    return Padding(
      padding: padding,
      child: Card(
        margin: EdgeInsets.zero,
        color: dark
            ? Colors.amber.shade900.withValues(alpha: .25)
            : Colors.amber.shade50,
        child: ListTile(
          leading: Icon(
            Icons.edit_note,
            color: dark ? Colors.amber.shade200 : Colors.amber.shade900,
          ),
          title: Text('$names $verb dieses Dokument gerade.'),
          subtitle: const Text(
            'Gleichzeitige Änderungen können einander überschreiben.',
          ),
        ),
      ),
    );
  }
}
