import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../widgets/file_drag.dart';
import 'format.dart';

/// Fetch a version through the *download* route (needs `download`, audited
/// as one) and write it to `<tmp>/<subdir>/<uuid>/v<n>/<original name>`.
/// [asPdf] uses the server-side PDF conversion and swaps the extension.
Future<File> downloadVersionToTemp(
  ApiClient api,
  String uuid,
  DocumentVersion v, {
  bool asPdf = false,
  String subdir = 'dms',
}) async {
  final bytes = asPdf
      ? await api.downloadVersionPdf(uuid, v.number)
      : await api.downloadVersion(uuid, v.number);
  final dir = await getTemporaryDirectory();
  final file = File(
      '${dir.path}/$subdir/$uuid/v${v.number}/${versionFilename(v, asPdf: asPdf)}');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes);
  return file;
}

/// Fetch a version like [downloadVersionToTemp] for handing to another app
/// by drag & drop. It lands in the user's Downloads folder, not /tmp:
/// sandboxed targets (snap/flatpak Thunderbird) see a private /tmp and
/// would attach an empty file. The user's files there are never
/// overwritten — an identical file of that name is reused, otherwise the
/// copy gets a " (n)" suffix.
Future<File> downloadVersionForDrag(
  ApiClient api,
  String uuid,
  DocumentVersion v, {
  bool asPdf = false,
}) async {
  final bytes = asPdf
      ? await api.downloadVersionPdf(uuid, v.number)
      : await api.downloadVersion(uuid, v.number);
  final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
  await dir.create(recursive: true);
  final name = versionFilename(v, asPdf: asPdf);
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var n = 1;; n++) {
    final file = File('${dir.path}/${n == 1 ? name : '$stem ($n)$ext'}');
    if (!await file.exists()) {
      await file.writeAsBytes(bytes);
      return file;
    }
    if (await file.length() == bytes.length &&
        _sameBytes(await file.readAsBytes(), bytes)) {
      return file;
    }
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// What dragging [v] out hands over: its PDF rendition wherever the server
/// has one ([canDownloadAsPdf]; PDF originals are already PDFs), the
/// original otherwise — there is no PDF to give for e.g. Markdown or images.
FileDragSpec dragSpecFor(ApiClient api, String uuid, DocumentVersion v) {
  final asPdf = canDownloadAsPdf(v.mimeType);
  return FileDragSpec(
    name: versionFilename(v, asPdf: asPdf),
    fetch: () => downloadVersionForDrag(api, uuid, v, asPdf: asPdf),
  );
}

/// The local file name for [v]: its original name made path-safe, with the
/// extension swapped to .pdf for the converted variant.
String versionFilename(DocumentVersion v, {bool asPdf = false}) {
  final name = v.originalFilename.isNotEmpty
      ? v.originalFilename.replaceAll(RegExp(r'[/\\]'), '_')
      : 'document';
  return asPdf ? pdfFilename(name) : name;
}
