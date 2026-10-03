# Changelog

Notable user-facing changes, newest first. The same file ships in the app
(Settings → About & Feedback → Changelog).

## 0.7.1 (2026-10-03)

### Changed — Devices and shared libraries are now separate concepts

- **Two kinds of links.** Connecting your own devices uses a **device
  link**: your name, AI settings, your library list, and the content of
  every library you own sync across them. Sharing with someone else
  uses a **library invite**: it grants exactly one library, and they
  never see your identity or your other libraries.
- **A new library starts truly fresh.** Creating a library after a
  delete no longer resurrects a previous device's name or state — the
  earlier version kept hidden sync state that survived both the delete
  and the app update. That state is now wiped on every delete path.
- **The AI API key never syncs.** AI settings (engine, model, context
  window, search) travel across your devices; the key stays in each
  device's own Keychain and must be entered once per device.

### Fixed

- **"Create join link" now works on first open.** The P2P page used to
  silently do nothing if the sync engine hadn't finished starting; it
  now starts the engine itself and shows a status while it does.
- **Deleting the last library no longer leaves hidden sync state** that
  a later launch could resurrect.
- **The P2P page has an Advanced section** — engine state, drive key,
  connected peers, last sync time, and per-directory payload counts —
  so sync activity is visible instead of invisible.

## 0.6.0 (2026-10-02)

### Changed — Sync is now P2P (Pears), iCloud sync removed

- **LibraryCove no longer uses iCloud for syncing.** All device-to-device
  sync — your own devices and shared libraries alike — now runs over
  Pears: a peer-to-peer system where devices talk to each other directly,
  encrypted end-to-end, with no server and no iCloud round-trip.
- **Sharing is a join link.** The owner creates a link (choosing what it
  grants: editor or guest), sends it any way they like, and the recipient
  taps it to join. Each link works exactly once.
