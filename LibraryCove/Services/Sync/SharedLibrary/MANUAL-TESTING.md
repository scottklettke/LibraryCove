# Manual Test Guide: Shared Library (Notes-style iCloud sharing)

Automated coverage lives in `LibraryCoveTests/SharedLibraryTests.swift` (codec
round-trips, hash-index change detection, conflict policy). Everything below
needs **two real devices (or one device + one Mac-signed build) with two
different iCloud accounts** — the simulator has no iCloud account, so
`accountStatus()` never reaches `.available` and every CloudKit call no-ops.

## One-time prerequisites

1. CloudKit container `iCloud.com.librarycove.app` must exist for the signing
   team (Developer Portal → CloudKit Dashboard). The SwiftData iCloud Sync
   feature already required this.
2. The CloudKit **schema** deployment note in the owner flow below — dev
   types auto-create on the first share cycle.
3. Both devices: Settings → [name] → iCloud → signed in, iCloud Drive on.

## Owner flow

1. One-time schema step: CloudKit types auto-create in the **development**
   environment on the owner's first share cycle. Before App Store/TestFlight
   participants share, promote them in CloudKit Console (Deploy Schema
   Changes to Production).
2. Settings → **Share Library** → wait for "Preparing your shared library…".
   Expected: system share sheet opens (UICloudSharingController) preloaded
   with the library title.
3. Invite the second account (Messages or Mail link), permission
   "Can make changes".
4. Expected on relaunch: Settings shows **Manage Shared Library** +
   **Stop Sharing**, and the "People with access" list shows the owner row
   plus the invited row as "Invited". A participant removed via the system
   sheet still shows until the next Settings re-open (refresh runs then).

## Participant flow

1. Open the invitation link on the second device → app launches →
   accept the CloudKit prompt.
2. Expected: next app launch switches to the shared library (mirror store);
   the owner's books appear after the first sync (pull happens in
   `RootView`'s launch task; a placeholder user row is seeded so the login
   gate doesn't cover the shared library). The participant's own previous
   library is NOT visible while in shared mode — that's the agreed
   switch-into-it design.
3. Add a book, edit a book, delete a book on each device in turn.
   Expected: changes appear on the other device within seconds of the next
   launch (sync is launch/task-driven; no push notification is wired — see
   "Known gaps").

## Leave / stop

- Participant: Settings → **Leave Shared Library** → "Keep a Copy & Leave".
  Expected: relaunch returns to the previous provider (usually Local only)
  and the shared books appear merged into the private library (ISBN /
  title+author dedup — no duplicates).
- Owner: **Stop Sharing**. Expected: participants' apps auto-revert on their
  next sync attempt — the zone no longer exists in their shared database, so
  the engine drops membership and flips the provider back; the Settings
  error row persists until relaunch (the Shared Library section then returns
  to its unshared state). The participant's mirror file is kept as the only
  local copy of the shared content.

## Known gaps (deliberate scope)

- **Connections (book-to-book knowledge graph) don't sync.** Share-scoped
  relationships across users aren't supported by CloudKit shares; they stay
  private per library.
- **Sync cadence is launch-driven.** No silent-push subscription is wired, so
  changes land when a member opens the app, not instantly.
- **Simulator cannot join shares.** Accept flows run only on real devices.
- Deleted records' cover files: a participant that received a cover via
  CKAsset keeps a local file; if the book is deleted remotely the file is
  removed by SwiftData cascade only for the DB row — orphaned cover files
  are harmless (CoverImageStore is regenerated on demand).
