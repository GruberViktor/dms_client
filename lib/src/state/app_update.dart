import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// A GitHub release newer than the running app.
typedef AppRelease = ({String version, String url});

const _latestReleaseUrl =
    'https://api.github.com/repos/GruberViktor/dms_client/releases/latest';

/// True when [candidate] ("v1.3.0" or "1.3.0") is newer than [current].
bool isNewerVersion(String candidate, String current) {
  List<int> parse(String v) => v
      .replaceFirst(RegExp('^v'), '')
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final a = parse(candidate), b = parse(current);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// Checked once per app run. Null when up to date or when the check fails
/// (offline, rate limit) — an update notice is not worth an error.
final appUpdateProvider = FutureProvider<AppRelease?>((ref) async {
  try {
    // Own Dio: the API client would send the Knox token to GitHub.
    final res = await Dio().get<Map<String, dynamic>>(_latestReleaseUrl);
    final tag = res.data!['tag_name'] as String;
    final info = await PackageInfo.fromPlatform();
    if (!isNewerVersion(tag, info.version)) return null;
    return (
      version: tag.replaceFirst(RegExp('^v'), ''),
      url: res.data!['html_url'] as String,
    );
  } catch (_) {
    return null;
  }
});
