import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import 'permissions.dart';

const _storage = FlutterSecureStorage();
const _kToken = 'dms_token';
const _kBaseUrl = 'dms_base_url';
const _kDefaultBaseUrl = 'http://localhost:8000/api/v1';

class Session {
  final ApiClient api;
  final CurrentUser user;
  Session(this.api, this.user);
}

class SessionState {
  final Session? session;
  final bool restoring;
  const SessionState({this.session, this.restoring = false});

  bool get loggedIn => session != null;
}

class SessionNotifier extends Notifier<SessionState> {
  @override
  SessionState build() {
    Future.microtask(restore);
    return const SessionState(restoring: true);
  }

  /// Restore a previous session from secure storage on startup.
  Future<void> restore() async {
    try {
      final token = await _storage.read(key: _kToken);
      final baseUrl = await _storage.read(key: _kBaseUrl) ?? _kDefaultBaseUrl;
      if (token == null) {
        state = const SessionState();
        return;
      }
      final api = _buildClient(baseUrl)..token = token;
      final user = await api.me();
      state = SessionState(session: Session(api, user));
    } catch (_) {
      // Token expired/revoked or server unreachable → show login.
      state = const SessionState();
    }
  }

  Future<String> storedBaseUrl() async =>
      await _storage.read(key: _kBaseUrl) ?? _kDefaultBaseUrl;

  Future<void> login(String baseUrl, String username, String password) async {
    final normalized = _normalizeBaseUrl(baseUrl);
    final api = _buildClient(normalized);
    final token = await api.login(username, password);
    api.token = token;
    final user = await api.me();
    await _storage.write(key: _kToken, value: token);
    await _storage.write(key: _kBaseUrl, value: normalized);
    state = SessionState(session: Session(api, user));
  }

  Future<void> logout() async {
    final s = state.session;
    if (s != null) {
      try {
        await s.api.logout();
      } catch (_) {
        // Token may already be dead; drop it locally regardless.
      }
    }
    await _storage.delete(key: _kToken);
    ref.invalidate(deniedActionsProvider);
    state = const SessionState();
  }

  /// 401 from any call: token is gone server-side.
  void sessionExpired() {
    _storage.delete(key: _kToken);
    ref.invalidate(deniedActionsProvider);
    state = const SessionState();
  }

  ApiClient _buildClient(String baseUrl) {
    final api = ApiClient(baseUrl);
    api.onUnauthorized = sessionExpired;
    return api;
  }

  static String _normalizeBaseUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return _kDefaultBaseUrl;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (!url.endsWith('/api/v1')) url = '$url/api/v1';
    return url;
  }
}

final sessionProvider =
    NotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);

/// Convenience: the API client of the active session. Only read when logged in.
final apiProvider = Provider<ApiClient>((ref) {
  final s = ref.watch(sessionProvider).session;
  if (s == null) throw StateError('Not logged in');
  return s.api;
});

/// Document types, fetched once per session (invalidate to refresh).
final documentTypesProvider = FutureProvider<List<DocumentType>>((ref) async {
  final api = ref.watch(apiProvider);
  return api.documentTypes();
});

final documentTypesBySlugProvider =
    Provider<Map<String, DocumentType>>((ref) {
  final types = ref.watch(documentTypesProvider).value ?? const <DocumentType>[];
  return {for (final t in types) t.slug: t};
});
