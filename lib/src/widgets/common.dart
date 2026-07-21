import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../util/format.dart';

IconData mimeIcon(String? mime) => switch (mimeCategory(mime)) {
      'image' => Icons.image_outlined,
      'pdf' => Icons.picture_as_pdf_outlined,
      'sheet' => Icons.table_chart_outlined,
      'doc' => Icons.description_outlined,
      'text' => Icons.notes_outlined,
      'slides' => Icons.slideshow_outlined,
      'archive' => Icons.folder_zip_outlined,
      'audio' => Icons.audio_file_outlined,
      'video' => Icons.video_file_outlined,
      _ => Icons.insert_drive_file_outlined,
    };

/// Thumbnail from the server preview endpoint; falls back to a mime icon
/// for formats without previews (404) or while unauthenticated.
class DocumentThumbnail extends StatelessWidget {
  final ApiClient api;
  final String uuid;
  final String? mime;
  final double size;

  const DocumentThumbnail({
    super.key,
    required this.api,
    required this.uuid,
    required this.mime,
    this.size = 48,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: size,
        height: size,
        color: scheme.surfaceContainerHighest,
        child: Image.network(
          api.documentPreviewUrl(uuid),
          headers: api.authHeaders,
          fit: BoxFit.cover,
          errorBuilder: (context, e, st) =>
              Icon(mimeIcon(mime), color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// Large preview for card headers: first page at `preview` size, cropped to
/// the top edge so the document reads like a sheet of paper. Falls back to a
/// mime icon for formats without previews (404).
class DocumentPreviewImage extends StatelessWidget {
  final ApiClient api;
  final String uuid;
  final String? mime;

  const DocumentPreviewImage({
    super.key,
    required this.api,
    required this.uuid,
    required this.mime,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Image.network(
        api.documentPreviewUrl(uuid, size: 'preview'),
        headers: api.authHeaders,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        width: double.infinity,
        height: double.infinity,
        frameBuilder: (context, child, frame, wasSync) => wasSync || frame != null
            ? child
            : const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
        errorBuilder: (context, e, st) => Icon(
          mimeIcon(mime),
          size: 40,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Standard error box with retry.
class ErrorRetry extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const ErrorRetry({super.key, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final msg = error is ApiException ? (error as ApiException).detail : '$error';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 40, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(msg, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class ComplianceBadge extends StatelessWidget {
  final String? retentionUntil;
  const ComplianceBadge({super.key, this.retentionUntil});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: retentionUntil != null
          ? 'Under retention until ${formatDate(retentionUntil)}'
          : 'Under retention',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 14, color: scheme.onTertiaryContainer),
            const SizedBox(width: 4),
            Text(
              retentionUntil != null
                  ? 'Retention · ${formatDate(retentionUntil)}'
                  : 'Retention',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.onTertiaryContainer),
            ),
          ],
        ),
      ),
    );
  }
}
