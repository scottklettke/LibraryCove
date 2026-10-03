import Foundation
import SwiftData
import os.log
import CloudKit
import CoreData
import UIKit

/// Diagnostics for multi-library issues (fetch/insert mismatches on device).
private let libraryLog = Logger(subsystem: "com.librarycove.app", category: "LibraryScope")

/// A user-created library: a named collection of books. The LIST of
/// libraries is stored as JSON (Application Support/libraries.json) rather
/// than SwiftData/CloudKit: the Library entity's rows failed to persist
/// reliably through the CloudKit schema on some devices (created rows
/// vanished across launches), while content isolation only needs the id —
/// which lives on the rows themselves.
struct LibraryInfo: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var isActive: Bool
    var createdAt: Date
    /// Last local rename, for CloudKit registry last-writer-wins. Optional
    /// so pre-mirror JSON decodes; treated as `createdAt` when nil.
    var modifiedAt: Date?
    /// Share facts adopted from the registry mirror (nil = not shared).
    /// The OWNER device writes these after creating/stopping a share; other
    /// devices fold them in, so Settings renders the shared-library section
    /// consistently across the same iCloud account's devices.
    var share: LibraryRegistryDTO.ShareFacts?
    /// The owner's stop-sharing event time (see LibraryRegistryDTO).
    var shareClearedAt: Date?
}

/// One registry entry, mirrored to the user's private CloudKit database so
/// library names and the library list stay consistent across the owner's
/// devices. `isActive` rides along only so a wiped-then-recreated device
/// can adopt the other device's post-wipe library — which library is open
/// stays a per-device choice (see the field note below).
struct LibraryRegistryDTO: Codable, Equatable {
    var id: String
    var name: String
    var createdAt: Date
    /// The writer's local rename stamp, preferred over the CKRecord's
    /// server modificationDate (a re-push of unchanged data gets a fresh
    /// server stamp that must not outrank a real rename). Optional so
    /// records mirrored before this field existed still decode.
    var modifiedAt: Date? = nil
    /// Which library the WRITER had open. Optional for records mirrored
    /// before this field existed. Mirrored so a wiped-then-recreated
    /// device adopts the other device's post-wipe library as active
    /// instead of showing "Untitled Library".
    var isActive: Bool? = nil
    /// Share facts written by the device that OWNS the share. Mirrored so
    /// the user's other devices learn a library became shared (Settings
    /// renders the management section instead of "Share Library") — and
    /// that sharing stopped. Nil = not shared. Ordered by `stampedAt`
    /// (below), NOT the entry's modifiedAt: renames move that stamp, share
    /// events must not be ordered by them.
    var share: ShareFacts? = nil
    /// The owner's stop-sharing event time. Set (with `share == nil`)
    /// when sharing stops; peers preserve it. Ordering share events needs
    /// this separate clock: a peer's rename re-publishes an old `share`
    /// block, and the entry's modifiedAt cannot tell that publish from
    /// the owner's later stop.
    var shareClearedAt: Date? = nil

    struct ShareFacts: Codable, Equatable {
        /// The owner's shared zone: `LibraryCoveSharedLibrary-<hash>`.
        var zoneName: String
        var zoneOwnerName: String
        /// The CKShare record's name in the owner's private DB.
        var shareRecordName: String
        /// When the owner published these facts. Peers adopt the block
        /// VERBATIM (clock included) and never re-stamp it — so a peer's
        /// later rename can never out-rank the owner's stop event.
        var stampedAt: Date
    }
}

/// Central multi-library plumbing. Observable so views re-render when the
/// active library changes (switch/rename/create/delete).
@MainActor
final class LibraryScope: ObservableObject {
    static let shared = LibraryScope()

    /// Posted after any local registry change (create/activate/rename/
    /// delete) and after a CloudKit pull folds remote registry changes in.
    /// Views observe it to refresh the active-library name.
    static let librariesChangedNotification = Notification.Name("librariesChanged")

    /// The id used for rows created before multi-library support existed
    /// (they migrate into the first/default library, which keeps this id).
    static let defaultLibraryID = "library-default"

    /// The member identity's deterministic id. Every device on the iCloud
    /// account shares ONE member row: onboarding adopts a synced row with
    /// this id instead of minting a UUID — that's what keeps "Your name"
    /// identical across devices (the old UUID-per-onboarding scheme let a
    /// second device create its own row, whose locally-typed name then
    /// diverged from the first device's and never converged).
    static let primaryMemberID = "member-primary"

    /// The ACTIVE library's id — @Published so observing views (library
    /// grid, settings) re-render the moment it changes.
    @Published private(set) var activeID: String = defaultLibraryID

