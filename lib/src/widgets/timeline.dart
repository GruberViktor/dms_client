import 'package:flutter/material.dart';

import '../models/models.dart';
import '../util/format.dart';
import 'common.dart';

/// Vertical audit/version timeline (client-specification.md §6).
/// Version events are large anchor nodes; audit events smaller entries.
/// view/download repeats are grouped ("5× angesehen").
class DocumentTimeline extends StatelessWidget {
  final List<TimelineEvent> events;

  const DocumentTimeline({super.key, required this.events});

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Keine Ereignisse.'),
      );
    }
    // comment_* audit rows duplicate what the comment node already shows —
    // add/edit via the node itself, delete via its struck-through state.
    final visible = events.where(
      (e) => e is! AuditEvent || !e.action.startsWith('comment_'),
    );
    // Newest first.
    final sorted = [...visible]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final entries = _groupViewDownload(sorted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < entries.length; i++)
          _TimelineRow(entry: entries[i], isLast: i == entries.length - 1),
      ],
    );
  }

  /// Collapse consecutive view/download audit events by the same actor on the
  /// same day into one entry with a count.
  static List<_Entry> _groupViewDownload(List<TimelineEvent> sorted) {
    final entries = <_Entry>[];
    for (final e in sorted) {
      if (e is AuditEvent && (e.action == 'view' || e.action == 'download')) {
        final last = entries.isNotEmpty ? entries.last : null;
        if (last != null &&
            last.event is AuditEvent &&
            (last.event as AuditEvent).action == e.action &&
            (last.event as AuditEvent).actor == e.actor &&
            _sameDay(last.event.timestamp, e.timestamp)) {
          last.repeat++;
          continue;
        }
      }
      entries.add(_Entry(e));
    }
    return entries;
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _Entry {
  final TimelineEvent event;
  int repeat = 1;
  _Entry(this.event);
}

class _TimelineRow extends StatelessWidget {
  final _Entry entry;
  final bool isLast;

  const _TimelineRow({required this.entry, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final e = entry.event;
    final isVersion = e is VersionEvent;
    final isComment = e is CommentEvent;
    final markerSize = isVersion ? 18.0 : (isComment ? 14.0 : 10.0);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 32,
            child: Column(
              children: [
                const SizedBox(height: 4),
                Container(
                  width: markerSize,
                  height: markerSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isVersion
                        ? (e.isHidden ? scheme.outlineVariant : scheme.primary)
                        : isComment
                        ? (e.isDeleted
                              ? scheme.outlineVariant
                              : scheme.tertiary)
                        : scheme.outline,
                    border: isVersion
                        ? Border.all(color: scheme.primaryContainer, width: 3)
                        : null,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(width: 2, color: scheme.outlineVariant),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 4 : 16),
              child: isVersion
                  ? _VersionCard(event: e)
                  : isComment
                  ? _CommentBubble(event: e)
                  : e is ReplaceDiffEvent
                  ? _ReplaceDiffLine(event: e)
                  : _AuditLine(event: e as AuditEvent, repeat: entry.repeat),
            ),
          ),
        ],
      ),
    );
  }
}

class _AuditLine extends StatelessWidget {
  final AuditEvent event;
  final int repeat;

  const _AuditLine({required this.event, required this.repeat});

  /// Verb phrases, read as `<Akteur> <Label>`.
  static const _labels = {
    'create': 'hat das Dokument erstellt',
    'edit_metadata': 'hat Metadaten bearbeitet',
    'edit_fields': 'hat Felder bearbeitet',
    'version_upload': 'hat eine Version hochgeladen',
    'version_replace_file': 'hat eine Versionsdatei ersetzt',
    'version_hide': 'hat eine Version ausgeblendet',
    'version_unhide': 'hat eine Version eingeblendet',
    'version_release': 'hat eine Version freigegeben',
    'download': 'hat heruntergeladen',
    'view': 'hat angesehen',
    'archive': 'hat das Dokument archiviert',
    'unarchive': 'hat das Dokument dearchiviert',
    'type_change': 'hat den Dokumenttyp geändert',
    'extraction_done': 'Texterkennung abgeschlossen',
    'extraction_failed': 'Texterkennung fehlgeschlagen',
    'acl_change': 'hat Berechtigungen geändert',
  };

