import 'package:intl/intl.dart';

final _dateFmt = DateFormat.yMMMd();
final _dateTimeFmt = DateFormat.yMMMd().add_Hm();

String formatDate(String? isoDate) {
  if (isoDate == null || isoDate.isEmpty) return '—';
  final d = DateTime.tryParse(isoDate);
  return d != null ? _dateFmt.format(d) : isoDate;
}

String formatDateTime(DateTime? dt) =>
    dt != null ? _dateTimeFmt.format(dt.toLocal()) : '—';

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

/// Formats the server can convert on the fly via
/// GET /documents/{uuid}/versions/{n}/download/pdf (odt and docx).
/// Substring match: servers may append parameters (e.g. `; charset=binary`).
bool canDownloadAsPdf(String? mime) {
  final m = mime ?? '';
  return m.contains('officedocument.wordprocessingml.document') ||
      m.contains('opendocument.text');
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
