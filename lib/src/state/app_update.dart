import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// A GitHub release newer than the running app. [tarball] is set only when
/// this app can replace itself with it, see [_selfUpdatable].
typedef AppRelease = ({String version, String url, String? tarball});

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
      tarball: _selfUpdatable()
          ? [
              for (final a in res.data!['assets'] as List)
                if ((a['name'] as String).endsWith('-linux-x64.tar.gz'))
                  a['browser_download_url'] as String,
            ].firstOrNull
          : null,
    );
  } catch (_) {
    return null;
  }
});

/// The running binary sits in the per-user install of `install.sh`. A system
/// install (/opt) needs root, a dev build is not installed at all — both
/// keep the browser download.
bool _selfUpdatable() {
  if (!Platform.isLinux) return false;
  final dataHome =
      Platform.environment['XDG_DATA_HOME'] ??
      '${Platform.environment['HOME']}/.local/share';
  return File(Platform.resolvedExecutable).parent.path == '$dataHome/luvi-docs';
}

/// Downloads and installs [tarballUrl] with its own `install.sh`, then
/// restarts the app. Throws on failure; the old install stays then, as
/// install.sh only runs after a complete download and unpack.
Future<void> installLinuxUpdate(String tarballUrl) async {
  final dir = await Directory.systemTemp.createTemp('luvi-docs-update');
  final tar = '${dir.path}/update.tar.gz';
  await Dio().download(tarballUrl, tar);
  Future<void> run(String exe, List<String> args) async {
    final r = await Process.run(exe, args, workingDirectory: dir.path);
    if (r.exitCode != 0) throw Exception('$exe: ${r.stderr}');
  }

  await run('tar', ['-xzf', tar]);
  // Replaces the app directory under the running process: Linux keeps the
  // deleted files mapped until exit, and we exit right below.
  await run('${dir.path}/install.sh', []);
  // The runner is single instance: a new process started while this one is
  // alive would only raise this window. So wait for our exit first.
  await Process.start('sh', [
    '-c',
    'while kill -0 \$0 2>/dev/null; do sleep 0.2; done; '
        'rm -rf "\$2"; exec "\$1"',
    '$pid',
    Platform.resolvedExecutable,
    dir.path,
  ], mode: ProcessStartMode.detached);
  exit(0);
}
