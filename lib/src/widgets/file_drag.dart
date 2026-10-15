import 'dart:io';

import 'package:flutter/material.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../api/api_client.dart';
import 'common.dart';

/// Desktop only: dragging out hands the drop target a `file://` URI of a
/// local copy. Mobile targets would need content URIs, which are not wired.
final bool fileDragSupported =
    Platform.isLinux || Platform.isWindows || Platform.isMacOS;

/// Marks drags that originate here, so the app's own upload drop zone can
/// ignore them.
const fileDragLocalData = 'dms_client.file_drag';

/// What a drag hands out: the file's [name] (known up front, for the drag
/// chip) and how to [fetch] its content.
class FileDragSpec {
  final String name;
  final Future<File> Function() fetch;

  const FileDragSpec({required this.name, required this.fetch});
}

/// Makes [builder]'s output draggable into other apps (mail drafts, file
/// managers) as a real file.
///
/// [prepare] runs when the drag starts and must be quick (at most a small
/// API call); returning null cancels the drag (the callback reports why).
/// The fetch then starts right away in the background while the drag is
/// already under way; the file URI is a lazy value that the drop target's
/// data request (normally on drop) waits on. That fetch is a download
/// (needs `download`, audited as one — also when the drag is cancelled).
/// [builder] gets `busy == true` while either step runs. Errors go to
/// [onError], defaulting to a snack; a failed fetch hands the target an
/// empty URI list, so the drop does nothing.
class FileDragSource extends StatefulWidget {
  final Future<FileDragSpec?> Function() prepare;
  final Widget Function(BuildContext context, bool busy) builder;
  final bool enabled;
  final void Function(Object error)? onError;

  const FileDragSource({
    super.key,
    required this.prepare,
    required this.builder,
    this.enabled = true,
    this.onError,
  });

  @override
  State<FileDragSource> createState() => _FileDragSourceState();
}

class _FileDragSourceState extends State<FileDragSource> {
  int _busyCount = 0;
  String _name = '';

  Future<T> _busy<T>(Future<T> Function() body) async {
    if (mounted) setState(() => _busyCount++);
    try {
      return await body();
    } finally {
      if (mounted) setState(() => _busyCount--);
    }
  }

  void _report(Object e) {
    if (widget.onError != null) {
      widget.onError!(e);
    } else if (mounted) {
      showSnack(
        context,
        e is ApiException ? e.detail : 'Download fehlgeschlagen: $e',
      );
    }
  }

  Future<DragItem?> _provide(DragItemRequest request) async {
    if (_busyCount > 0) return null;
    final FileDragSpec? spec;
    try {
      spec = await _busy(widget.prepare);
    } catch (e) {
      _report(e);
      return null;
    }
    if (spec == null) return null;
    _name = spec.name;
    // Start downloading as the drag takes off; the target's data request
    // (normally on drop) then only waits for whatever is left. The native
    // side blocks that request on this future, so it must always complete
    // — never throw.
    final fetched = _busy(() async {
      try {
        return (await spec!.fetch()).uri;
      } catch (e) {
        _report(e);
        return Uri();
      }
    });
    return DragItem(localData: fileDragLocalData, suggestedName: spec.name)
      ..add(Formats.fileUri.lazy(() => fetched));
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(context, _busyCount > 0);
    if (!fileDragSupported || !widget.enabled) return child;
    return DragItemWidget(
      allowedOperations: () => [DropOperation.copy],
      dragItemProvider: _provide,
      // A compact file chip instead of a snapshot of the whole source.
      dragBuilder: (context, _) => _DragChip(name: _name),
      child: DraggableWidget(child: child),
    );
  }
}

class _DragChip extends StatelessWidget {
  final String name;

  const _DragChip({required this.name});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(8),
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.insert_drive_file_outlined,
                size: 18,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSecondaryContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
