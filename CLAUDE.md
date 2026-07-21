# DMS Flutter Client

Flutter client for the company DMS server (Django/DRF). The contract is
`client-specification.md` + `client-api-schema.yml` — read the spec before
changing API-facing code.

## Run

```sh
flutter run -d linux          # dev server default: http://localhost:8000/api/v1
flutter test
flutter analyze
```

The server URL is entered on the login screen and persisted (with the Knox
token) in flutter_secure_storage.

## Structure

- `lib/src/api/api_client.dart` — hand-written Dio client, one method per
  endpoint; maps domain errors (`compliance_locked`, `duplicate_file`,
  `invalid_metadata`) to `ApiException`; any 401 triggers `onUnauthorized`
  (session drop → login screen).
- `lib/src/models/models.dart` — wire models, parsed tolerantly
  (`archived`/booleans may arrive as strings). `mergedMetadataFields` walks
  `parent_slug` to build the inherited metadata field set per type.
- `lib/src/state/session.dart` — Riverpod session (login/restore/logout),
  `documentTypesProvider` (fetched once per session).
- `lib/src/screens/` — login, home shell (rail ≥700px / bottom nav),
  document list (compact search field + type dropdown, type-tree drawer,
  Active/All/Archived, date range, metadata filters, infinite scroll —
  a non-empty query feeds the same card grid from `/search/` instead, and
  hides the date/metadata chips that endpoint cannot apply; headlines are
  discarded), document detail (preview pager, metadata card, versions, timeline,
  download & open, archive, extraction polling), index browser (drill nodes →
  leaf document list).
- `lib/src/widgets/timeline.dart` — the §6 vertical timeline: version anchor
  cards, grouped view/download events, collapsed ±N diff chips, hidden
  versions struck through.

## Conventions

- Monetary metadata values are decimal **strings** on the wire — never parse
  to double (use `decimal` when arithmetic is needed).
- Multipart uploads: `metadata` must be a JSON-encoded *string* form field.
- Previews come from the server (`/preview/?size=thumb|preview&page=N`),
  fetched with the token header; 404 → mime-type icon fallback. No on-device
  PDF rendering.
- Compliance mode: hide delete/replace-file actions, show the lock badge;
  archive stays available.

## Status

M1 (read/browse), M2 (write: upload with typed metadata form + camera
capture→PDF, edit, new version/replace file, duplicate dialog, §5 permission
memory in `state/permissions.dart`), M3 (desktop round-trip editing:
`state/edit_sessions.dart` downloads to a temp dir, opens externally,
watches via `watcher`, debounces 2s + double-hash stability check, then the
detail screen shows a compliance-aware banner — new version vs replace in
place) and most of M4 (version hide/unhide with reason + re-extract,
change-type, index management UI, admin area under `screens/admin/` gated on
is_superuser: types + metadata fields + ACL editor, retention policies,
storages) implemented. Still open from M4: mobile share-sheet intake,
optional offline upload queue, global audit browser.

ACL editor caveat: PUT acls body is `[{"group": <pk>, "permissions": [...]}]`
and there is no group listing API (spec §10) — groups are entered as raw ids.

Dev login: `claude` / `claude_password` on `http://localhost:8000`
(superuser). Server holds demo data: a "Roundtrip test" document (type
scratch, 2 versions) and a "By batch (edited)" index.