- **You control membership.** The owner's P2P screen lists every join
  link — pending, used (with the member's name), and revoked. A revoked
  link can never be used; members who already joined keep access.
- **The owner must be online when someone joins.** Joining hands the
  new member their access key directly, owner-to-member — that's what
  makes single-use links enforceable. After joining, sync works whenever
  both devices are running the app.
- **Sync happens while the app is open.** Open LibraryCove and changes
  flow both ways; the app doesn't sync in the background yet.
- **Your books didn't move.** Everything already on each device stays;
  the iCloud copy simply stops being written to.

### Fixed — Sync reliability and sharing bugs

- **Duplicate books no longer pile up.** The reset/reinstall cycle could
  re-deliver books from iCloud on every launch, compounding copies. The
  cause is gone, existing duplicates are cleaned in one tap
  (Settings → Advanced → Remove duplicate books), and cleanup is safe
  even if run on two devices.
- **The Libraries list checkmark is honest.** A library created on
  another device no longer arrives pre-checked with a stuck checkmark.
- **The old "Family member" login page is gone.** Reinstalling the app
  used to route back to it with no way forward; the welcome screen is
  now the only entry.

## 0.5.4 (2026-09-30)

### Fixed — Sync status diagnosis

- **Sync errors now name the actual failing records.** When iCloud reports
  a partial failure (some records in a batch fail while others succeed),
  the Sync row showed only a generic "The operation couldn't be completed"
  message. It now lists the failing records and the reason for each
  (validation, missing record, quota), so sync problems can be identified
  directly from the app instead of guessing.

### Fixed — Shared library joining actually works

- **First-run library naming keeps up with fast typing.** Typing your name
  quickly during onboarding could leave the library named after an early
  prefix ("Te's Library" for "Tester"); the library now always derives from
  the full name unless you edited the library field yourself.
- **Accepting a share link now completes.** Joining a shared library used to
  stop silently after the iCloud confirmation prompt: the app missed
  cold-launch invitations entirely, looked the accepted share up under a
  zone name that no longer exists, and never started syncing. The join now
  happens in the same session — no relaunch — and the shared library's
  books appear after the first sync.
- **Sharing is per library.** Each library gets its own share, and multiple
  libraries can be shared with different people at the same time. Every
  device syncs all libraries it shares; leaving one share no longer touches
  the others.
- **Members show LibraryCove names.** The people list now shows the name
  each member chose inside LibraryCove (Settings → Your Name), not their
  iCloud account name or email. Renaming yourself propagates to everyone on
  the next sync.

### Changed — Sync options

- **Removed the Dropbox, Box, and Nextcloud placeholders** from the sync
  provider picker. They were never functional; iCloud Sync and Shared
  Library remain. A peer-to-peer sync option (no accounts, no servers) is
  under research — see `docs/pears-sync-research.md`.

## 0.5.3 (2026-09-28)

### Fixed — Member name sync

- **"Your name" now stays the same on every device.** Setting up a second
  device used to create its own member row, so the name you typed there
  ("Test") could diverge from your other device ("Scott") and never
  converge. All devices now share one member identity: existing duplicate
  rows merge automatically on the next launch (newest name wins, book
  attributions follow), and second-device setup adopts your synced
  identity instead of creating a new one.

## 0.5.2 (2026-09-27)

### Added — Hardcover enrichment (optional)

- **One-tap Hardcover connect.** Connecting now opens a single Hardcover
  consent screen (OAuth) — no key to create, copy, or paste. LibraryCove
  receives short-lived access tokens that renew automatically and can be
  revoked anytime at hardcover.app → Account → Authorized Apps. Only public
  book data is read — never your Hardcover ratings, reviews, or library.
- **Enrichment via Hardcover.** Scanned and imported books gain Hardcover's
  curated genres, tags, series name & number, extra details, and another
  cover option. It fills gaps only — never overwrites what OpenLibrary or
  Google found. (Manual API-key entry remains available as a fallback.)

### Improved — OpenLibrary etiquette

- **Identified API traffic.** Requests now carry a contact email alongside
  the app name, which Open Library's guidelines reward with a higher rate
  limit (3 requests/second instead of 1).
- **Rate-limit compliance built in.** All Open Library requests are
  automatically spaced out so a burst of scans can never exceed the
  documented limit — fewer 429s, fewer "couldn't reach the catalog" items.

### Fixed — Cover quality

- **The first cover is no longer the low-resolution one.** Scan and search
  results used to offer Open Library's tiny thumbnail (~75px) as the default
  cover. Covers now arrive largest-first — the biggest image is the default
  selection — sub-100px thumbnails are never offered, and Google Books cover
  URLs are upgraded to their highest-resolution variant automatically.
  "Retrieve additional covers" still finds alternatives; you can always pick
  a different one or use a photo.

### Fixed — Scanning ISBNs

- **Scanning finds books again.** Open Library retired the ISBN lookup
  endpoint LibraryCove used (`/api/books` now answers 404), which broke every
  scan. Lookups now use the same working search index as the title search and
  still fall back to Google Books for ISBNs Open Library doesn't know. A dead
  or malformed catalog response can no longer abort a scan lookup outright.
- **Holding the phone on a barcode no longer stutters.** The green
  "ISBN detected" indication used to restart with every re-read of the same
  code; it now stays solid until you move away from the book.

## 0.5.1 (2026-09-26)

### Changed — Add a book screen

- **The Add screen has a big Scan ISBN button.** The plus menu in the top-right
  is gone; scanning — the primary way to add books — is a prominent button
  right under the search bar. The three ways to add are now labeled directly on
  the page: Search (search bar), Scan ISBN (big button), and Add manually (list
  row, whose explanatory footer was removed).

## 0.5 (2026-09-25)

### Fixed — iCloud sync reliability

This release fixes the iCloud sync failures reported after wiping devices or
deleting libraries:

- **Wiping both devices works.** "Delete everything" no longer lets pre-wipe
  libraries resurrect from the cloud. The wipe now publishes atomically
  (delete records + wipe marker in one call), a persisted flag guarantees the
  wipe publishes even if you start typing names before it lands, failures are
  logged and retried on next launch, and leftover shared-library zones (which
  held pre-wipe books) are swept from the private database.
- **Restoring a shared library works.** Deleting everything while a shared
  library was active left its zone — and every book in it — in the cloud,
  which re-downloaded and repopulated the library on the next launch. Factory
  reset now deletes those zones unconditionally.
- **Deleting the last library behaves.** No more blank Active Library name or
  phantom "Untitled Library" in the Libraries list. An empty state is
  first-class: Settings shows "No library" with a **Create Library** button,
  the top-of-page text stays blank until a library exists, the Library page
  shows a "No library" prompt with an Open Settings jump, and the welcome flow
  creates your library instead of renaming a phantom default.
- Per-record CloudKit failures (partial failures that previously surfaced as
  silent successes) are now unwrapped and logged with their error codes under
  the `com.librarycove.app` Console subsystem.

### Added — iCloud-synced backups

- **"Back up library now" backs up to iCloud.** Backup files live in the
  app's iCloud Drive container and sync to every device on the account:
  create on one, restore on the other. Deleting a backup deletes it
  everywhere.
- Existing backups migrate into the synced folder automatically (backups made
  under the retired per-provider folders are merged in on first visit).
- Restoring a backup that's still downloading from iCloud waits for the bytes
  instead of failing, with a spinner and a clear retry message if iCloud is
  unreachable.

### Changed

- **Local only is retired.** Sync choices are iCloud Sync and Shared Library.
  Backups are one synced set — the "(Local)" tags on backup rows and the
  "Restore & switch" flow are gone.
- Restored the tree to the last known-good sync behavior, then re-applied
  shared-library syncing with the fixes above: shared libraries appear on all
  your devices again, share events can no longer ping-pong across devices,
  and switching libraries preserves share state.

### Changed — shared library roles

- **Roles are enforced consistently**: **admin** (full control — edit,
  share links, manage members' roles, stop sharing), **editor** (edit
  anything and share links, but cannot stop sharing), **guest** (view only —
  no edits, no sharing). Only admins can stop sharing or assign roles
  (including new admins), changeable on the fly from the Members sheet.
- **First share asks who the link is for**: before the system share sheet,
  you pick what the link grants — Admin, Editor, or Guest. The choice
  travels with the share, so people joining from any device get that role
  automatically, and role changes made later reach every member's device on
  the next sync.
- The Libraries list long-press menu now shows role-aware controls for a
  shared library: Members, Share library (editors/admins), Stop sharing and
  Leave shared library (admins; Leave for participants).
- **Export PDF is available to every role**, including guests.

### Attribution

- Added a "Data sources" section to About & Feedback crediting Open Library
  (CC0 bibliographic data), Google Books, and Wikipedia (CC BY-SA). A
  courtesy note covers Cindy's Books, an independently developed app
  discovered near release whose work-key storage idea informed the
  deterministic description fetches above; all code is original.

## 0.4 (TestFlight)

### Changed

- The app is renamed **LibraryCove** (bundle id `com.librarycove.app`, CloudKit
  container `iCloud.com.librarycove.app`). Exports still use the same
  `library.json` format; archives written by older BookNexus builds
  (`booknexus-library` format marker) import unchanged.

### Added

- Catalog lookups now capture the Open Library **work key** and store it on the
  book (`olKey`). "Fetch description" uses it to read the description directly
  from the correct work record — deterministic, no fuzzy title/author matching —
  and description pickers prefer it for their Open Library candidate. The key
  travels with exports and shared libraries, and backfills on later lookups.
- Catalog network requests identify themselves to Open Library with a
  descriptive User-Agent per its API etiquette.
