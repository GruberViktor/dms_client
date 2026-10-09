import 'dart:io';

import 'package:flutter/material.dart';
import '../util/open_file.dart';
import 'package:path_provider/path_provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../util/format.dart';
import 'common.dart';

/// Paperless-style document tile: preview header, title, type/date meta and
/// open/download actions.
///
/// Built from a list [Document] or from a [SearchHit] — the search payload
/// carries no compliance flag, so hits never show the lock badge.
class DocumentCard extends StatefulWidget {
  final ApiClient api;
  final String uuid;
  final String title;
  final String typeName;
  final String dateLabel;
  final String? mimeType;
  final bool archived;
  final bool inComplianceMode;
  final bool hasPendingRelease;
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
    required this.hasPendingRelease,
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
          hasPendingRelease: document.hasPendingRelease,
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
          mimeType: hit.mimeType,
          archived: hit.archived,
          inComplianceMode: false,
          hasPendingRelease: hit.hasPendingRelease,
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
  String? _busyAction; // 'file' | 'pdf'

  bool get _busy => _busyAction != null;

  /// The list payload carries no versions, so resolve the current one first.
  Future<void> _download({bool asPdf = false}) async {
    final uuid = widget.uuid;
    setState(() => _busyAction = asPdf ? 'pdf' : 'file');
    try {
      final full = await widget.api.document(uuid);
      final v = full.currentVersion;
      if (v == null) {
        if (mounted) showSnack(context, 'Keine herunterladbare Version vorhanden.');
        return;
      }
      final bytes = asPdf
          ? await widget.api.downloadVersionPdf(uuid, v.number)
          : await widget.api.downloadVersion(uuid, v.number);
      final dir = await getTemporaryDirectory();
      var safeName = v.originalFilename.isNotEmpty
          ? v.originalFilename.replaceAll(RegExp(r'[/\\]'), '_')
          : 'document';
      if (asPdf) safeName = pdfFilename(safeName);
      final file = File('${dir.path}/dms/$uuid/v${v.number}/$safeName');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      final opened = await openExternally(file.path);
      if (mounted && !opened) {
        showSnack(context, 'Gespeichert unter ${file.path}');
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.detail);
    } catch (e) {
      if (mounted) showSnack(context, 'Download fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _busyAction = null);
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
                      left: 6,
                      child: Row(
                        children: [
                          if (d.inComplianceMode)
                            _Badge(
                              icon: Icons.lock_outline,
                              tooltip: 'Aufbewahrungspflicht',
                            ),
                          if (d.archived)
                            _Badge(
                              icon: Icons.inventory_2_outlined,
                              tooltip: 'Archiviert',
                            ),
                        ],
                      ),
                    ),
                  // the card clips the band's ends
                  if (d.hasPendingRelease)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: CornerBanner(
                        scale: 1.2,
                        message: 'Freigabe',
                        color: scheme.tertiary,
                        textColor: scheme.onTertiary,
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
                      tooltip: 'Herunterladen & öffnen',
                      icon: _busyAction == 'file'
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_outlined),
                      onPressed: _busy ? null : _download,
                    ),
                  ),
                  // Only convertible formats (odt/docx); mime_type is null
                  // when all versions are hidden.
                  if (canDownloadAsPdf(d.mimeType))
                    Expanded(
                      child: IconButton(
                        tooltip: 'Als PDF herunterladen',
                        icon: _busyAction == 'pdf'
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.picture_as_pdf_outlined),
                        onPressed:
                            _busy ? null : () => _download(asPdf: true),
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
