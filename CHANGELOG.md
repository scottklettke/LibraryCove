# Changelog

Notable user-facing changes, newest first. The same file ships in the app
(Settings → About & Feedback → Changelog).

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
