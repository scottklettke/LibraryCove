# Manual Test Guide: Shared Library (Notes-style iCloud sharing)

Automated coverage lives in `LibraryCoveTests/SharedLibraryTests.swift` (codec
round-trips, hash-index change detection, conflict policy) and
`PerLibraryShareTests.swift` (per-library membership state). Everything below
needs **two real devices (or one device + one Mac-signed build) with two
different iCloud accounts** — the simulator has no iCloud account, so
`accountStatus()` never reaches `.available` and every CloudKit call no-ops.

## How sharing works (current architecture)

- **Every library gets its own zone + CKShare** (`LibraryCoveSharedLibrary-<hash>`,
  one per library id). Shares are created in the owner's private DB; joiners
  reach the zone through the shared DB. All engine state is per-library
  (`sharedLibrary.<id>.*` keys); multiple libraries can be shared with
  different people simultaneously, and every sync run covers all of them.
- **Link roles**: the owner picks what the LINK grants (admin/editor/guest)
  before the system sheet opens. The choice travels in the zone's `roles`
  record because CKShare permissions cannot distinguish admin from editor
  (both are `.readWrite`). A joiner's effective role = owner's per-participant
  assignment (same record's `userRoles` map) else the link default.
- **Member names**: each member's display name is the name they chose INSIDE
  LibraryCove, published in the zone's `participants` record keyed by their
  CloudKit participant record name (`publishOwnProfile`, re-written on every
  sync so renames propagate). iCloud identity names are only the fallback
  (read-only "guest" link joiners cannot write the record).
- **Acceptance**: share links route through `ShareAcceptSceneDelegate`
  (warm: `windowScene(_:userDidAcceptCloudKitShareWith:)`; cold launch:
  `connectionOptions.cloudKitShareMetadata`). The metadata is stashed and the
  join completes in-session: accept → zone read from the accepted share's
  zone ID → mirror store hot-swap → first pull. No relaunch required.

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
2. Settings → **Share Library** → pick the link's role → wait for
   "Preparing your shared library…".
   Expected: system share sheet opens (UICloudSharingController) preloaded
   with the library title.
3. Send the link to the second account (Messages or Mail).
4. Expected on relaunch: Settings shows **Manage Shared Library** +
   **Stop Sharing**, and the "People with access" list shows the owner row
   (the owner's LibraryCove name) plus the invited row as "Invited".
5. After the second device joins: the participant row flips to "Accepted"
   and shows the participant's **LibraryCove name** (their Settings → Your
   Name value), not an email — within one sync cycle of the joiner's device.

## Participant flow

1. Open the invitation link on the second device → app launches → accept
   the CloudKit prompt.
2. Expected IN THE SAME SESSION: the app switches onto the shared library
   (mirror store) without a relaunch — `RootView`'s
   `.sharedLibraryInviteArrived` handler hot-swaps the store. The owner's
   books appear after the first sync. If the app was cold-launched by the
   link, the join completes at the first RootView appearance instead.
   The participant's own previous library stays in their registry — switch
   to it any time from Libraries.
3. Add a book, edit a book, delete a book on each device in turn.
   Expected: changes appear on the other device within seconds of the next
   launch or foreground (sync is launch/task-driven; see "Known gaps").

## Leave / stop

### In-session behavior (no relaunch needed)

Stopping a share IN THE SAME SESSION it was started (Settings → Share
Library → share sheet → Stop Sharing, without killing the app) hot-swaps
the SAME container back — `SyncStoreRegistry.makeContainer` reuses the live
container whenever the requested provider's store file is already open.
Expected: NO CloudKit error like "BUG IN CLIENT OF CLOUDKIT:
Registering a handler for a CKScheduler activity identifier that has
already been registered (com.apple.coredata.cloudkit.activity.export.…)"
and NO mirroring reset (`NSCloudKitMirroringDelegate resetAfterError`).
Books merge back into the live cloud store and the UI re-renders on it
immediately.

- The mirror file is `default-shared.store`; every library's rows inside it
  are tagged with that library's id and each library has its own hash index
  (`shared-mirror-index-<libraryID>.json`). Owner leave/stop wipes rows of
  the ended share's library only; other live shares keep syncing.
- Owner: **Stop Sharing** (admins only). Expected: the app switches back to
  iCloud (or the previous provider); the owner's books merge home (no
  duplicates); the zone is deleted — every participant's app auto-reverts
  on its next sync attempt (their zone lookup fails, membership drops, and
  the provider flips back when no other share remains).
- Participant: **Leave** (keeps a copy). Removes the participant from the
  share, merges mirror content home, clears that library's share state.

## Known gaps (deliberate scope)

- **Connections (book-to-book knowledge graph) don't sync.** Share-scoped
  relationships across users aren't supported by CloudKit shares; they stay
  private per library.
- **Sync cadence is launch/foreground-driven.** No silent-push subscription
  is wired for SHARED zones (the registry zone has one), so changes land
  when a member opens the app, not instantly.
- **Simulator cannot join shares.** Accept flows run only on real devices.
- Deleted records' cover files: a participant that received a cover via
  CKAsset keeps a local file; if the book is deleted remotely the file is
  removed by SwiftData cascade only for the DB row — orphaned cover files
  are harmless (CoverImageStore is regenerated on demand).
