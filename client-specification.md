# DMS Flutter Client — Specification & Server Handoff

You are building the **Flutter client** for an existing, working company DMS
server. The server is complete and tested; this document is your contract with
it. A machine-readable OpenAPI schema (`client-api-schema.yml`) ships alongside
this file — prefer it for exact request/response shapes; regenerate anytime
from the server repo with `uv run python manage.py spectacular --file schema.yml`.

## 1. Product context

The company replaced Paperless-ngx/Mayan with its own DMS server (Django/DRF +
Postgres + Celery). The client is the only UI — there is no server-rendered
frontend. Primary users are internal staff handling invoices, contracts,
delivery notes and receipts.

**Why Flutter was chosen:** one codebase for desktop (Linux/Windows/macOS) and
mobile (Android/iOS), with two killer workflows that a web app can't do well:

1. **Mobile capture:** photograph a receipt/document with the phone camera and
   upload it directly (server OCRs it asynchronously).
2. **Desktop round-trip editing:** download a file to a temp folder, open it in
   the system default app (e.g. LibreOffice), watch the file for changes, and
   when it changes ask the user "Upload as new version?" — showing what will
   happen (new version vs replace, depending on compliance mode).

Target platforms in priority order: **Linux desktop, Android, Windows desktop**,
then iOS/macOS.

## 2. Server basics

- Base URL: configurable at login screen (company deploys on-prem), e.g.
  `https://dms.example.com/api/v1`. Dev default `http://localhost:8000/api/v1`.
- **Auth:** POST `/auth/login` with `{"username": ..., "password": ...}` →
  `{"expiry": null, "token": "<64 hex>"}`. Send `Authorization: Token <token>`
  on every request. `POST /auth/logout` revokes the current token,
  `/auth/logoutall` revokes all. `GET /auth/me` → id, username, email,
  is_superuser, groups. Store the token in platform secure storage
  (flutter_secure_storage); never in plain prefs.
- **Errors:** DRF standard errors, plus domain errors in the form
  `{"code": "<machine_code>", "detail": "<human message>", ...extras}`.
  Codes you must handle specially:
  - `compliance_locked` (HTTP 409) — the document is under retention; the
    attempted operation (delete / replace file / change type) is forbidden.
    Show a friendly explanation, offer allowed alternatives (new version,
    archive).
  - `duplicate_file` (HTTP 409, extra `duplicate_of: [uuid, ...]`) — identical
    bytes already exist. Show the duplicates (linkified) and offer
    "Upload anyway" which retries with `force=true`.
  - `invalid_metadata` (HTTP 400, extra `field` / `unknown_keys`) — attach the
    message to the offending form field.
  - 401 → token expired/revoked → return to login. 403 → lacking ACL
    permission → hide/disable the action next time (see §5).
- **Pagination:** DRF limit/offset — `{"count": N, "next": url|null,
  "previous": url|null, "results": [...]}`. Default page size 50.
- **Dates:** all dates ISO `YYYY-MM-DD`, datetimes ISO-8601 with timezone.

## 3. Domain model (what the client must understand)

### Document types — a tree that drives everything
`GET /document-types/` returns all nodes (flat, ordered by tree path) with
`slug` (the API identifier), `name`, `parent_slug`, `depth`,
`retention_policy` (id|null), `storage` (id|null), `is_active`, and
`metadata_fields` (see below). Render as a tree (build from `parent_slug`).
Choosing a type is part of every upload; the type determines:
- **where** the file is stored (server-side concern, invisible to client),
- **whether the document is in compliance mode** (retention policy inherited
  down the tree),
- **which metadata fields** the document has.

### Metadata fields — dynamic, typed forms
Each type carries `metadata_fields`: `{key, label, field_type, required,
default, ordering, indexed}`. `field_type` ∈:

| type      | JSON wire format                  | suggested widget            |
|-----------|-----------------------------------|-----------------------------|
| text      | string                            | text field                  |
| date      | "YYYY-MM-DD" string               | date picker                 |
| integer   | JSON int                          | numeric field (no decimals) |
| float     | JSON number                       | numeric field               |
| monetary  | **string**, e.g. "1234.50"        | currency field — always send the decimal as a *string*, never a float |
| bool      | true/false                        | switch/checkbox             |
| url       | string (validated server-side)    | text field with link affordance |