    private let registryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("libraries.json")
    }()

    /// Test seam: the registry file location (tests delete it between runs).
    var registryURLForTesting: URL { registryURL }

    /// Persisted server change token for the registry zone (per-device,
    /// UserDefaults). Non-nil = next pull is a delta fetch; cleared on any
    /// failure so the next pull falls back to a full enumeration.
    private static let registryChangeTokenKey = "LibraryCoveRegistryChangeToken"

    private static func loadRegistryChangeToken() -> Data? {
        UserDefaults.standard.data(forKey: registryChangeTokenKey)
    }

    private static func saveRegistryChangeToken(_ token: Data?) {
        guard let token else {
            UserDefaults.standard.removeObject(forKey: registryChangeTokenKey)
            return
        }
        UserDefaults.standard.set(token, forKey: registryChangeTokenKey)
    }

    /// Set by `deleteAllLibraries()`, cleared ONLY when the wipe publish
    /// (meta record with wipedAt + stale record deletes) is CONFIRMED
    /// server-side. Keyed off a re-read snapshot alone is racy: any
    /// `saveRegistry` between the wipe and the push's re-read (e.g. the
    /// welcome flow naming the new default) makes the registry non-empty,
    /// silently skips the wipe branch, and leaves every pre-wipe record
    /// in the zone for the next full pull to adopt wholesale.
    private static let registryWipePendingKey = "LibraryCoveRegistryWipePending"
    private static var wipePending: Bool {
        get { UserDefaults.standard.bool(forKey: registryWipePendingKey) }
        set { UserDefaults.standard.set(newValue, forKey: registryWipePendingKey) }
    }

    /// Test seam: read-only view of the active library id for fold tests.
    var activeIDForTesting: String { activeID }

    private init() {
        activeID = loadRegistry().first(where: { $0.isActive })?.id ?? Self.defaultLibraryID
        // Long-running sessions miss launch-time pulls: renames made on
        // another device land only when this device foregrounds. Cheap,
        // guarded by the in-flight flag; no account → silent no-op.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pullRegistryFromCloud()
                // A push that failed while offline republishes here (queued
                // behind the pull, which folds any remote state first).
                self?.pushRegistryToCloud()
            }
        }
        // The willEnterForeground observer misses an app that stays open:
        // subscribe to activity transitions too so switching back to an
        // already-running iPad app picks up remote renames.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pullRegistryFromCloud()
            }
        }
        // Catch-all poll: registry-only changes produce no content import.
        // (Registry sync is now local-only — pullRegistryFromCloud is a
        // no-op — but the timer keeps the no-op cheap and harmless.)
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pullRegistryFromCloud()
            }
        }
    }

    /// All libraries, oldest first.
    func all(context: ModelContext) -> [LibraryInfo] {
        let result = loadRegistry()
        libraryLog.debug("LibraryScope.all -> \(result.count) libraries")
        return result
    }

    /// The active library, or nil when NO library exists (the user deleted
    /// every one). Does NOT synthesize a default — Settings and the Library
    /// page surface the no-library state instead. A dangling activeID
    /// against a non-empty registry (deleted library was active) promotes
    /// the oldest remaining entry, like the pre-refactor behavior.
    func active(context: ModelContext) -> LibraryInfo? {
        let registry = all(context: context)
        if let active = registry.first(where: { $0.id == activeID }) {
            return active
        }
        guard let oldest = registry.first else { return nil }
        activate(oldest, context: context)
        return oldest
    }

    /// The active library's id, or nil when no library exists.
    func activeID(context: ModelContext) -> String? {
        active(context: context)?.id
    }

    /// The active library's display name, or nil when NO library exists
    /// (callers render the no-library state). Unnamed active library keeps
    /// the classic "<member>'s Library" fallback.
    func activeName(context: ModelContext, memberName: String) -> String? {
        guard let library = active(context: context) else { return nil }
        return library.name.isEmpty
            ? SharedLibrarySettings.defaultShareTitle(for: memberName)
            : library.name
    }

    /// Marks `library` as the only active one.
    func activate(_ library: LibraryInfo, context: ModelContext) {
        var registry = loadRegistry().map { info in
            LibraryInfo(id: info.id, name: info.name,
                        isActive: info.id == library.id, createdAt: info.createdAt,
                        modifiedAt: info.modifiedAt, share: info.share,
                        shareClearedAt: info.shareClearedAt)
        }
        if !registry.contains(where: { $0.id == library.id }) {
            registry.append(library)
        }
        saveRegistry(registry)
        activeID = library.id
        notifyChanged()
    }

    /// Creates a library (and makes it active when requested).
    /// - Throws: the underlying save error, so UI can surface it.
    @discardableResult
    func create(name: String, makeActive: Bool, context: ModelContext) throws -> LibraryInfo {
        let library = LibraryInfo(id: UUID().uuidString, name: name,
                                  isActive: false, createdAt: Date(),
                                  modifiedAt: Date())
        var registry = all(context: context)
        registry.append(library)
        if makeActive {
            for i in registry.indices { registry[i].isActive = registry[i].id == library.id }
        }
        do {
            try saveRegistry(registry)
            libraryLog.notice("LibraryScope.create saved")
        } catch {
            libraryLog.error("LibraryScope.create save FAILED")
            throw error
        }
        if makeActive {
            activeID = library.id
        }
        pushRegistryToCloud()
        notifyChanged()
        return library
    }

    /// Deletes a library and ALL of its content. Members (User rows) are
    /// shared across libraries and are NOT touched. If the deleted library
    /// was active, the oldest remaining library becomes active.
    func delete(_ library: LibraryInfo, context: ModelContext) {
        let id = library.id
        let wasActive = id == activeID

        saveRegistry(all(context: context).filter { $0.id != id })

        for row in (try? context.fetch(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == id }
        ))) ?? [] { context.delete(row) }
        for row in (try? context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.libraryID == id }
        ))) ?? [] { context.delete(row) }
        for row in (try? context.fetch(FetchDescriptor<ReadingList>(
            predicate: #Predicate { $0.libraryID == id }
        ))) ?? [] { context.delete(row) }
        for row in (try? context.fetch(FetchDescriptor<ReadingListItem>(
            predicate: #Predicate { $0.libraryID == id }
        ))) ?? [] { context.delete(row) }
        for row in (try? context.fetch(FetchDescriptor<Connection>(
            predicate: #Predicate { $0.libraryID == id }
        ))) ?? [] { context.delete(row) }
        try? context.save()

        if wasActive {
            if let next = all(context: context).first {
                // Promote the oldest remaining library; a dangling activeID
                // would leave no entry marked active.
                activeID = next.id
                var registry = loadRegistry()
                for i in registry.indices { registry[i].isActive = registry[i].id == next.id }
                saveRegistry(registry)
            } else {
                // No default synthesis: when the LAST library goes, the
                // device is genuinely library-less (Settings offers Create
                // Library, the Library page shows the no-library state).
                // A silently recreated "Untitled" default is the bug this
                // replaces. Reset activeID so every active(...) lookup is
                // nil-safe until the user creates a library.
                activeID = Self.defaultLibraryID
            }
        }
        deleteRegistryRecord(id: id)
        pushRegistryToCloud()
        notifyChanged()
    }

    /// Launch migration: promotes the oldest library when the active one
    /// is gone, and tags every legacy row (libraryID == nil) into the
    /// default library when one exists. An empty registry stays empty —
    /// the no-library state — UNLESS legacy content rows exist (an
    /// upgrade from a pre-multi-library install, or UI-test seeds): those
    /// get a default library so the rows are tagged and visible. Idempotent.
    func migrateIfNeeded(context: ModelContext) {
        var registry = loadRegistry()
        if registry.isEmpty {
            // Legacy upgrade / UI-test seeds: content rows exist with no
            // registry — synthesize the default so tagLegacyRows has a
            // target and the rows stay visible. A truly empty store
            // (post-wipe, post-last-delete) keeps the no-library state.
            let hasLegacyRows =
                ((try? context.fetchCount(FetchDescriptor<Book>())) ?? 0) > 0
                || ((try? context.fetchCount(FetchDescriptor<Note>())) ?? 0) > 0
                || ((try? context.fetchCount(FetchDescriptor<ReadingList>())) ?? 0) > 0
                || ((try? context.fetchCount(FetchDescriptor<ReadingListItem>())) ?? 0) > 0
                || ((try? context.fetchCount(FetchDescriptor<Connection>())) ?? 0) > 0
            guard hasLegacyRows else {
                activeID = Self.defaultLibraryID
                return
            }
            registry = [LibraryInfo(id: Self.defaultLibraryID, name: "",
                                    isActive: true,
                                    createdAt: Date(timeIntervalSinceReferenceDate: 0),
                                    modifiedAt: nil)]
            saveRegistry(registry)
        }
        if let active = registry.first(where: { $0.isActive }) {
            activeID = active.id
        } else if let oldest = registry.first {
            for i in registry.indices { registry[i].isActive = registry[i].id == oldest.id }
            saveRegistry(registry)
            activeID = oldest.id
        }
        if let defaultLibrary = registry.first(where: { $0.id == Self.defaultLibraryID }) {
            tagLegacyRows(context: context, libraryID: defaultLibrary.id)
        }
    }

    /// Remove every library (Delete everything) — content rows are cleared
    /// separately by the caller.
    func deleteAllLibraries() {
        // Drop the registry file entirely: a stale in-memory snapshot would
        // re-publish pre-wipe libraries on the next push. The wipe itself
        // propagates via the meta record (wipedAt) that the empty-snapshot
        // push writes.
        try? FileManager.default.removeItem(at: registryURL)
        // The wipe invalidates every server record the token delta-tracks:
        // keeping the token would make the next pull a DELTA against
        // pre-wipe state, replaying stale changes over the freshly created
        // post-wipe default (renames vanished after "Delete everything").
        Self.saveRegistryChangeToken(nil)
        // Survives app restarts: the wipe publish must run (and be
        // CONFIRMED) even if the local registry is re-populated first.
        Self.wipePending = true
        activeID = Self.defaultLibraryID
        pushRegistryToCloud()
        notifyChanged()
    }

    /// Re-ids a library entry (used when a joined share maps to a derived
    /// share-scoped id). Content rows must be re-tagged by the caller.
    func renameIDForSharing(from oldID: String, to newID: String, context: ModelContext) {
        var registry = loadRegistry()
        guard let idx = registry.firstIndex(where: { $0.id == oldID }) else { return }
        registry[idx].id = newID
        saveRegistry(registry)
        if activeID == oldID { activeID = newID }
        for row in (try? context.fetch(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == oldID }
        ))) ?? [] { row.libraryID = newID }
        for row in (try? context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.libraryID == oldID }
        ))) ?? [] { row.libraryID = newID }
        for row in (try? context.fetch(FetchDescriptor<ReadingList>(
            predicate: #Predicate { $0.libraryID == oldID }
        ))) ?? [] { row.libraryID = newID }
        for row in (try? context.fetch(FetchDescriptor<ReadingListItem>(
            predicate: #Predicate { $0.libraryID == oldID }
        ))) ?? [] { row.libraryID = newID }
        for row in (try? context.fetch(FetchDescriptor<Connection>(
            predicate: #Predicate { $0.libraryID == oldID }
        ))) ?? [] { row.libraryID = newID }
        try? context.save()
        // The old record key is stale after the re-id: remove it remotely so
        // another device's pull does not re-add the old id as an unknown
        // library, then publish the re-id'd registry.
        deleteRegistryRecord(id: oldID)
        pushRegistryToCloud()
        notifyChanged()
    }

    /// Renames a library (by id). No-op when absent.
    func rename(id: String, to name: String, context: ModelContext) {
        var registry = loadRegistry()
        guard let idx = registry.firstIndex(where: { $0.id == id }) else { return }
        registry[idx].name = name
        registry[idx].modifiedAt = Date()
        saveRegistry(registry)
        pushRegistryToCloud()
        notifyChanged()
    }

    /// Publishes (or clears, with `nil`) a library's share facts into the
    /// registry and pushes. Called by the device that OWNS the share after
    /// creating or stopping it — the account's other devices fold the facts
    /// in on their next registry pull and render the shared-library UI
    /// accordingly. Stamps the SHARE EVENT's own clock (`stampedAt` /
    /// `shareClearedAt`), never the entry's modifiedAt: peers re-publish
    /// these blocks verbatim, and their renames must never out-rank the
    /// owner's later stop event.
    func setShareFacts(_ facts: LibraryRegistryDTO.ShareFacts?, libraryID: String) {
        var registry = loadRegistry()
        guard let idx = registry.firstIndex(where: { $0.id == libraryID }) else { return }
        if let facts {
            guard registry[idx].share?.stampedAt != facts.stampedAt
                || registry[idx].share != facts else { return }
            registry[idx].share = facts
            registry[idx].shareClearedAt = nil
        } else {
            let now = Date()
            guard registry[idx].share != nil || registry[idx].shareClearedAt != now else { return }
            registry[idx].share = nil
            registry[idx].shareClearedAt = now
        }
        saveRegistry(registry)
        pushRegistryToCloud()
        notifyChanged()
    }

    /// The registry's share facts for a library (nil = not shared).
    func shareFacts(libraryID: String) -> LibraryRegistryDTO.ShareFacts? {
        loadRegistry().first(where: { $0.id == libraryID })?.share
    }

    /// A fetch descriptor for the ACTIVE library's books (helper for view
    /// layer call sites).
    func activeBooksDescriptor(context: ModelContext) -> FetchDescriptor<Book> {
        let id = activeID(context: context)
        return FetchDescriptor<Book>(predicate: #Predicate { $0.libraryID == id })
    }

    private func ensureDefault(context: ModelContext) -> LibraryInfo? {
        var registry = loadRegistry()
        if let existing = registry.first {
            if !registry.contains(where: { $0.isActive }) {
                for i in registry.indices { registry[i].isActive = registry[i].id == existing.id }
                saveRegistry(registry)
            }
            activeID = existing.id
            return existing
        }
        let library = LibraryInfo(id: Self.defaultLibraryID, name: "",
                                  isActive: true, createdAt: Date(timeIntervalSinceReferenceDate: 0),
                                  modifiedAt: nil)
        registry.append(library)
        saveRegistry(registry)
        activeID = library.id
        return library
    }

    private func tagLegacyRows(context: ModelContext, libraryID: String) {
        var changed = false
        for row in (try? context.fetch(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == nil }
        ))) ?? [] { row.libraryID = libraryID; changed = true }
        for row in (try? context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.libraryID == nil }
        ))) ?? [] { row.libraryID = libraryID; changed = true }
        for row in (try? context.fetch(FetchDescriptor<ReadingList>(
            predicate: #Predicate { $0.libraryID == nil }
        ))) ?? [] { row.libraryID = libraryID; changed = true }
        for row in (try? context.fetch(FetchDescriptor<ReadingListItem>(
            predicate: #Predicate { $0.libraryID == nil }
        ))) ?? [] { row.libraryID = libraryID; changed = true }
        for row in (try? context.fetch(FetchDescriptor<Connection>(
            predicate: #Predicate { $0.libraryID == nil }
        ))) ?? [] { row.libraryID = libraryID; changed = true }
        if changed { try? context.save() }
    }
    // MARK: - Registry CloudKit mirror

    private static let registryZoneName = "LibraryCoveRegistry"
    private static let registryRecordType = "LibraryRegistry"
    /// Full-set wipe marker (delete-everything). Its `wipedAt` tells pulls
    /// which local entries predate the wipe and must be removed.
    private static let registryMetaRecordName = "library-meta"
    /// Fixed id for the silent zone subscription that wakes this device
    /// when the registry mirror changes remotely (APNs → didReceiveRemote
    /// Notification → pull).
    private static let registrySubscriptionID = "LibraryCoveRegistryChanges"

    /// Serialized mirror traffic: overlapping ops coalesce. A pending full
    /// push replays once; pending record deletes replay before it so a
    /// trailing push cannot resurrect what the deletes removed. Pulls
    /// arriving mid-op queue the same way instead of being dropped.
    private var registrySyncInFlight = false
    private var registrySyncPending = false
    private var registryPendingDeletes: [String] = []
    private var registryPullPending = false

    /// Pushes every library as one CKRecord into the private DB (record
    /// name = library id, own zone, so devices converge on the same
    /// records and a factory reset can drop the zone in one call).
    func pushRegistryToCloud() {
        // RETIRED (no iCloud): the local registry file is the registry.
        notifyChanged()
    }

    /// Pulls the mirror and folds it into the local registry. Per-library
    /// last-writer-wins on NAME; libraries known only remotely are
    /// appended (their synced content rows already exist here with
    /// matching `libraryID` stamps). Local-only libraries survive — not
    /// pushed yet, or the other device has not pulled; the next push
    /// publishes them.
    func pullRegistryFromCloud() {
        guard !registrySyncInFlight else {
            // Queue instead of dropping: a pull arriving while another op
            // is in flight replays when it drains.
            registryPullPending = true
            return
        }
        registrySyncInFlight = true
        Task { @MainActor in
            defer {
                registrySyncInFlight = false
                drainPendingRegistryWork()
            }
            if await pullAndFoldRegistry() {
                notifyChanged()
            }
        }
    }

    private func pullAndFoldRegistry() async -> Bool {
        // RETIRED (no iCloud): nothing remote to fold.
        return false
    }

    /// Idempotently (re)registers a silent CloudKit subscription on the
    /// registry zone so a rename/create on one device wakes the other via
    /// APNs. Fixed subscription id — saving is an upsert; without a
    /// subscription the remote-notification delivery path never engages.

    /// Removes ONE library's mirror record (deletion propagation). Without
    /// this, a deleted library's record would linger in the zone and the
    /// other device's next pull would re-append it. Ordered BEFORE any
    /// coalesced re-push: a full push that ran first would resurrect the
    /// record this delete is meant to remove.
    func deleteRegistryRecord(id: String) {
        // RETIRED (no iCloud).
    }

    /// Runs coalesced work after an in-flight mirror op finishes: queued
    /// record deletes first (so a trailing full push doesn't resurrect
    /// them), then a pending full push, then a queued pull.
    private func drainPendingRegistryWork() {
        if !registryPendingDeletes.isEmpty {
            let ids = registryPendingDeletes
            registryPendingDeletes.removeAll()
            for id in ids {
                deleteRegistryRecord(id: id)
            }
            return
        }
        if registrySyncPending {
            registrySyncPending = false
            pushRegistryToCloud()
        }
        if registryPullPending {
            registryPullPending = false
            pullRegistryFromCloud()
        }
    }

    /// Merge rules, offline-testable:
    ///   - `wipedAt` set (delete-everything on another device): remove every
    ///     local entry whose last modification predates the wipe; entries
    ///     created/renamed AFTER it survive (they are post-wipe state).
    ///   - remote entry, unknown id → append as inactive (active flag is
    ///     per-device).
    ///   - remote entry, same id + strictly newer mod date + different name →
    ///     take remote name (last-writer-wins).
    ///   - LOCAL entry with no remote counterpart → REMOVE, but only when
    ///     the remote set is actually populated (or a wipe was seen): a
    ///     transient empty query must not nuke local libraries.
    ///   - `deletions`: record names (library ids) that were deleted
    ///     remotely since the last fetch — applied on delta fetches, where
    ///     absence-removal against a partial remote set would nuke
    ///     everything else.
    ///   - `fullSnapshot`: false when the fetch was a token-based DELTA.
    ///     The wholesale-adoption, absence-removal, and default-recreation
    ///     steps assume the remote set is complete; on a delta only
    ///     wipe-cutoff, deletions, and the LWW rename/append pass run.
    /// Returns whether anything changed.
    @discardableResult
    func foldRemoteRegistry(_ remote: [(dto: LibraryRegistryDTO, modDate: Date)],
                            wipedAt: Date? = nil,
                            deletions: [String] = [],
                            fullSnapshot: Bool = true) -> Bool {
        var registry = loadRegistry()
        var changed = false

        // Apply remote deletions FIRST so a library deleted elsewhere is
        // gone before any other step can rename or promote it.
        if !deletions.isEmpty {
            let before = registry.count
            registry.removeAll { deletions.contains($0.id) }
            if registry.count != before {
                changed = true
            }
        }

        // Remote entries eligible to fold in. Never an EMPTY name: a stale
        // wiped device re-pushing "" must not clobber a remote rename or
        // resurrect itself. Never pre-wipe state: an entry stamped before
        // the wipe marker must not rename or re-append into a post-wipe
        // registry. The DTO's own modifiedAt (the writer's local stamp)
        // beats the record's server modificationDate: a re-push of
        // unchanged data gets a fresh server stamp that must not outrank a
        // real rename.
        let eligible = remote.filter { entry in
            !entry.dto.name.isEmpty
                && (entry.dto.modifiedAt ?? entry.modDate) >= (wipedAt ?? .distantPast)
        }

        // 0. Fresh local registry (never synced, or recreated after a
        // wipe): adopt the eligible remote state wholesale — entries,
        // names, and the writer's active library — instead of layering
        // remote entries on top of a synthetic empty default (which would
        // sit "Untitled" and could itself push over the remote rename).
        // FULL fetches only: a delta by definition carries a subset.
        if fullSnapshot, registry.isEmpty, !eligible.isEmpty {
            registry = eligible.map { dto, _ in
                LibraryInfo(id: dto.id, name: dto.name,
                            isActive: dto.isActive ?? false,
                            createdAt: dto.createdAt,
                            modifiedAt: dto.modifiedAt,
                            share: dto.share,
                            shareClearedAt: dto.shareClearedAt)
            }
            // The writer's snapshot should carry one active, but a second
            // writer's stale flag could sneak in — enforce the invariant.
            var kept = false
            for i in registry.indices where registry[i].isActive {
                if kept { registry[i].isActive = false } else { kept = true }
            }
            if !registry.contains(where: { $0.isActive }), let _ = registry.first {
                registry[0].isActive = true
            }
            if let active = registry.first(where: { $0.isActive }) {
                activeID = active.id
            }
            saveRegistry(registry)
            return true
        }

        // 1. Wipe cutoff: everything modified before the wipe is gone.
        if let wipedAt {
            let before = registry.count
            registry.removeAll { ($0.modifiedAt ?? $0.createdAt) < wipedAt }
            if registry.count != before {
                changed = true
            }
        }

        // 2. Remote-absence removal: a populated remote set is
        // authoritative — entries it lacks were deleted remotely. With a
        // wipe but an EMPTY remote set, skip: the wipe cutoff above already
        // did the removals, and locally-created post-wipe entries have not
        // been pushed yet (they must survive). FULL fetches only: a delta
        // carries only what changed, so absence there means nothing.
        if fullSnapshot, !remote.isEmpty {
            let before = registry.count
            let remoteIDs = Set(remote.map { $0.dto.id })
            registry.removeAll { !remoteIDs.contains($0.id) }
            if registry.count != before {
                changed = true
            }
        }

        // 3. (removed) The fold no longer invents a default when the
        // merged registry is empty: empty is the genuine no-library state
        // after a wipe or last-library delete, and the user creates a
        // library from the UI. FULL fetches only historically — a delta
        // must never invent entries anyway.

        // 3b. (moved below step 4) The no-active promotion runs AFTER the
        // fold's append pass: a sole appended remote library would
        // otherwise sit inactive in an emptied registry until the next
        // fold.

        // 4. Fold eligible remote entries: rename on strictly newer stamp,
        // append on unknown ids. An empty LOCAL name is a recreated default
        // that was never named by the user — any real remote name is
        // authoritative for it regardless of stamp order (the recreated
        // default's Date() stamp is newer than the other device's rename).
        // Mirror the writer's active choice only from strictly newer
        // records so an old one cannot flip the local user's current
        // library.
        for entry in eligible {
            let dto = entry.dto
            let remoteStamp = dto.modifiedAt ?? entry.modDate
            if let idx = registry.firstIndex(where: { $0.id == dto.id }) {
                let localStamp = registry[idx].modifiedAt ?? registry[idx].createdAt
                let remoteNewer = remoteStamp > localStamp
                if (remoteNewer || registry[idx].name.isEmpty),
                   registry[idx].name != dto.name {
                    registry[idx].name = dto.name
                    registry[idx].modifiedAt = max(localStamp, remoteStamp)
                    changed = true
                }
                // NOTE: no isActive adoption here. Activeness is device-
                // local (activeID); the DTO flag records which library the
                // WRITER had open and is consumed only by step 0 (fresh
                // adopt). Adopting it on existing entries let a remote
                // device's switch demote this device's active library —
                // the checkmark then sat on the wrong row and the tap
                // guard (isActive) swallowed taps to fix it.
                // Share events are ordered by their OWN clock, never the
                // entry's modifiedAt (renames move that; share events must
                // not be ordered by them). A remote SHARE block adopts when
                // its stampedAt beats the local share clock; a remote
                // CLEAR (nil share) adopts when its shareClearedAt beats
                // the local share clock. Peers adopt the owner's block
                // VERBATIM — clocks included — so a peer re-publishing
                // after a rename can never out-rank the owner's later
                // stop event. Local share clock = stampedAt of the held
                // facts, else shareClearedAt, else none.
                let localShareClock = registry[idx].share?.stampedAt
                    ?? registry[idx].shareClearedAt
                if let remoteFacts = dto.share {
                    let remoteShareClock = remoteFacts.stampedAt
                    if remoteShareClock > (localShareClock ?? .distantPast),
                       registry[idx].share != remoteFacts {
                        registry[idx].share = remoteFacts
                        registry[idx].shareClearedAt = nil
                        changed = true
                    }
                } else if let clearedAt = dto.shareClearedAt,
                          clearedAt > (localShareClock ?? .distantPast) {
                    if registry[idx].share != nil || registry[idx].shareClearedAt != clearedAt {
                        registry[idx].share = nil
                        registry[idx].shareClearedAt = clearedAt
                        changed = true
                    }
                }
            } else {
                // Activeness is DEVICE-LOCAL (activeID on this device): an
                // appended remote entry must not arrive pre-checked. The
                // writer's active choice only matters in step 0 (fresh
                // adopt) and step 3b (no-active promotion). Adopting it
                // here produced two checked libraries when the other
                // device created one while this device's library was
                // active — and the tap handler no-ops on isActive=true
                // rows, wedging the checkmark until another library was
                // created.
                registry.append(LibraryInfo(id: dto.id, name: dto.name,
                                            isActive: false,
                                            createdAt: dto.createdAt,
                                            modifiedAt: remoteStamp,
                                            share: dto.share,
                                            shareClearedAt: dto.shareClearedAt))
                changed = true
            }
        }

        // Single-active invariant: activeness is device-local, so exactly
        // one entry may be flagged — the one matching activeID. Remote
        // folds (step 0 wholesale adoption) can leave two flagged; a
        // second flagged row renders a second checkmark and its tap is
        // swallowed by the `if !isActive` guard. Net-diff semantics: flip
        // ONLY rows whose flag differs from the target, so a fold whose
        // registry content is unchanged returns false (the no-op contract
        // the tests encode) instead of churning flags into a true.
        let target: LibraryInfo? = {
            if let match = registry.first(where: { $0.id == activeID }) { return match }
            // activeID matches no entry (fresh process, pre-migration):
            // keep the already-flagged row and re-point activeID silently.
            return registry.first(where: { $0.isActive })
        }()
        for i in registry.indices {
            let shouldBeActive = target?.id == registry[i].id
            if registry[i].isActive != shouldBeActive {
                registry[i].isActive = shouldBeActive
                changed = true
            }
        }
        if let target, activeID != target.id {
            activeID = target.id
        }

        // 3b. No active library (deletions removed the active one, a sole
        // appended remote library, or a rename promoted another device's
        // choice): promote the first remaining entry. Runs after the fold
        // loop so appends participate, and on deltas too — deletions there
        // can strand the active flag.
        if !registry.isEmpty, !registry.contains(where: { $0.isActive }) {
            if let next = registry.first {
                for i in registry.indices { registry[i].isActive = registry[i].id == next.id }
                activeID = next.id
                changed = true
            }
        }

        if changed {
            saveRegistry(registry)
        }
        return changed
    }

    private func loadRegistry() -> [LibraryInfo] {
        guard let data = try? Data(contentsOf: registryURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LibraryInfo].self, from: data)) ?? []
    }

    private func saveRegistry(_ libraries: [LibraryInfo]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(libraries)
            try data.write(to: registryURL, options: .atomic)
        } catch {
            libraryLog.error("LibraryScope registry save FAILED")
        }
        adoptShareFacts(libraries)
        notifyChanged()
    }

    /// Registry share facts adopted from another device: seed this device's
    /// SharedLibrarySettings so the share's CloudKit machinery (currentShare,
    /// participants, the Settings management section) works identically
    /// here. Runs on every registry save — a no-op when the local state
    /// already matches. Only handles the OWNER side: a joined share is
    /// always created locally by the accept flow (which writes the
    /// participant-side keys and can't be reconstructed from facts alone).
    private func adoptShareFacts(_ registry: [LibraryInfo]) {
        for info in registry {
            guard let facts = info.share else {
                // Facts gone (owner stopped sharing): drop locally-adopted
                // owner state so the UI reverts to "Share Library".
                if SharedLibrarySettings.membership(libraryID: info.id) == .owner,
                   SharedLibrarySettings.ownerZoneName(libraryID: info.id) != nil {
                    SharedLibrarySettings.reset(libraryID: info.id)
                    libraryLog.notice("Cleared adopted shared-library facts for \(info.id, privacy: .public)")
                }
                continue
            }
            guard SharedLibrarySettings.membership(libraryID: info.id) == .none else { continue }
            SharedLibrarySettings.setMembership(.owner, libraryID: info.id)
            SharedLibrarySettings.setOwnerZoneName(facts.zoneName, libraryID: info.id)
            SharedLibrarySettings.setOwnerZoneOwnerName(facts.zoneOwnerName, libraryID: info.id)
            SharedLibrarySettings.setOwnerShareRecordName(facts.shareRecordName, libraryID: info.id)
            libraryLog.notice("Adopted shared-library facts for \(info.id, privacy: .public) from the registry")
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.librariesChangedNotification, object: nil)
    }
}
// MARK: - Pears full-state sync

