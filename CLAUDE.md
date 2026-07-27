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
- `lib/src/state/notifications.dart` + `state/watches.dart` — unread inbox
  count polled every 45 s (no push channel exists) and the session-cached
  watch set with optimistic document/type toggles.
- `lib/src/screens/` — login, home shell (rail ≥700px / bottom nav),
  document list (compact search field + type dropdown, type tree as an
  inline collapsible sidebar ≥760px content width / overlay drawer below,
  Active/All/Archived, date range, metadata filters, sort control, infinite
  scroll — a non-empty query feeds the same card grid from `/search/`
  instead, and hides the date/metadata chips that endpoint cannot apply;
  headlines are discarded), document detail (in-app PDF viewer with server-image pager
  fallback, metadata card, versions, comments
  card — affordances driven by server-resolved `can_edit`/`can_delete`, composer
  shown optimistically and dropped per type on 403 — timeline, download & open,
  archive, extraction polling), index browser (drill nodes → leaf document
  list), notification inbox (unread filter, mark read / read-all,
  email-preference dialog; rows render from `payload`, tap deep-links to the
  document unless it was deleted).
- `lib/src/widgets/sort_control.dart` — the `ordering` parameter as a filter-bar
  chip (key menu) plus a direction toggle. Both defaults are sent explicitly
  (`-date_added` browsing, `-rank` searching) and swap when a query is
  entered/cleared unless the user picked a sort themselves; metadata keys
  (`metadata__<key>`) come from the selected type's merged field set. Server
  400 `invalid_ordering` falls back to the default instead of erroring out.
- `lib/src/widgets/timeline.dart` — the §6 vertical timeline: version anchor
  cards, grouped view/download events, collapsed ±N diff chips, hidden
  versions struck through, comment nodes (soft-deleted ones stay, struck
  through with "removed by" hint; `comment_*` audit rows are suppressed as
  duplicates of the nodes), `replace_diff` events (what an in-place file
  replacement changed, timestamped at re-extraction, no actor) reusing the
  same diff chips.

## Conventions

- **The UI is German.** Strings are hardcoded German in place — there is no
  ARB/gen-l10n setup and no second locale. New user-facing text goes in
  German directly. `main()` pins `Intl.defaultLocale = 'de_DE'` and
  `MaterialApp` ships `flutter_localizations` with `locale: de_DE`, so stock
  Material widgets (date picker, text-selection menu) and every `DateFormat`
  in `util/format.dart` are German too. `intl` is pinned to `^0.20.2` by
  `flutter_localizations` — do not raise it. Wire vocabulary stays English:
  enum names, audit action codes, ACL permission codes, `ordering` keys,
  metadata keys. Where such a code is shown to the user, translate it at the
  display site (`FieldTypeLabel.label`, `aclPermissionLabel`, the audit label
  maps in `widgets/timeline.dart` and `screens/notifications_screen.dart`).
  Server-produced error `detail` strings pass through untranslated.
- Monetary metadata values are decimal **strings** on the wire — never parse
  to double (use `decimal` when arithmetic is needed).
- Multipart uploads: `metadata` must be a JSON-encoded *string* form field.
- View vs. download are separate server routes with separate audit actions and
  permissions. Anything rendered *inside* the app fetches
  `…/versions/{n}/view/pdf` (needs only `view`, logged as a view, seek Ranges
  deduped server-side); only an explicit Download/open-externally action may
  call `…/download` or `…/download/pdf` (needs `download`, logged as one).
- Detail-screen preview: PDFs (and odt/docx via `…/view/pdf`) render
  in-app with pdfrx/pdfium — real text layer, select/copy. Other formats,
  and PDF fetch failures, use the server preview images
  (`/preview/?size=thumb|preview&page=N`, token header); 404 → mime-type
  icon fallback. List thumbnails always use the server previews.
- Compliance mode: hide delete/replace-file actions, show the lock badge;
  archive stays available.
- Branding: display name "LUVI Docs" (Android label, GTK/Win32 window title,
  Windows version resource, `MaterialApp.title`); the package/binary stays
  `dms_client`. Icons come from `assets/icon/` via `flutter pub run
  flutter_launcher_icons` (see the pubspec block) — Linux is wired by hand in
  `linux/runner/my_application.cc`.

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

Notifications & watches hand-off implemented: Inbox tab with polled unread
badge, watch bells on document detail + type-tree nodes (a type watch covers
the subtree), @-mention autocomplete in the comment composer (`can_view:
false` users struck through), mention tokens styled in comment bodies.
odt/docx versions can be fetched as PDF (`…/versions/{n}/download/pdf`) via
the pdf icon on list cards, the detail top bar, and version rows. Note the
spec prose calling `mime_type` detail-only is outdated: the server now sends
it on document list and search rows too (null when all versions are hidden).

Version approvals hand-off implemented: types can require release of new
versions (`approval_mode`: none/required/four_eyes, null = inherit — admin
editor resolves the effective mode client-side by walking `parent_slug`).
`Document.currentVersion` now means newest visible *released* version (the
server keeps content/preview/mime_type there while a proposal is pending);
detail screen shows an amber "awaiting release" banner + per-version badges,
optimistic release buttons (`release_version` atom; plain 403 → §5 deny,
403 `approval_required` → four-eyes, button disabled with hint, tracked in
`_fourEyesBlocked`), the timeline renders the live `proposed_diff` ("what
changes if released") on pending version nodes and `version_release` audit
rows, and replace-file warns that it resets a released version to pending
(§7). Reject = the existing hide flow. No pending-approvals queue exists
server-side (§10).

ACL editor caveat: PUT acls body is `[{"group": <pk>, "permissions": [...]}]`
and there is no group listing API (spec §10) — groups are entered as raw ids.

Dev login: `claude` / `claude_password` on `http://localhost:8000`
(superuser). Server holds demo data: a "Roundtrip test" document (type
scratch, 2 versions) and a "By batch (edited)" index.
