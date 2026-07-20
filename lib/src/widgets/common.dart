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

/// Renders a search headline: keeps <b>…</b> as bold, strips other tags.
class HeadlineText extends StatelessWidget {
  final String headline;
  final int maxLines;

  const HeadlineText(this.headline, {super.key, this.maxLines = 2});

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.bodyMedium!;
    final bold = base.copyWith(
      fontWeight: FontWeight.w700,
      backgroundColor:
          Theme.of(context).colorScheme.primaryContainer.withValues(alpha: .5),
    );
    final spans = <TextSpan>[];
    final re = RegExp(r'<b>(.*?)</b>', dotAll: true);
    var pos = 0;
    for (final m in re.allMatches(headline)) {
      if (m.start > pos) {
        spans.add(TextSpan(text: _strip(headline.substring(pos, m.start))));
      }
      spans.add(TextSpan(text: _strip(m.group(1)!), style: bold));
      pos = m.end;
    }
    if (pos < headline.length) {
      spans.add(TextSpan(text: _strip(headline.substring(pos))));
    }
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }

  static String _strip(String s) => s
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#x27;', "'")
      .replaceAll('&#39;', "'");
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
