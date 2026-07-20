/// Domain models for the DMS API (see client-specification.md §3/§4).
library;

class Paginated<T> {
  final int count;
  final String? next;
  final String? previous;
  final List<T> results;

  Paginated({
    required this.count,
    required this.next,
    required this.previous,
    required this.results,
  });

  factory Paginated.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) itemFromJson,
  ) {
    return Paginated(
      count: json['count'] as int,
      next: json['next'] as String?,
      previous: json['previous'] as String?,
      results: (json['results'] as List)
          .map((e) => itemFromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

enum FieldType { text, date, integer, float, monetary, boolean, url, unknown }

FieldType fieldTypeFromWire(String? s) => switch (s) {
      'text' => FieldType.text,
      'date' => FieldType.date,
      'integer' => FieldType.integer,
      'float' => FieldType.float,
      'monetary' => FieldType.monetary,
      'bool' => FieldType.boolean,
      'url' => FieldType.url,
      _ => FieldType.unknown,
    };

class MetadataFieldDef {
  final int? id; // DB id — present on the admin list endpoint
  final String key;
  final String label;
  final FieldType fieldType;
  final bool required;
  final Object? defaultValue;
  final int ordering;
  final bool indexed;

  MetadataFieldDef({
    this.id,
    required this.key,
    required this.label,
    required this.fieldType,
    required this.required,
    required this.defaultValue,
    required this.ordering,
    required this.indexed,
  });

  factory MetadataFieldDef.fromJson(Map<String, dynamic> json) =>
      MetadataFieldDef(
        id: (json['id'] as num?)?.toInt(),
        key: json['key'] as String,
        label: (json['label'] as String?) ?? json['key'] as String,
        fieldType: fieldTypeFromWire(json['field_type'] as String?),
        required: json['required'] == true,
        defaultValue: json['default'],
        ordering: (json['ordering'] as num?)?.toInt() ?? 0,
        indexed: json['indexed'] == true,
      );
}

class DocumentType {
  final String slug;
  final String name;
  final String? parentSlug;
  final int depth;
  final int? retentionPolicy;
  final bool isActive;
  final List<MetadataFieldDef> metadataFields;

  DocumentType({
    required this.slug,
    required this.name,
    required this.parentSlug,
    required this.depth,
    required this.retentionPolicy,
    required this.isActive,
    required this.metadataFields,
  });

  factory DocumentType.fromJson(Map<String, dynamic> json) => DocumentType(
        slug: json['slug'] as String,
        name: json['name'] as String,
        parentSlug: (json['parent_slug'] as String?)?.isNotEmpty == true
            ? json['parent_slug'] as String
            : null,
        depth: (json['depth'] as num?)?.toInt() ?? 0,
        retentionPolicy: (json['retention_policy'] as num?)?.toInt(),
        isActive: json['is_active'] != false,
        metadataFields: ((json['metadata_fields'] as List?) ?? const [])
            .map((e) => MetadataFieldDef.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Builds the merged (ancestor-inherited) metadata field set for [slug]:
/// walk up parent_slug; child keys override ancestor keys.
List<MetadataFieldDef> mergedMetadataFields(
    Map<String, DocumentType> bySlug, String slug) {
  final chain = <DocumentType>[];
  String? cur = slug;
  final seen = <String>{};
  while (cur != null && seen.add(cur)) {
    final t = bySlug[cur];
    if (t == null) break;
    chain.add(t);
    cur = t.parentSlug;
  }
  final merged = <String, MetadataFieldDef>{};
  // Root first so children override.
  for (final t in chain.reversed) {
    for (final f in t.metadataFields) {
      merged[f.key] = f;
    }
  }
  final list = merged.values.toList()
    ..sort((a, b) => a.ordering.compareTo(b.ordering));
  return list;
}

bool _asBool(Object? v) {
  if (v is bool) return v;
  if (v is String) return v.toLowerCase() == 'true';
  return false;
}

enum ExtractionStatus { pending, running, done, failed, unknown }

ExtractionStatus extractionStatusFromWire(String? s) => switch (s) {
      'pending' => ExtractionStatus.pending,
      'running' => ExtractionStatus.running,
      'done' => ExtractionStatus.done,
      'failed' => ExtractionStatus.failed,
      _ => ExtractionStatus.unknown,
    };

class DocumentVersion {
  final int number;
  final String originalFilename;
  final String mimeType;
  final int size;
  final String checksumSha256;
  final ExtractionStatus extractionStatus;
  final String? extractionBackend;
  final bool isHidden;
  final String? hiddenBy;
  final DateTime? hiddenAt;
  final String? hiddenReason;
  final String uploadedBy;
  final DateTime uploadedAt;
  final DateTime? objectLockUntil;
  final int? pageCount;
  final String? consoleUrl;

  DocumentVersion({
    required this.number,
    required this.originalFilename,
    required this.mimeType,
    required this.size,
    required this.checksumSha256,
    required this.extractionStatus,
    required this.extractionBackend,
    required this.isHidden,
    required this.hiddenBy,
    required this.hiddenAt,
    required this.hiddenReason,
    required this.uploadedBy,
    required this.uploadedAt,
    required this.objectLockUntil,
    required this.pageCount,
    required this.consoleUrl,
  });

  factory DocumentVersion.fromJson(Map<String, dynamic> json) =>
      DocumentVersion(
        number: (json['number'] as num).toInt(),
        originalFilename: (json['original_filename'] as String?) ?? '',
        mimeType: (json['mime_type'] as String?) ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        checksumSha256: (json['checksum_sha256'] as String?) ?? '',
        extractionStatus:
            extractionStatusFromWire(json['extraction_status'] as String?),
        extractionBackend: json['extraction_backend'] as String?,
        isHidden: _asBool(json['is_hidden']),
        hiddenBy: json['hidden_by'] as String?,
        hiddenAt: json['hidden_at'] != null
            ? DateTime.tryParse(json['hidden_at'] as String)
            : null,
        hiddenReason: json['hidden_reason'] as String?,
        uploadedBy: (json['uploaded_by'] as String?) ?? '',
        uploadedAt: DateTime.parse(json['uploaded_at'] as String),
        objectLockUntil: json['object_lock_until'] != null
            ? DateTime.tryParse(json['object_lock_until'] as String)
            : null,
        pageCount: (json['page_count'] as num?)?.toInt(),
        consoleUrl: json['console_url'] as String?,
      );
}

class Document {
  final String uuid;
  final String title;
  final String documentType;
  final String? documentDate; // YYYY-MM-DD
  final DateTime dateAdded;
  final String addedBy;
  final String? notes;
  final Map<String, dynamic> metadata;
  final bool archived;
  final String? retentionUntil; // YYYY-MM-DD
  final bool inComplianceMode;
  // Detail-only:
  final String? content;
  final String? mimeType;
  final List<DocumentVersion> versions;

  Document({
    required this.uuid,
    required this.title,
    required this.documentType,
    required this.documentDate,
    required this.dateAdded,
    required this.addedBy,
    required this.notes,
    required this.metadata,
    required this.archived,
    required this.retentionUntil,
    required this.inComplianceMode,
    required this.content,
    required this.mimeType,
    required this.versions,
  });

  factory Document.fromJson(Map<String, dynamic> json) => Document(
        uuid: json['uuid'] as String,
        title: (json['title'] as String?) ?? '',
        documentType: (json['document_type'] as String?) ?? '',
        documentDate: json['document_date'] as String?,
        dateAdded: DateTime.parse(json['date_added'] as String),
        addedBy: (json['added_by'] as String?) ?? '',
        notes: json['notes'] as String?,
        metadata: (json['metadata'] as Map?)?.cast<String, dynamic>() ?? {},
        archived: _asBool(json['archived']),
        retentionUntil: json['retention_until'] as String?,
        inComplianceMode: _asBool(json['in_compliance_mode']),
        content: json['content'] as String?,
        mimeType: json['mime_type'] as String?,
        versions: ((json['versions'] as List?) ?? const [])
            .map((e) => DocumentVersion.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// Newest visible version — "the document".
  DocumentVersion? get currentVersion {
    DocumentVersion? best;
    for (final v in versions) {
      if (v.isHidden) continue;
      if (best == null || v.number > best.number) best = v;
    }
    return best;
  }
}

class VersionDiff {
  final int? fromVersion;
  final int? toVersion;
  final String? unifiedDiff;
  final int addedLines;
  final int removedLines;
  final bool tooLarge;

  VersionDiff({
    required this.fromVersion,
    required this.toVersion,
    required this.unifiedDiff,
    required this.addedLines,
    required this.removedLines,
    required this.tooLarge,
  });

  factory VersionDiff.fromJson(Map<String, dynamic> json) => VersionDiff(
        fromVersion: (json['from_version'] as num?)?.toInt(),
        toVersion: (json['to_version'] as num?)?.toInt(),
        unifiedDiff: json['unified_diff'] as String?,
        addedLines: (json['added_lines'] as num?)?.toInt() ?? 0,
        removedLines: (json['removed_lines'] as num?)?.toInt() ?? 0,
        tooLarge: _asBool(json['too_large']),
      );
}

sealed class TimelineEvent {
  final DateTime timestamp;
  TimelineEvent(this.timestamp);

  static TimelineEvent fromJson(Map<String, dynamic> json) {
    final ts = DateTime.parse(json['timestamp'] as String);
    if (json['kind'] == 'version') {
      return VersionEvent(
        timestamp: ts,
        number: (json['number'] as num).toInt(),
        originalFilename: (json['original_filename'] as String?) ?? '',
        mimeType: (json['mime_type'] as String?) ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        uploadedBy: (json['uploaded_by'] as String?) ?? '',
        extractionStatus:
            extractionStatusFromWire(json['extraction_status'] as String?),
        isHidden: _asBool(json['is_hidden']),
        hiddenBy: json['hidden_by'] as String?,
        hiddenReason: json['hidden_reason'] as String?,
        diff: json['diff'] != null
            ? VersionDiff.fromJson(json['diff'] as Map<String, dynamic>)
            : null,
      );
    }
    return AuditEvent(
      timestamp: ts,
      action: (json['action'] as String?) ?? 'unknown',
      actor: json['actor'] as String?,
      changes: (json['changes'] as Map?)?.cast<String, dynamic>(),
      context: (json['context'] as Map?)?.cast<String, dynamic>(),
    );
  }
}

class AuditEvent extends TimelineEvent {
  final String action;
  final String? actor; // null = system
  final Map<String, dynamic>? changes;
  final Map<String, dynamic>? context;

  AuditEvent({
    required DateTime timestamp,
    required this.action,
    required this.actor,
    required this.changes,
    required this.context,
  }) : super(timestamp);
}

class VersionEvent extends TimelineEvent {
  final int number;
  final String originalFilename;
  final String mimeType;
  final int size;
  final String uploadedBy;
  final ExtractionStatus extractionStatus;
  final bool isHidden;
  final String? hiddenBy;
  final String? hiddenReason;
  final VersionDiff? diff;

  VersionEvent({
    required DateTime timestamp,
    required this.number,
    required this.originalFilename,
    required this.mimeType,
    required this.size,
    required this.uploadedBy,
    required this.extractionStatus,
    required this.isHidden,
    required this.hiddenBy,
    required this.hiddenReason,
    required this.diff,
  }) : super(timestamp);
}

class SearchHit {
  final String uuid;
  final String title;
  final String documentType;
  final String? documentDate;
  final DateTime? dateAdded;
  final bool archived;
  final double? rank;
  final String headline; // contains <b>..</b> around matches

  SearchHit({
    required this.uuid,
    required this.title,
    required this.documentType,
    required this.documentDate,
    required this.dateAdded,
    required this.archived,
    required this.rank,
    required this.headline,
  });

  factory SearchHit.fromJson(Map<String, dynamic> json) => SearchHit(
        uuid: json['uuid'] as String,
        title: (json['title'] as String?) ?? '',
        documentType: (json['document_type'] as String?) ?? '',
        documentDate: json['document_date'] as String?,
        dateAdded: json['date_added'] != null
            ? DateTime.tryParse(json['date_added'] as String)
            : null,
        archived: _asBool(json['archived']),
        rank: (json['rank'] as num?)?.toDouble(),
        headline: (json['headline'] as String?) ?? '',
      );
}

class IndexLevel {
  final int position;
  final String source; // metadata|document_date|document_type|added_by
  final String? sourceKey;
  final String transform; // none|year|year_month|first_letter
  final bool descending;

  IndexLevel({
    required this.position,
    required this.source,
    required this.sourceKey,
    required this.transform,
    required this.descending,
  });

  factory IndexLevel.fromJson(Map<String, dynamic> json) => IndexLevel(
        position: (json['position'] as num?)?.toInt() ?? 0,
        source: (json['source'] as String?) ?? 'metadata',
        sourceKey: json['source_key'] as String?,
        transform: (json['transform'] as String?) ?? 'none',
        descending: _asBool(json['descending']),
      );
}

class DmsIndex {
  final String slug;
  final String name;
  final String? rootDocumentType;
  final bool shared;
  final List<IndexLevel> levels;

  DmsIndex({
    required this.slug,
    required this.name,
    required this.rootDocumentType,
    required this.shared,
    required this.levels,
  });

  factory DmsIndex.fromJson(Map<String, dynamic> json) => DmsIndex(
        slug: json['slug'] as String,
        name: (json['name'] as String?) ?? json['slug'] as String,
        rootDocumentType: json['root_document_type'] as String?,
        shared: _asBool(json['shared']),
        levels: ((json['levels'] as List?) ?? const [])
            .map((e) => IndexLevel.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class IndexNode {
  final String value;
  final int count;

  IndexNode({required this.value, required this.count});

  factory IndexNode.fromJson(Map<String, dynamic> json) => IndexNode(
        value: '${json['value']}',
        count: (json['count'] as num?)?.toInt() ?? 0,
      );
}

class RetentionPolicy {
  final int id;
  final String name;
  final int? retentionYears; // null = no compliance / freely editable
  final String anchor; // document_date | date_added
  final bool isCompliance;

  RetentionPolicy({
    required this.id,
    required this.name,
    required this.retentionYears,
    required this.anchor,
    required this.isCompliance,
  });

  factory RetentionPolicy.fromJson(Map<String, dynamic> json) =>
      RetentionPolicy(
        id: (json['id'] as num).toInt(),
        name: (json['name'] as String?) ?? '',
        retentionYears: (json['retention_years'] as num?)?.toInt(),
        anchor: (json['anchor'] as String?) ?? 'document_date',
        isCompliance: _asBool(json['is_compliance']),
      );
}

class Storage {
  final int id;
  final String name;
  final String slug;
  final String backend;
  final Map<String, dynamic> config;
  final bool objectLockEnabled;
  final String? defaultLockMode;
  final bool readOnly;
  final bool isDefault;
  final bool isActive;

  Storage({
    required this.id,
    required this.name,
    required this.slug,
    required this.backend,
    required this.config,
    required this.objectLockEnabled,
    required this.defaultLockMode,
    required this.readOnly,
    required this.isDefault,
    required this.isActive,
  });

  factory Storage.fromJson(Map<String, dynamic> json) => Storage(
        id: (json['id'] as num).toInt(),
        name: (json['name'] as String?) ?? '',
        slug: (json['slug'] as String?) ?? '',
        backend: (json['backend'] as String?) ?? '',
        config: (json['config'] as Map?)?.cast<String, dynamic>() ?? {},
        objectLockEnabled: _asBool(json['object_lock_enabled']),
        defaultLockMode: (json['default_lock_mode'] as String?)?.isNotEmpty ==
                true
            ? json['default_lock_mode'] as String
            : null,
        readOnly: _asBool(json['read_only']),
        isDefault: _asBool(json['is_default']),
        isActive: json['is_active'] != false,
      );
}

/// One entry of a type's own ACL list: a group pk plus its permissions.
/// (There is no group listing API yet — spec §10 — so groups are raw ids.)
class AclEntry {
  int group;
  String? groupName;
  Set<String> permissions;

  AclEntry({required this.group, this.groupName, required this.permissions});

  factory AclEntry.fromJson(Map<String, dynamic> json) => AclEntry(
        group: (json['group'] as num?)?.toInt() ?? 0,
        groupName: json['group_name'] as String?,
        permissions: ((json['permissions'] as List?) ?? const [])
            .map((e) => '$e')
            .toSet(),
      );

  Map<String, dynamic> toJson() =>
      {'group': group, 'permissions': permissions.toList()};
}

const aclPermissions = [
  'view',
  'edit_metadata',
  'upload_version',
  'delete',
  'archive',
  'download',
  'manage_acl',
];

class CurrentUser {
  final int id;
  final String username;
  final String? email;
  final bool isSuperuser;
  final List<String> groups;

  CurrentUser({
    required this.id,
    required this.username,
    required this.email,
    required this.isSuperuser,
    required this.groups,
  });

  factory CurrentUser.fromJson(Map<String, dynamic> json) => CurrentUser(
        id: (json['id'] as num).toInt(),
        username: json['username'] as String,
        email: json['email'] as String?,
        isSuperuser: _asBool(json['is_superuser']),
        groups: ((json['groups'] as List?) ?? const [])
            .map((e) => e is Map ? '${e['name']}' : '$e')
            .toList(),
      );
}