Children inherit the union of ancestor field definitions (the API already
returns the merged set per type via the tree — merge ancestor `metadata_fields`
client-side when showing a child type's form: walk up `parent_slug`, child keys
override ancestor keys).

Unknown keys are rejected by the server; required fields are enforced on
create (not on PATCH).

### Documents
Fixed fields: `uuid` (the identifier in all URLs), `title`, `document_type`
(slug), `document_date`, `date_added`, `added_by`, `notes`, `metadata` (object),
`archived` (bool), `retention_until` (date|null), `in_compliance_mode` (bool),
and on detail additionally `content` (extracted full text), `mime_type`,
`versions` (array).

### Versions
`{number, original_filename, mime_type, size, checksum_sha256,
extraction_status (pending|running|done|failed), extraction_backend,
is_hidden, hidden_by, hidden_at, hidden_reason, uploaded_by, uploaded_at,
object_lock_until, page_count}`. `page_count` is filled once the server has
rendered previews (null until then; 1 for images; null for non-visual files).
- Versions are ordered by `number` (upload order). The newest **visible**
  (non-hidden) version is "the document".
- After any upload, `extraction_status` starts `pending` — poll the version
  (or document detail) every few seconds until `done`/`failed` to refresh
  content/search availability. Show a subtle "processing" indicator meanwhile.
- Hidden versions ("wrong upload") must be rendered **struck through** in the
  timeline, with hover/tap showing `hidden_reason` and who hid them. No diffs
  are shown for hidden versions.

### Compliance mode — UI rules
When `in_compliance_mode` is true:
- No delete (server 409s; ideally don't offer the button — show a lock badge
  with `retention_until` instead).
- No "replace file" on released versions — only "upload new version".
  A version awaiting release stays replaceable.
