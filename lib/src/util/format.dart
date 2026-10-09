import 'package:decimal/decimal.dart';
import 'package:decimal/intl.dart';
import 'package:intl/intl.dart';

final _dateFmt = DateFormat.yMMMd();
final _dateTimeFmt = DateFormat.yMMMd().add_Hm();

/// German number formatting for monetary values: `1234.5` → `1.234,50`.
/// Formats straight from `Decimal` (never via `double`), so long decimal
/// strings keep their exact value.
final _moneyFmt = DecimalFormatter(
  NumberFormat.decimalPatternDigits(decimalDigits: 2),
);

String formatDate(String? isoDate) {
  if (isoDate == null || isoDate.isEmpty) return '—';
  final d = DateTime.tryParse(isoDate);
  return d != null ? _dateFmt.format(d) : isoDate;
}

String formatDateTime(DateTime? dt) =>
    dt != null ? _dateTimeFmt.format(dt.toLocal()) : '—';

/// Monetary metadata values arrive as decimal strings (see CLAUDE.md); older
/// rows may still carry a JSON number. Rendered German: comma decimal
/// separator, dot grouping, always two decimals. Anything unparseable is
/// shown verbatim rather than swallowed.
String formatMonetary(Object? value) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) return '—';
  final dec = Decimal.tryParse(raw.replaceAll(',', '.'));
  return dec != null ? _moneyFmt.format(dec) : raw;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  var i = -1;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 10 ? 0 : 1)} ${units[i]}';
}

/// Substring match: servers may append parameters (e.g. `; charset=binary`).
bool isPdfMime(String? mime) => (mime ?? '').contains('application/pdf');

/// Formats the server can convert on the fly via
/// GET /documents/{uuid}/versions/{n}/download/pdf (odt, docx, drawio).
/// Substring match: servers may append parameters (e.g. `; charset=binary`).
bool canDownloadAsPdf(String? mime) {
  final m = mime ?? '';
  return m.contains('officedocument.wordprocessingml.document') ||
      m.contains('opendocument.text') ||
      m.contains('vnd.jgraph.mxfile');
}

/// Markdown source we can render in-app from the extracted text.
/// libmagic sniffs `.md` as `text/plain` far more often than `text/markdown`,
/// so the filename decides and the mime only has to be textual (or unknown,
/// e.g. while a version row carries no mime yet).
bool isMarkdown(String? mime, String? filename) {
  final m = mime ?? '';
  if (m.isNotEmpty && !m.startsWith('text/')) return false;
  final n = (filename ?? '').toLowerCase();
  return n.endsWith('.md') ||
      n.endsWith('.markdown') ||
      n.endsWith('.mdown') ||
      n.endsWith('.mkd');
}

/// "report.docx" → "report.pdf" (extension swapped, not appended).
String pdfFilename(String name) {
  final dot = name.lastIndexOf('.');
  return '${dot > 0 ? name.substring(0, dot) : name}.pdf';
}

/// Icon-name category for a mime type (used when no preview exists).
String mimeCategory(String? mime) {
  final m = mime ?? '';
  if (m.startsWith('image/')) return 'image';
  if (m == 'application/pdf') return 'pdf';
  if (m.contains('spreadsheet') || m.contains('excel') || m == 'text/csv') {
    return 'sheet';
  }
  if (m.contains('word') || m.contains('opendocument.text')) return 'doc';
  if (m.startsWith('text/')) return 'text';
  if (m.contains('presentation') || m.contains('powerpoint')) return 'slides';
  if (m.contains('zip') || m.contains('compressed') || m.contains('tar')) {
    return 'archive';
  }
  if (m.startsWith('audio/')) return 'audio';
  if (m.startsWith('video/')) return 'video';
  return 'file';
}