extension LibraryScope {
    /// The registry as wire bytes (Pears /settings/libraries.json) — the
    /// same shape as the local file, so apply is a straight decode+fold.
    func exportRegistryPayload() -> Data? {
        let registry = loadRegistry()
        guard !registry.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(registry)
    }

    /// Adopts a peer's registry: the same wholesale/delta semantics as the
    /// retired CloudKit fold — unknown ids append (device-local activeness
    /// preserved), known ids rename on a strictly newer stamp. Deletions
    /// are NOT honored from a peer snapshot (a device that deleted a
    /// library publishes via deleteRegistryRecord semantics, not a
    /// snapshot absence).
    func importRegistryPayload(_ data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let remote = try? decoder.decode([LibraryInfo].self, from: data) else { return }
        var registry = loadRegistry()
        var changed = false
        for dto in remote where dto.id != Self.defaultLibraryID || registry.isEmpty {
            if let idx = registry.firstIndex(where: { $0.id == dto.id }) {
                let remoteStamp = dto.modifiedAt ?? dto.createdAt
                let localStamp = registry[idx].modifiedAt ?? registry[idx].createdAt
                if remoteStamp > localStamp, registry[idx].name != dto.name, !dto.name.isEmpty {
                    registry[idx].name = dto.name
                    registry[idx].modifiedAt = max(localStamp, remoteStamp)
                    changed = true
                }
                if let remoteShare = dto.share, remoteShare.stampedAt > (registry[idx].share?.stampedAt ?? .distantPast) {
                    registry[idx].share = remoteShare
                    registry[idx].shareClearedAt = nil
                    changed = true
                }
            } else {
                registry.append(LibraryInfo(id: dto.id, name: dto.name,
                                            isActive: false,
                                            createdAt: dto.createdAt,
                                            modifiedAt: dto.modifiedAt ?? dto.createdAt,
                                            share: dto.share,
                                            shareClearedAt: dto.shareClearedAt))
                changed = true
            }
        }
        if changed { saveRegistry(registry) }
    }
}