- No type change.
- Archive **is** allowed and is the "get it out of my face" action.
Metadata/title/notes edits are allowed (they're audited).

### Archive (Odoo-style)
Archived documents vanish from all default lists. List endpoints accept
`?archived=true` (include) and `?archived=only`. Give the document list a
filter toggle ("Active / All / Archived") and an archive/unarchive action on
the document.

## 4. API reference (v1)

Base: `/api/v1`. All endpoints require the token header unless noted.

```
POST /auth/login {username, password}            → {token}         (no auth)
POST /auth/logout · /auth/logoutall              → 204
GET  /auth/me

GET  /document-types/                            flat tree, ordered
GET  /document-types/{slug}/
GET|PUT /document-types/{slug}/acls/             admin/manage_acl only
GET  /retention-policies/                        {id, name, retention_years, anchor, is_compliance}

GET  /documents/                                 params: type=<slug> (includes descendants),
                                                 archived=true|only, document_date_from/to=YYYY-MM-DD,
                                                 metadata__<key>=<value>, limit, offset
POST /documents/                                 multipart: file, title, document_type=<slug>,
                                                 document_date?, notes?, metadata=<JSON string>,
                                                 force=true|false
                                                 → 201 document detail | 409 duplicate_file
GET  /documents/{uuid}/                          detail (+content, versions); logs a VIEW audit event
PATCH /documents/{uuid}/                         JSON: {title?, notes?, document_date?, metadata?{...}}
                                                 metadata is merged key-wise; null clears a key
DELETE /documents/{uuid}/                        → 204 | 409 compliance_locked | 403
POST /documents/{uuid}/archive/ · /unarchive/
POST /documents/{uuid}/change-type/              {document_type, metadata?} — 409 in compliance mode
GET  /documents/{uuid}/timeline/                 → {"events": [...]} (see §6)

GET  /documents/{uuid}/versions/
POST /documents/{uuid}/versions/                 multipart: file, force? → 201 version;
                                                 while a visible version awaits release,
                                                 replaces that version's file instead
                                                 (same number returned, no new version)
GET  /documents/{uuid}/versions/{n}/
GET  /documents/{uuid}/versions/{n}/download     bytes, Content-Disposition attachment; audited
PUT  /documents/{uuid}/versions/{n}/file         multipart: file — replace in place;
                                                 409 compliance_locked in compliance mode
                                                 (not for a version awaiting release)
POST /documents/{uuid}/versions/{n}/hide         {reason?} — cannot hide the only visible version
POST /documents/{uuid}/versions/{n}/unhide
POST /documents/{uuid}/versions/{n}/re-extract   re-runs OCR
GET  /documents/{uuid}/versions/{a}/diff/{b}     → {from_version, to_version, unified_diff,
                                                    added_lines, removed_lines, too_large, stored}

GET  /documents/{uuid}/preview/?size=thumb|preview&page=N
GET  /documents/{uuid}/versions/{n}/preview?size=thumb|preview&page=N
     → image/png. Server-rendered: PDFs and images only; other formats → 404
     (fall back to a mime-type icon). The document-level route serves the
     latest *visible* version — use it for list thumbnails; the version route
     for the detail/page viewer. sizes: thumb = 320px longest side,
     preview = 1440px. page defaults to 1; page beyond page_count → 404.
     Responses carry ETag (content-addressed — send If-None-Match, expect 304),
     Cache-Control: private, max-age=86400, and X-Page-Count. Page 1 is
     prerendered server-side right after upload/OCR; other pages render
     lazily on first request (may take ~1s — show a placeholder).

GET  /search/?q=...&type=<slug>&archived=...&limit=&offset=
     → {count, results: [{uuid, title, document_type, document_date, date_added,
                          archived, rank, headline}]}
     headline is an HTML-ish snippet with <b>...</b> around matches — render the
     bold tags, strip anything else. Query syntax is Postgres websearch:
     quoted phrases, OR, -exclusion.

GET  /indexes/                                   user-defined tree views
POST /indexes/  {name, slug, root_document_type?, shared, levels: [
                  {position, source: metadata|document_date|document_type|added_by,
                   source_key?, transform: none|year|year_month|first_letter, descending}]}
GET  /indexes/{slug}/nodes/?path=A/B&archived=   → {"nodes":[{value, count}]} while drilling,
                                                 → paginated document list at leaf depth
GET  /audit/                                     admin-only global audit browser
GET  /api/schema/                                OpenAPI (drop /api/v1 prefix: it's /api/schema/)
```

## 5. Permissions & adaptive UI

Permissions are **per document type**, per group, inherited down the type tree:
`view, edit_metadata, upload_version, delete, archive, download, manage_acl`.
The API enforces everything (403), and list endpoints only return documents the
user may view — the client never needs to filter for security. But for good UX,
degrade gracefully: on a 403 for an action, disable that action for documents
of that type for the session. (There is currently no endpoint exposing "my
effective permissions per type" — request one from the server team if you want
to pre-hide buttons; suggested shape: `GET /auth/me/permissions` →
`{type_slug: [perms]}`.)

## 6. The timeline (core UI element)

`GET /documents/{uuid}/timeline/` returns one time-sorted list mixing two event
kinds — render as a **vertical timeline** (audit trail is a compliance
feature; make it look trustworthy):

```jsonc
{"kind": "audit", "timestamp": ..., "action": "create|edit_metadata|edit_fields|
  version_upload|version_replace_file|version_hide|version_unhide|download|view|
  archive|unarchive|type_change|extraction_done|extraction_failed|acl_change",
 "actor": "alice"|null,           // null = system (e.g. OCR pipeline)
 "changes": {"field": {"old": ..., "new": ...}}|null,
 "context": {...}}                // may contain version number, ip, backend

{"kind": "version", "timestamp": ..., "number": 2, "original_filename": ...,
 "mime_type": ..., "size": ..., "uploaded_by": ..., "extraction_status": ...,
 "is_hidden": false, "hidden_by": null, "hidden_reason": null,
 "diff": {"from_version": 1, "added_lines": 2, "removed_lines": 4,
          "too_large": false, "unified_diff": "--- v1\n+++ v2\n@@ ..."}|null}
```

Rendering rules:
- Version events are the anchor nodes (bigger markers); audit events are
  smaller entries between them.
- `is_hidden: true` → strike through the whole version entry, muted color,
  no diff section, show reason.
- `diff` (when present) collapsed by default: show "+2 −4" chips; expanding
  shows the unified diff with syntax coloring (green +/red −). `too_large` →
  "diff not available (file too large)".
- `changes` on edit events → render old → new per field.
- De-emphasize `view`/`download` events (or group repeats: "viewed 5× today").

## 7. Feature set by milestone

**M1 — Read/browse (all platforms):**
login + server URL screen, document list with filters (type tree drawer,
archived toggle, date range, metadata filters), search screen (debounced,
headline snippets), document detail (metadata card, versions, timeline),
download/open file, index tree browsing.

**M2 — Write:**
upload flow (file picker; on mobile additionally **camera capture** —
multi-page: capture N photos, client combines to a single PDF, e.g. via the
`pdf` package, before upload; consider edge detection/crop with something like
`cunning_document_scanner`), typed metadata form generated from the type's
field definitions, edit metadata/title/notes, new version upload, archive,
duplicate-conflict dialog, compliance-aware action visibility.

**M3 — Desktop round-trip editing:**
"Open & edit" on a version: download to a temp dir, launch the OS default
application, watch the file (package `watcher`); on change show a diff-aware
prompt: non-compliance docs → "Replace file in version N or add version N+1?",
compliance docs → "Upload as version N+1" only. While a version awaits
release, the only choice is "Replace file in version P" (the pending one).
After upload, poll extraction
and show the new server-side text diff from the timeline. Handle the app
still holding the file open (debounce; re-check checksum stability before
prompting).

**M4 — Polish:**
version hide/unhide with reason dialog, re-extract action, index management UI,
admin screens (document types, metadata fields, retention policies, storages,
ACL editor) gated on `is_superuser`, share-sheet integration on mobile
("share PDF to DMS"), optional offline upload queue.

## 8. Technical recommendations (non-binding)

- Generate the API layer from `client-api-schema.yml` (openapi-generator dart-dio
  or similar); wrap it in a repository layer — the schema's generic fallbacks
  for a few endpoints (login, search) may need hand-written models, they are
  small and fully documented above.
- Uploads are multipart; `metadata` must be a JSON-*string* form field.
- Poll-based freshness is fine (the server has no websockets); poll extraction
  status with backoff, refresh lists on focus.
- Monetary values: use a Decimal type client-side (package `decimal`); never
  parse to double.
- Use the server-rendered preview endpoint (§4) for list thumbnails and the
  page-by-page document viewer (swipe through pages by incrementing `page` up
  to `page_count`) — no on-device PDF rendering needed. Cache by ETag. For
  formats with no preview (404), show a mime-type icon and offer
  download/open externally.

## 9. Running the server for development

From the server repo (`DMS_server`):

```sh
docker compose up          # Postgres, Redis, MinIO, API on :8000, worker, beat
docker compose exec app python manage.py createsuperuser
```

or natively: `uv sync && uv run python manage.py migrate && uv run python
manage.py runserver` plus `uv run celery -A config worker -Q default,ocr`.
Swagger UI at `http://localhost:8000/api/docs/`. First-run setup (as admin, via
API or Django admin at `/admin/`): create a Storage (filesystem is fine), mark
it default, create retention policies and a document-type tree, add metadata
fields, create groups + users, and PUT ACLs on the type roots.

## 10. Known server-side gaps (coordinate, don't work around)

- No user/group management API (Django admin only for now).
- No "effective permissions for me" endpoint (see §5).
- Push is one-way and fire-and-forget: `GET /events/` (Server-Sent Events)
  sends `document_changed` `{"document": uuid, "action": audit code}` for
  every change to a document the caller may view (not for view/download),
  with a `: keepalive` comment every 20 s. No history: after a reconnect,
  reload what is on screen. Inbox state is not pushed — keep polling it.
- Editing notice (no lock): PUT `/documents/{uuid}/editing/` while editing,
  repeated at least every 30 s, DELETE when done. The feed relays it as
  `document_editing` `{"document", "user", "editing", "expires_in"}`; drop
  an editor not repeated within `expires_in` (60 s).
