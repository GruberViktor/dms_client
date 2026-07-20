import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/models.dart';

/// Domain error from the server: `{"code": ..., "detail": ..., ...extras}`.
class ApiException implements Exception {
  final int? statusCode;
  final String? code; // e.g. compliance_locked, duplicate_file, invalid_metadata
  final String detail;
  final Map<String, dynamic> extras;

  ApiException({
    required this.statusCode,
    required this.code,
    required this.detail,
    this.extras = const {},
  });

  bool get isComplianceLocked => code == 'compliance_locked';
  bool get isDuplicateFile => code == 'duplicate_file';
  bool get isInvalidMetadata => code == 'invalid_metadata';
  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;

  List<String> get duplicateOf =>
      ((extras['duplicate_of'] as List?) ?? const []).map((e) => '$e').toList();

  @override
  String toString() => detail;

  static ApiException fromDio(DioException e) {
    final res = e.response;
    String detail = e.message ?? 'Network error';
    String? code;
    final extras = <String, dynamic>{};
    final data = res?.data;
    if (data is Map) {
      final map = data.cast<String, dynamic>();
      code = map['code'] as String?;
      final d = map['detail'];
      if (d is String) {
        detail = d;
      } else if (map.isNotEmpty) {
        // DRF field errors: {"field": ["msg", ...]}
        detail = map.entries
            .where((en) => en.key != 'code')
            .map((en) => '${en.key}: ${en.value is List ? (en.value as List).join(', ') : en.value}')
            .join('\n');
      }
      extras.addAll(map..remove('detail'));
    } else if (res != null) {
      detail = 'HTTP ${res.statusCode}';
    }
    return ApiException(
      statusCode: res?.statusCode,
      code: code,
      detail: detail,
      extras: extras,
    );
  }
}

typedef UnauthorizedCallback = void Function();

/// Thin hand-written client for the DMS API (client-specification.md §4).
class ApiClient {
  final Dio _dio;
  String? token;

  /// Called on any 401 so the app can drop the session and show login.
  UnauthorizedCallback? onUnauthorized;