  bool get _deEmphasized =>
      event.action == 'view' || event.action == 'download';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final actor = event.actor ?? 'System';
    var label = _labels[event.action] ?? event.action;
    if (repeat > 1) {
      label = event.action == 'view'
          ? 'hat $repeat× angesehen'
          : 'hat $repeat× heruntergeladen';
    }
    if (event.action == 'version_release' &&
        event.context?['version'] != null) {
      label = 'hat v${event.context!['version']} freigegeben';
    }
    // Approvals hand-off §6: the upload/replace awaits release — say so.
    if (event.context?['pending_approval'] == true) {
      if (event.action == 'version_upload') {
        label = 'hat eine neue Version vorgeschlagen';
      }
      if (event.action == 'version_replace_file') {
        label = 'hat eine Versionsdatei ersetzt (wartet auf Freigabe)';
      }
    }
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: actor,
                style: TextStyle(
                  fontWeight: _deEmphasized
                      ? FontWeight.normal
                      : FontWeight.w600,
                  fontStyle: event.actor == null ? FontStyle.italic : null,
                ),
              ),
              TextSpan(text: ' $label'),
            ],
          ),
          style: _deEmphasized
              ? theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                )
              : theme.textTheme.bodyMedium,
        ),
        Text(formatDateTime(event.timestamp), style: muted),
        if (event.changes != null && event.changes!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _ChangesTable(changes: event.changes!),
          ),
        if (event.action == 'extraction_failed' &&
            event.context?['error'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '${event.context!['error']}',
              style: muted?.copyWith(color: scheme.error),
            ),
          ),
      ],
    );
  }
}

/// A replace_diff event: the in-place file replacement's content changes,
/// styled like an audit line (no actor — computed by the server after
/// re-extraction) with the usual collapsed diff chips below.
class _ReplaceDiffLine extends StatelessWidget {
  final ReplaceDiffEvent event;

  const _ReplaceDiffLine({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Inhalt von Version ${event.version} durch Dateiersetzung geändert',
          style: theme.textTheme.bodyMedium,
        ),
        Text(
          formatDateTime(event.timestamp),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _DiffSection(diff: event.diff),
        ),
      ],
    );
  }
}

/// old → new per changed field.
class _ChangesTable extends StatelessWidget {
  final Map<String, dynamic> changes;

  const _ChangesTable({required this.changes});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in changes.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${e.key}: ',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    TextSpan(
                      text: _fmt(e.value is Map ? e.value['old'] : null),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                    const TextSpan(text: '  →  '),
                    TextSpan(
                      text: _fmt(e.value is Map ? e.value['new'] : e.value),
                    ),
                  ],
                ),
                style: small,
              ),
            ),
        ],
      ),
    );
  }

  static String _fmt(Object? v) {
    if (v == null) return '—';
    if (v is String && v.isEmpty) return '—';
    return '$v';
  }
}

/// A comment node: user speech, styled apart from version anchors.
/// The body is untrusted plain text — rendered verbatim, newlines kept.
/// Soft-deleted comments stay visible, struck through like hidden versions.
class _CommentBubble extends StatelessWidget {
  final CommentEvent event;

  const _CommentBubble({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final deleted = event.isDeleted;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: deleted
            ? scheme.surfaceContainerLow
            : scheme.tertiaryContainer.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.chat_bubble_outline,
                size: 14,
                color: deleted ? scheme.outline : scheme.tertiary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: event.author,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const TextSpan(text: ' hat kommentiert'),
                      if (event.editedAt != null)
                        TextSpan(
                          text:
                              event.editedBy != null &&
                                  event.editedBy != event.author
                              ? ' · bearbeitet von ${event.editedBy}'
                              : ' · bearbeitet',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: deleted ? scheme.onSurfaceVariant : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            event.body,
            style: theme.textTheme.bodyMedium?.copyWith(
              decoration: deleted ? TextDecoration.lineThrough : null,
              color: deleted ? scheme.onSurfaceVariant : null,
            ),
          ),
          const SizedBox(height: 2),
          Text(formatDateTime(event.timestamp), style: muted),
          if (deleted)
            Text(
              'Entfernt'
              '${event.deletedBy != null ? ' von ${event.deletedBy}' : ''}'
              '${event.deletedAt != null ? ' · ${formatDateTime(event.deletedAt!)}' : ''}',
              style: muted?.copyWith(fontStyle: FontStyle.italic),
            ),
        ],
      ),
    );
  }
}

class _VersionCard extends StatelessWidget {
  final VersionEvent event;

