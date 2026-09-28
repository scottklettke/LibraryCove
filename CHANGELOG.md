# Changelog

Notable user-facing changes, newest first. The same file ships in the app
(Settings → About & Feedback → Changelog).

## 0.5.2 (2026-09-27)

### Added — Hardcover enrichment (optional)

- **Optional Hardcover integration.** Turn it on in Settings → Hardcover:
  paste your free API key from hardcover.app (Account → API → New API Key)
  and scanned/imported books gain Hardcover's curated genres, tags, series
  name & number, extra details, and another cover option. It fills gaps
  only — never overwrites what OpenLibrary or Google found — and reads
  exclusively public catalog data (no ratings, reviews, or anything from
  your Hardcover account). The key is stored in your device's Keychain.

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
