import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';

/// Open [path] with the system default application. Returns true on success.
///
/// On desktop this goes through url_launcher (gtk_show_uri → D-Bus/gio
/// activation on Linux) instead of open_filex, which spawns `xdg-open` as a
/// child process with Dart-piped stdio: the pipes close once xdg-open exits,
/// and the opened application dies of SIGPIPE on its next stderr write
/// (observed with LibreOffice, which then leaves a stale /tmp/OSL_PIPE_*
/// socket that makes every later launch quit silently). Mobile keeps
/// open_filex — Android cannot launch file:// URIs.
Future<bool> openExternally(String path) async {
  if (Platform.isAndroid || Platform.isIOS) {
    final result = await OpenFilex.open(path);
    return result.type == ResultType.done;
  }
  return launchUrl(Uri.file(path));
}