  const _VersionCard({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hidden = event.isHidden;
    final titleStyle = theme.textTheme.titleSmall?.copyWith(
      decoration: hidden ? TextDecoration.lineThrough : null,
      color: hidden ? scheme.onSurfaceVariant : null,
    );

    final card = Card(
      margin: EdgeInsets.zero,
      color: hidden ? scheme.surfaceContainerLow : scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  mimeIcon(event.mimeType),
                  size: 20,
                  color: hidden ? scheme.outline : scheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Version ${event.number} · ${event.originalFilename}',
                    style: titleStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!hidden && event.isPending)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: PendingReleaseBadge(),
                  ),
                if (event.extractionStatus == ExtractionStatus.pending ||
                    event.extractionStatus == ExtractionStatus.running)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${formatBytes(event.size)} · ${event.uploadedBy} · '
              '${formatDateTime(event.timestamp)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            // Only explicit releases carry released_by; auto-released
            // versions stay unannotated (approvals hand-off §5).
            if (!hidden && event.releasedBy != null)
              Text(
                'Freigegeben von ${event.releasedBy}'
                '${event.releasedAt != null ? ' · ${formatDateTime(event.releasedAt!)}' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (hidden)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Ausgeblendet${event.hiddenBy != null ? ' von ${event.hiddenBy}' : ''}'
                  '${(event.hiddenReason?.isNotEmpty ?? false) ? ': ${event.hiddenReason}' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            // No diff section for hidden versions.
            if (!hidden && event.diff != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _DiffSection(diff: event.diff!),
              ),
            // Review surface for pending versions (approvals hand-off §6):
            // live diff against the current released content. Null until
            // extraction is done; after release the chain diff replaces it.
            if (!hidden && event.isPending && event.proposedDiff != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Was sich bei Freigabe ändert'
                      '${event.proposedDiff!.fromVersion == null ? ' (keine freigegebene Vergleichsbasis)' : ''}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    _DiffSection(diff: event.proposedDiff!),
                  ],
                ),
              ),
          ],
        ),
      ),
    );

    if (!hidden) return card;
    return Tooltip(
      message:
          'Ausgeblendet${event.hiddenBy != null ? ' von ${event.hiddenBy}' : ''}'
          '${(event.hiddenReason?.isNotEmpty ?? false) ? ' — ${event.hiddenReason}' : ''}',
      child: card,
    );
  }
}

/// Amber "wartet auf Freigabe" chip for pending versions (approvals hand-off
/// §9) — shared by the timeline version card and the detail versions card.
class PendingReleaseBadge extends StatelessWidget {
  const PendingReleaseBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: dark ? Colors.amber.shade900 : Colors.amber.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Freigabe erforderlich',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: dark ? Colors.white : Colors.amber.shade900,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Collapsed "+N −M" chips; expands to the unified diff with +/− coloring.
class _DiffSection extends StatefulWidget {
  final VersionDiff diff;

  const _DiffSection({required this.diff});

  @override
  State<_DiffSection> createState() => _DiffSectionState();
}

class _DiffSectionState extends State<_DiffSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final d = widget.diff;

    if (d.tooLarge) {
      return Text(
        'Unterschiede zu umfangreich — bitte die Datei direkt prüfen',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    }

    final chips = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _chip(context, '+${d.addedLines}', Colors.green),
        const SizedBox(width: 6),
        _chip(context, '−${d.removedLines}', Colors.red),
        const SizedBox(width: 6),
        Icon(
          _expanded ? Icons.expand_less : Icons.expand_more,
          size: 18,
          color: scheme.onSurfaceVariant,
        ),
        if (d.fromVersion != null)
          Text(
            '  ggü. v${d.fromVersion}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: (d.unifiedDiff?.isNotEmpty ?? false)
              ? () => setState(() => _expanded = !_expanded)
              : null,
          child: Padding(padding: const EdgeInsets.all(2), child: chips),
        ),
        if (_expanded && d.unifiedDiff != null)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(10),
            width: double.infinity,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: _UnifiedDiffText(diff: d.unifiedDiff!),
            ),
          ),
      ],
    );
  }

  Widget _chip(BuildContext context, String label, MaterialColor color) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: dark ? color.shade900.withValues(alpha: .5) : color.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: dark ? color.shade200 : color.shade800,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _UnifiedDiffText extends StatelessWidget {
  final String diff;

  const _UnifiedDiffText({required this.diff});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      height: 1.4,
      color: Theme.of(context).colorScheme.onSurface,
    );
    final spans = <TextSpan>[];
    for (final line in diff.split('\n')) {
      Color? color;
      if (line.startsWith('+') && !line.startsWith('+++')) {
        color = dark ? Colors.green.shade300 : Colors.green.shade800;
      } else if (line.startsWith('-') && !line.startsWith('---')) {
        color = dark ? Colors.red.shade300 : Colors.red.shade800;
      } else if (line.startsWith('@@')) {
        color = dark ? Colors.blue.shade300 : Colors.blue.shade800;
      }
      spans.add(
        TextSpan(
          text: '$line\n',
          style: color != null ? mono.copyWith(color: color) : mono,
        ),
      );
    }
    return Text.rich(TextSpan(children: spans), style: mono);
  }
}