  ApiClient(String baseUrl)
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 60),
        ));

  String get baseUrl => _dio.options.baseUrl;

  Map<String, String> get authHeaders =>
      token != null ? {'Authorization': 'Token $token'} : {};

  Future<Response<T>> _request<T>(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? query,
    ResponseType responseType = ResponseType.json,
  }) async {
    try {
      return await _dio.request<T>(
        path,
        data: data,
        queryParameters: query,
        options: Options(
          method: method,
          headers: authHeaders,
          responseType: responseType,
        ),
      );
    } on DioException catch (e) {
      final ex = ApiException.fromDio(e);
      if (ex.isUnauthorized) onUnauthorized?.call();
      throw ex;
    }
  }

  Map<String, dynamic> _asMap(Object? data) =>
      (data as Map).cast<String, dynamic>();

  // ---- Auth ----

  Future<String> login(String username, String password) async {
    final res = await _request('POST', '/auth/login',
        data: {'username': username, 'password': password});
    return _asMap(res.data)['token'] as String;
  }

  Future<void> logout() async {
    await _request('POST', '/auth/logout');
  }

  Future<CurrentUser> me() async {
    final res = await _request('GET', '/auth/me');
    return CurrentUser.fromJson(_asMap(res.data));
  }

  // ---- Document types ----

  Future<List<DocumentType>> documentTypes() async {
    // Flat tree, ordered by tree path; may be paginated — follow next links.
    final all = <DocumentType>[];
    String? next = '/document-types/';
    Map<String, dynamic>? query = {'limit': 500};
    while (next != null) {
      final res = await _request('GET', next, query: query);
      query = null;
      final data = res.data;
      if (data is List) {
        all.addAll(data
            .map((e) => DocumentType.fromJson((e as Map).cast<String, dynamic>())));
        break;
      }
      final page = Paginated.fromJson(_asMap(data), DocumentType.fromJson);
      all.addAll(page.results);
      next = page.next;
    }
    return all;
  }

  // ---- Documents ----

  Future<Paginated<Document>> documents({
    String? type,
    String? archived, // "true" | "only" | null
    String? dateFrom,
    String? dateTo,
    Map<String, String> metadataFilters = const {},
    int limit = 50,
    int offset = 0,
  }) async {
    final query = <String, dynamic>{
      'type': ?type,
      'archived': ?archived,
      'document_date_from': ?dateFrom,
      'document_date_to': ?dateTo,
      for (final e in metadataFilters.entries) 'metadata__${e.key}': e.value,
      'limit': limit,
      'offset': offset,
    };
    final res = await _request('GET', '/documents/', query: query);
    return Paginated.fromJson(_asMap(res.data), Document.fromJson);
  }

  Future<Document> document(String uuid) async {
    final res = await _request('GET', '/documents/$uuid/');
    return Document.fromJson(_asMap(res.data));
  }

  Future<Document> patchDocument(String uuid, Map<String, dynamic> patch) async {
    final res = await _request('PATCH', '/documents/$uuid/', data: patch);
    return Document.fromJson(_asMap(res.data));
  }

  Future<void> deleteDocument(String uuid) async {
    await _request('DELETE', '/documents/$uuid/');
  }

  Future<void> archiveDocument(String uuid) async {
    await _request('POST', '/documents/$uuid/archive/');
  }

  Future<void> unarchiveDocument(String uuid) async {
    await _request('POST', '/documents/$uuid/unarchive/');
  }

  Future<List<TimelineEvent>> timeline(String uuid) async {
    final res = await _request('GET', '/documents/$uuid/timeline/');
    return ((_asMap(res.data)['events'] as List?) ?? const [])
        .map((e) => TimelineEvent.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<Document> uploadDocument({
    required MultipartFile file,
    required String title,
    required String documentType,
    String? documentDate,
    String? notes,
    Map<String, dynamic> metadata = const {},
    bool force = false,
  }) async {
    final form = FormData.fromMap({
      'file': file,
      'title': title,
      'document_type': documentType,
      'document_date': ?documentDate,
      'notes': ?notes,
      // metadata must be a JSON *string* form field.
      'metadata': jsonEncode(metadata),
      if (force) 'force': 'true',
    });
    final res = await _request('POST', '/documents/', data: form);
    return Document.fromJson(_asMap(res.data));
  }

  // ---- Versions ----

  Future<DocumentVersion> uploadVersion(String uuid, MultipartFile file,
      {bool force = false}) async {
    final form = FormData.fromMap({'file': file, if (force) 'force': 'true'});
    final res = await _request('POST', '/documents/$uuid/versions/', data: form);
    return DocumentVersion.fromJson(_asMap(res.data));
  }

  /// Replace the bytes of version [number] in place.
  /// 409 compliance_locked when the document is in compliance mode.
  Future<DocumentVersion> replaceVersionFile(
      String uuid, int number, MultipartFile file) async {
    final res = await _request(
      'PUT',
      '/documents/$uuid/versions/$number/file',
      data: FormData.fromMap({'file': file}),
    );
    return DocumentVersion.fromJson(_asMap(res.data));
  }

  Future<DocumentVersion> version(String uuid, int number) async {
    final res = await _request('GET', '/documents/$uuid/versions/$number/');
    return DocumentVersion.fromJson(_asMap(res.data));
  }

  Future<Uint8List> downloadVersion(String uuid, int number) async {
    final res = await _request<List<int>>(
      'GET',
      '/documents/$uuid/versions/$number/download',
      responseType: ResponseType.bytes,
    );
    return Uint8List.fromList(res.data!);
  }

  Future<DocumentVersion> hideVersion(String uuid, int number,
      {String? reason}) async {
    final res = await _request(
      'POST',
      '/documents/$uuid/versions/$number/hide',
      data: {'reason': ?reason},
    );
    return DocumentVersion.fromJson(_asMap(res.data));
  }

  Future<DocumentVersion> unhideVersion(String uuid, int number) async {
    final res =
        await _request('POST', '/documents/$uuid/versions/$number/unhide');
    return DocumentVersion.fromJson(_asMap(res.data));
  }

  Future<DocumentVersion> reExtract(String uuid, int number) async {
    final res =
        await _request('POST', '/documents/$uuid/versions/$number/re-extract');
    return DocumentVersion.fromJson(_asMap(res.data));
  }

  /// 409 compliance_locked in compliance mode.
  Future<Document> changeType(String uuid, String documentType,
      {Map<String, dynamic>? metadata}) async {
    final res = await _request('POST', '/documents/$uuid/change-type/', data: {
      'document_type': documentType,
      'metadata': ?metadata,
    });
    return Document.fromJson(_asMap(res.data));
  }

  // ---- Previews ----

  /// URL for the latest-visible-version preview (list thumbnails).
  String documentPreviewUrl(String uuid, {String size = 'thumb', int page = 1}) =>
      '$baseUrl/documents/$uuid/preview/?size=$size&page=$page';

  String versionPreviewUrl(String uuid, int number,
          {String size = 'preview', int page = 1}) =>
      '$baseUrl/documents/$uuid/versions/$number/preview?size=$size&page=$page';

  // ---- Search ----

  Future<Paginated<SearchHit>> search(
    String q, {
    String? type,
    String? archived,
    int limit = 50,
    int offset = 0,
  }) async {
    final res = await _request('GET', '/search/', query: {
      'q': q,
      'type': ?type,
      'archived': ?archived,
      'limit': limit,
      'offset': offset,
    });
    return Paginated.fromJson(_asMap(res.data), SearchHit.fromJson);
  }

  // ---- Indexes ----

  Future<List<DmsIndex>> indexes() async {
    final res = await _request('GET', '/indexes/', query: {'limit': 200});
    final data = res.data;
    if (data is List) {
      return data
          .map((e) => DmsIndex.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    }
    return Paginated.fromJson(_asMap(data), DmsIndex.fromJson).results;
  }

  Future<DmsIndex> createIndex(Map<String, dynamic> body) async {
    final res = await _request('POST', '/indexes/', data: body);
    return DmsIndex.fromJson(_asMap(res.data));
  }

  Future<DmsIndex> patchIndex(String slug, Map<String, dynamic> body) async {
    final res = await _request('PATCH', '/indexes/$slug/', data: body);
    return DmsIndex.fromJson(_asMap(res.data));
  }

  Future<void> deleteIndex(String slug) async {
    await _request('DELETE', '/indexes/$slug/');
  }

  /// While drilling returns {"nodes": [...]}; at leaf depth returns a
  /// paginated document list. The result is one or the other.
  Future<({List<IndexNode>? nodes, Paginated<Document>? documents})> indexNodes(
    String slug, {
    String path = '',
    String? archived,
    int limit = 50,
    int offset = 0,
  }) async {
    final res = await _request('GET', '/indexes/$slug/nodes/', query: {
      if (path.isNotEmpty) 'path': path,
      'archived': ?archived,
      'limit': limit,
      'offset': offset,
    });
    final map = _asMap(res.data);
    if (map.containsKey('nodes')) {
      final nodes = (map['nodes'] as List)
          .map((e) => IndexNode.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      return (nodes: nodes, documents: null);
    }
    return (nodes: null, documents: Paginated.fromJson(map, Document.fromJson));
  }

  // ---- Admin: document types ----

  Future<DocumentType> createDocumentType(Map<String, dynamic> body) async {
    final res = await _request('POST', '/document-types/', data: body);
    return DocumentType.fromJson(_asMap(res.data));
  }

  Future<DocumentType> patchDocumentType(
      String slug, Map<String, dynamic> body) async {
    final res = await _request('PATCH', '/document-types/$slug/', data: body);
    return DocumentType.fromJson(_asMap(res.data));
  }

  Future<void> deleteDocumentType(String slug) async {
    await _request('DELETE', '/document-types/$slug/');
  }

  // ---- Admin: metadata fields (own definitions of one type) ----

  Future<List<MetadataFieldDef>> metadataFields(String typeSlug) async {
    final res = await _request(
        'GET', '/document-types/$typeSlug/metadata-fields/',
        query: {'limit': 500});
    final data = res.data;
    if (data is List) {
      return data
          .map((e) =>
              MetadataFieldDef.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    }
    return Paginated.fromJson(_asMap(data), MetadataFieldDef.fromJson).results;
  }

  Future<void> createMetadataField(
      String typeSlug, Map<String, dynamic> body) async {
    await _request('POST', '/document-types/$typeSlug/metadata-fields/',
        data: body);
  }

  Future<void> patchMetadataField(
      String typeSlug, int id, Map<String, dynamic> body) async {
    await _request('PATCH', '/document-types/$typeSlug/metadata-fields/$id/',
        data: body);
  }

  Future<void> deleteMetadataField(String typeSlug, int id) async {
    await _request('DELETE', '/document-types/$typeSlug/metadata-fields/$id/');
  }

  // ---- Admin: ACLs ----

  /// → {"own": [{group, permissions}...], "effective": {...}}
  Future<Map<String, dynamic>> acls(String typeSlug) async {
    final res = await _request('GET', '/document-types/$typeSlug/acls/');
    return _asMap(res.data);
  }

  Future<Map<String, dynamic>> putAcls(
      String typeSlug, List<AclEntry> entries) async {
    final res = await _request('PUT', '/document-types/$typeSlug/acls/',
        data: entries.map((e) => e.toJson()).toList());
    return _asMap(res.data);
  }

  // ---- Admin: retention policies ----

  Future<List<RetentionPolicy>> retentionPolicies() async {
    final res =
        await _request('GET', '/retention-policies/', query: {'limit': 200});
    return Paginated.fromJson(_asMap(res.data), RetentionPolicy.fromJson)
        .results;
  }

  Future<RetentionPolicy> createRetentionPolicy(
      Map<String, dynamic> body) async {
    final res = await _request('POST', '/retention-policies/', data: body);
    return RetentionPolicy.fromJson(_asMap(res.data));
  }

  Future<RetentionPolicy> patchRetentionPolicy(
      int id, Map<String, dynamic> body) async {
    final res =
        await _request('PATCH', '/retention-policies/$id/', data: body);
    return RetentionPolicy.fromJson(_asMap(res.data));
  }

  Future<void> deleteRetentionPolicy(int id) async {
    await _request('DELETE', '/retention-policies/$id/');
  }

  // ---- Admin: storages ----

  Future<List<Storage>> storages() async {
    final res = await _request('GET', '/storages/', query: {'limit': 200});
    return Paginated.fromJson(_asMap(res.data), Storage.fromJson).results;
  }

  Future<Storage> createStorage(Map<String, dynamic> body) async {
    final res = await _request('POST', '/storages/', data: body);
    return Storage.fromJson(_asMap(res.data));
  }

  Future<Storage> patchStorage(int id, Map<String, dynamic> body) async {
    final res = await _request('PATCH', '/storages/$id/', data: body);
    return Storage.fromJson(_asMap(res.data));
  }

  Future<void> deleteStorage(int id) async {
    await _request('DELETE', '/storages/$id/');
  }
}
