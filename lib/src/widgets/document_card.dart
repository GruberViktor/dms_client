import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../util/format.dart';
import 'common.dart';

/// Paperless-style document tile: preview header, title, type/date meta and
/// open/download actions.
///
/// Built from a list [Document] or from a [SearchHit] — the search payload
/// carries no mime type or compliance flag, so those degrade to the generic
/// icon fallback and a missing lock badge.
class DocumentCard extends StatefulWidget {
  final ApiClient api;
  final String uuid;
  final String title;
  final String typeName;
  final String dateLabel;
  final String? mimeType;
  final bool archived;
  final bool inComplianceMode;
  final VoidCallback onOpen;

  const DocumentCard._({
    super.key,
    required this.api,
    required this.uuid,
    required this.title,
    required this.typeName,
    required this.dateLabel,
    required this.mimeType,
    required this.archived,
    required this.inComplianceMode,
    required this.onOpen,
  });

  DocumentCard({
    Key? key,
    required ApiClient api,
    required Document document,
    required String typeName,
    required VoidCallback onOpen,
  }) : this._(
          key: key,
          api: api,
          uuid: document.uuid,
          title: document.title,
          typeName: typeName,
          dateLabel: _dateLabel(document.documentDate, document.dateAdded),
          mimeType: document.mimeType,
          archived: document.archived,
          inComplianceMode: document.inComplianceMode,
          onOpen: onOpen,
        );

  DocumentCard.hit({
    Key? key,
    required ApiClient api,
    required SearchHit hit,
    required String typeName,
    required VoidCallback onOpen,
  }) : this._(
          key: key,
          api: api,
          uuid: hit.uuid,
          title: hit.title,
          typeName: typeName,
          dateLabel: _dateLabel(hit.documentDate, hit.dateAdded),
          mimeType: null,
          archived: hit.archived,
          inComplianceMode: false,
          onOpen: onOpen,
        );

  /// document_date is the business date; fall back to when it was filed.
  static String _dateLabel(String? documentDate, DateTime? dateAdded) {
    if (documentDate != null && documentDate.isNotEmpty) {
      return formatDate(documentDate);
    }
    return dateAdded != null
        ? formatDate(dateAdded.toLocal().toIso8601String())
        : '—';
  }

  @override
  State<DocumentCard> createState() => _DocumentCardState();
}

class _DocumentCardState extends State<DocumentCard> {
  bool _busy = false;

  /// The list payload carries no versions, so resolve the current one first.
  Future<void> _download() async {
    final uuid = widget.uuid;
    setState(() => _busy = true);
    try {
      final full = await widget.api.document(uuid);
      final v = full.currentVersion;
      if (v == null) {
        if (mounted) showSnack(context, 'No downloadable version.');
        return;
      }
      final bytes = await widget.api.downloadVersion(uuid, v.number);
      final dir = await getTemporaryDirectory();
      final safeName = v.originalFilename.isNotEmpty
          ? v.originalFilename.replaceAll(RegExp(r'[/\\]'), '_')
          : 'document';
      final file = File('${dir.path}/dms/$uuid/v${v.number}/$safeName');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      final result = await OpenFilex.open(file.path);
      if (mounted && result.type != ResultType.done) {
        showSnack(context, 'Saved to ${file.path}');
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    } catch (e) {
      if (mounted) showSnack(context, 'Download failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: widget.onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DocumentPreviewImage(
                    api: widget.api,
                    uuid: d.uuid,
                    mime: d.mimeType,
                  ),
                  if (d.inComplianceMode || d.archived)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Row(
                        children: [
                          if (d.inComplianceMode)
                            _Badge(
                              icon: Icons.lock_outline,
                              tooltip: 'Under retention',
                            ),
                          if (d.archived)
                            _Badge(
                              icon: Icons.inventory_2_outlined,
                              tooltip: 'Archived',
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 40,
                    child: Text(
                      d.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: d.archived ? scheme.outline : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  _MetaRow(
                    icon: Icons.sell_outlined,
                    text: widget.typeName,
                  ),
                  const SizedBox(height: 2),
                  _MetaRow(icon: Icons.event_outlined, text: d.dateLabel),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Expanded(
                    child: IconButton(
                      tooltip: 'Details',
                      icon: const Icon(Icons.description_outlined),
                      onPressed: widget.onOpen,
                    ),
                  ),
                  Expanded(
                    child: IconButton(
                      tooltip: 'Download & open',
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_outlined),
                      onPressed: _busy ? null : _download,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MetaRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 15, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final String tooltip;

  const _Badge({required this.icon, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: tooltip,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
