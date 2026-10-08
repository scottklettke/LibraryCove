import Foundation
import LocalAuthentication
import SwiftData
import BareKit
import UIKit

/// Pears P2P sync engine: embeds the Bare worklet (Hyperdrive over
/// Hyperswarm) and mirrors SwiftData rows through it.
///
/// Reuses the transport facts proven in spikes/bare-ios-spike:
/// - NDJSON over BareKit.IPC, serialized drain (concurrent read() segfaults)
/// - drive.replicate(conn) wiring; shared-primaryKey writable joins
/// - Blob blocks arrive async over a LIVE stream — reads retry/re-bridge
/// - Payloads are OPAQUE base64 bytes (JSONEncoder msSince1970 + sortedKeys);
///   the worklet never re-serializes them
///
/// v1 scope: foreground sync (launch/foreground/manual), per-library
/// enable, single-use join keys with admin audit. No background sync.
@MainActor
final class PearsSyncEngine: ObservableObject {
    static let shared = PearsSyncEngine()

    // MARK: - Published state

    @Published private(set) var isRunning = false
    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?
    @Published private(set) var peers = 0
    /// Last completed sync cycle (both pull and push).
    @Published private(set) var lastSyncAt: Date?
    /// Per-directory payload counts from the worklet's poll — the live
    /// view of what the drive holds (books/notes/lists/items/covers/...).
    @Published private(set) var counts: [String: Int] = [:]
    /// Rolling worklet console (the barespike log stream) — the
    /// Advanced panel renders it for under-the-hood visibility.
    @Published private(set) var consoleLines: [String] = []
    /// Pending/used/revoked keys for the admin surface (active library).
    @Published private(set) var joinKeys: [PearsJoinKey] = []
    /// Set when a member announcement was reconciled — UI surfaces it.
    @Published private(set) var lastJoinedMember: String?

    /// Fired after remote payloads were applied — UI refresh hook.
    var onRemoteChange: (() -> Void)?

    // MARK: - Worklet state

    private var worklet: BareWorklet?
    private var ipc: BareIPC?

    /// The active library this engine instance syncs. v1: one library per
    /// device session (matches the mirror's provider-slot model).
    private(set) var activeLibraryID: String?

    /// The admin device's drive public key (from 'created'/'restored'
    /// events) — the only identity piece invite strings carry.
    private(set) var currentDriveKey: String?
    /// Stable per-device tag for diagnosing cross-device effects
    /// (persists in UserDefaults; shown in the Advanced panel).
    private(set) var deviceTag: String = {
        let k = "pears.deviceTag"
        if let s = UserDefaults.standard.string(forKey: k) { return s }
        let s = "dev-" + UUID().uuidString.prefix(8)
        UserDefaults.standard.set(s, forKey: k)
        return s
    }()

    private var memberName = ""

    private init() {}

    // MARK: - Lifecycle

    /// Fresh admin: create the library (first-time owner on this device).
    /// The worklet persists the primary-key credential locally.
    /// `fresh` (welcome path) wipes any prior session first — a NEW
    /// library must never silently restore an old identity.
    func createLibrary(name: String, libraryID: String, memberName: String, fresh: Bool = true) {
        // Delegates to start(.create): the worklet must BOOT and receive
        // init before the create command — sending early dropped it on
        // the floor (the "drive key —" / silent-buttons report).
        start(libraryID: libraryID, memberName: memberName, fresh: fresh, mode: .create,
              libraryName: name)
    }

    /// Boot the worklet and either restore an existing session or wait
    /// for an explicit create. `createLibrary` (welcome path) calls this
    /// with .create — the OLD createLibrary sent its command before the
    /// worklet booted and before init, so the command vanished ("pears
    /// ready — storage: ." with drive key "—" was that bug).
    enum BootMode { case restore, create }
    func start(libraryID: String, memberName: String, fresh: Bool = false, mode: BootMode = .restore, libraryName: String? = nil) {
        guard !isRunning else { return }
        if fresh { Self.wipeAllLocalState() }
        activeLibraryID = libraryID
        self.memberName = memberName
        do {
            let worklet = BareWorklet(configuration: nil)!
            self.worklet = worklet
            let source = try bundleSource()
            worklet.start("/pears.bundle", source: Data(source.utf8), arguments: [])
            let ipc = BareIPC(worklet: worklet)!
            self.ipc = ipc
            isRunning = true
            readLoop()
            // Give the worklet a beat to boot, then init with the storage
            // root (same 1.5s pacing as the spike — bare boots fast but the
            // first IPC write can race the stream setup).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("pears").path
                try? FileManager.default.createDirectory(atPath: docs, withIntermediateDirectories: true)
                self.send(json: ["cmd": "init", "storageRoot": docs])
                switch mode {
                case .restore:
                    // v2 protocol: the worklet decides admin-vs-member itself
                    // (admin = local primary-key credential file exists) and
                    // emits 'restored' (admin) or nothing (fresh). A member
                    // joins via joinWithKey.
                    self.send(json: ["cmd": "restore"])
                    self.role = .writer
                case .create:
                    self.role = .writer
                    self.isIdentityOriginator = true
                    self.send(json: ["cmd": "create", "library": libraryName ?? libraryID])
                }
            }
        } catch {
            lastError = "Pears worklet failed to start: \(error.localizedDescription)"
        }
    }

    func stop() {
        ipc = nil
        worklet = nil
        isRunning = false
        ipcLineBuffer.reset()
    }

    private func bundleSource() throws -> String {
        #if targetEnvironment(simulator)
        let name = "pears-sim"
        #else
        let name = "pears-ios"
        #endif
        guard let url = Bundle.main.url(forResource: name, withExtension: "bundle"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw PearsError.bundleMissing(name)
        }
        return source
    }

    // MARK: - Role & identity

    enum Role { case none, writer, reader }
    private(set) var role: Role = .none

    /// True when THIS device created the library (the identity originator).
    /// Settings/profile payloads are pushed ONLY by the originator — a
    /// member pushing its own AIConfig/profile would thrash the owner's
    /// identity data (last-writer-wins on rows the owner should own).
    /// Members push only their /members/<token>.json announce.
    private(set) var isIdentityOriginator = false

    // v2: identity persists in the WORKLET — the admin's primary key is a
    // local credential file (primary-key.hex), member sessions live in
    // the worklet's library-meta.json. The engine holds only the drive
    // public key (currentDriveKey, from created/restored events).

    // MARK: - IPC

    /// Callback-thread line buffer. BareIPC.read fires on an ARBITRARY
    /// queue — this buffer and the line-splitting must NOT touch
    /// MainActor-isolated state. Parsed events hop to MainActor.
    private let ipcLineBuffer = IPCLineBuffer()

    private func readLoop() {
        ipc?.read { [weak self] data, error in
            guard let self else { return }
            guard let data, !data.isEmpty else {
                if data?.isEmpty == true {
                    Task { @MainActor in self.lastError = "Pears worklet stream closed" }
                }
                return
            }
            let events = self.ipcLineBuffer.appendAndExtract(data)
            guard !events.isEmpty else {
                self.readLoop()
                return
            }
            Task { @MainActor in
                for event in events { self.handle(event: event) }
            }
            self.readLoop()
        }
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        ipc?.write(Data(line.utf8))
    }

    // MARK: - Event handling

    private func handle(event: [String: Any]) {
        switch event["evt"] as? String {
        case "ready", "joined":
            break
        case "created":
            // v2: the worklet no longer sends the primaryKey (it persists
            // it locally as the admin credential). The drive key arrives
            // here; generateJoinKey uses it for invite strings. The pk
            // is fetched via the worklet's own restore path — the engine
            // learns it only through 'restored' events or never.
            if let key = event["key"] as? String, let libraryID = activeLibraryID {
                currentDriveKey = key
                isIdentityOriginator = true   // this device created the drive
            }
        case "restored":
            // Admin restore: worklet reopened the writer drive locally.
            if let key = event["key"] as? String { currentDriveKey = key }
            isIdentityOriginator = true
            refreshJoinKeys()
        case "redeemFailed":
            // Joiner stayed read-only — surface why (already-used,
            // revoked, unknown, timeout). Guest onboarding continues.
            lastError = "Join link not accepted: \(event["why"] ?? "rejected")"
        case "log":
            if let msg = event["msg"] as? String {
                consoleLines.append(msg)
                if consoleLines.count > 200 { consoleLines.removeFirst(consoleLines.count - 200) }
            }
        case "peer":
            peers += 1
        case "counts":
            // Payload counts changed — run the sync cycle.
            if let c = event["counts"] as? [String: Int] { counts = c }
            Task { await syncNow() }
        case "data":
            // readRaw reply: resume the awaiting pull continuation.
            if let path = event["path"] as? String,
               let b64 = event["data"] as? String,
               let bytes = Data(base64Encoded: b64),
               let continuation = pendingReads.removeValue(forKey: path) {
                continuation.resume(returning: bytes)
            }
        case "written":
            // putRaw reply (also fires for legacy puts — path-keyed, so
            // only awaited paths resume).
            if let path = event["path"] as? String,
               let continuation = pendingPuts.removeValue(forKey: path) {
                continuation.resume()
            }
        case "paths":
            // 'list' reply: resolve the discovery continuation.
            if let paths = event["paths"] as? [String],
               let continuation = listCompletion {
                listCompletion = nil
                continuation.resume(returning: paths)
            }
        case "joinKeys":
            if let keysData = try? JSONSerialization.data(withJSONObject: event["keys"] ?? []),
               let keys = try? JSONDecoder().decode([PearsJoinKey].self, from: keysData) {
                joinKeys = keys
            }
        case "memberJoined":
            if let name = event["name"] as? String {
                lastJoinedMember = name
                refreshJoinKeys()
            }
        case "error":
            lastError = event["msg"] as? String ?? "unknown worklet error"
        default:
            break
        }
    }

    // MARK: - Sync cycle

    /// Push local changed rows into the drive, pull peer rows into SwiftData.
    /// Called on foreground/launch and when the worklet reports count changes.
    func syncNow() async {
        guard isRunning, let libraryID = activeLibraryID else { return }
        guard !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
            lastSyncAt = Date()
        }
        print("[PEARS-\(deviceTag)] sync cycle starting")
        let context = Persistence.shared.mainContext
        do {
            // PULL FIRST: a member's local core must hold the peer's
            // blocks before appending its own, or the append forks
            // (host-proven: write-before-sync = silent divergence).
            try await pullRemoteChanges(libraryID: libraryID, context: context)
            try await pushLocalChanges(libraryID: libraryID, context: context)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Join tokens (v2 redemption protocol)

    /// Admin side: generates a single-use token and returns the invite
    /// string to send — lc1.<driveKey>.<token>. The primary key is NEVER
    /// part of it; the joiner receives it only via the redemption
    /// handshake (worklet's serveControl) once the token validates.
    func generateJoinKey(role: PearsJoinKey.Role) -> String? {
        guard isRunning, case .writer = self.role, activeLibraryID != nil,
              let driveKey = currentDriveKey else { return nil }
        let token = PearsJoinKeyGenerator.newCode()
        let key = PearsJoinKey(code: token, role: role, createdAt: Date(), state: .pending, usedBy: nil, usedAt: nil)
        joinKeys.append(key)
        persistKeys(joinKeys)
        // The worklet persists the token to its local keys.json; the
        // admin device IS the single writer pre-redemption.
        send(json: ["cmd": "generateJoinKey", "role": role.rawValue])
        return "lc1.\(driveKey).\(token)"
    }

    func revokeJoinKey(_ token: String) {
        guard let idx = joinKeys.firstIndex(where: { $0.code == token }) else { return }
        joinKeys[idx].state = .revoked
        persistKeys(joinKeys)
        send(json: ["cmd": "revokeJoinKey", "token": token])
    }

    func refreshJoinKeys() {
        send(json: ["cmd": "listJoinKeys"])
    }

    private func persistKeys(_ keys: [PearsJoinKey]) {
        guard let libraryID = activeLibraryID else { return }
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: "pears.\(libraryID).keys")
        }
    }

    /// Joiner side: consume a pasted or link-opened invite —
    /// lc1.<driveKey>.<token>. Opens read-only, redeems the token over
    /// the encrypted control channel; the admin dispenses the primary
    /// key only on a valid redemption. Failure stays read-only (guest).
    func joinWithKey(_ joinString: String, memberName: String) {
        let cleaned = joinString.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "librarycove://join?key=", with: "")
        let parts = cleaned.split(separator: ".").map(String.init)
        guard parts.count == 3, parts[0] == "lc1",
              parts[1].count == 64, parts[2].count == 32,
              parts[1].allSatisfy({ $0.isHexDigit }),
              parts[2].allSatisfy({ $0.isHexDigit }) else {
            lastError = PearsError.badJoinKey.errorDescription ?? "Bad join key"
            return
        }
        self.memberName = memberName
        role = .reader
        // Boot the worklet first (same drop-the-command bug as create),
        // then deliver joinV2 once init has run.
        start(libraryID: "joining", memberName: memberName, fresh: true, mode: .restore)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self] in
            self?.send(json: ["cmd": "joinV2", "key": parts[1], "token": parts[2], "memberName": memberName])
        }
    }

    // MARK: - Payload pipeline
    //
    // Push: every Book row in the active library → SharedBook DTO (the
    // mirror's mapping — same field for field) → JSONEncoder with the
    // EXACT SharedLibraryRecord settings (msSince1970 + sortedKeys) →
    // putRaw books/<id>.json. Cover bytes → covers/<id> sibling file.
    //
    // Pull: readRaw every books/*.json the peer replicated in, decode,
    // upsert by the verified conflict rule (record-level LWW on
    // updatedAt, ties to the INCOMING copy — the mirror's hash-index
    // rides CKRecord change tokens that P2P doesn't have; record-level
    // LWW is the correct transport-faithful form and documented).

    /// Outstanding readRaw continuations, keyed by path (the worklet
    /// replies {evt:'data',path,data:base64}).
    private var pendingReads: [String: CheckedContinuation<Data?, Never>] = [:]

    private func encodePayload<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]   // mirrors SharedLibraryRecord.setPayload
        return try encoder.encode(value)
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }

    private func readRawAwait(_ path: String) async -> Data? {
        await withCheckedContinuation { continuation in
            pendingReads[path] = continuation
            send(json: ["cmd": "readRaw", "path": path])
        }
    }

    private func putRawAwait(_ path: String, bytes: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingPuts[path] = continuation
            send(json: ["cmd": "putRaw", "path": path, "data": bytes.base64EncodedString()])
        }
    }

    private var pendingPuts: [String: CheckedContinuation<Void, Never>] = [:]

    private func pushLocalChanges(libraryID: String, context: ModelContext) async throws {
        // Content: every row of every content type in the active library.
        let books = (try? context.fetch(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? []
        for book in books {
            let dto = SharedLibraryMirror.dto(from: book)
            let path = "/books/\(book.id).json"
            // Push every row each cycle (v1 simplicity; the drive dedupes
            // identical blocks — no bytes move unless content changed).
            try await putRawAwait(path, bytes: encodePayload(dto))
            // Cover bytes: sibling file, the CKAsset equivalent.
            if let coverBytes = CoverImageStore.data(forBookID: book.id) {
                try await putRawAwait("/covers/\(book.id)", bytes: coverBytes)
            }
        }
        let notes = (try? context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? []
        for note in notes {
            try await putRawAwait("/notes/\(note.id).json",
                                  bytes: encodePayload(SharedLibraryMirror.dto(from: note)))
        }
        let lists = (try? context.fetch(FetchDescriptor<ReadingList>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? []
        for list in lists {
            try await putRawAwait("/lists/\(list.id).json",
                                  bytes: encodePayload(SharedLibraryMirror.dto(from: list)))
        }
        let items = (try? context.fetch(FetchDescriptor<ReadingListItem>(
            predicate: #Predicate { $0.libraryID == libraryID }
        ))) ?? []
        for item in items {
            try await putRawAwait("/items/\(item.id).json",
                                  bytes: encodePayload(SharedLibraryMirror.dto(from: item)))
        }

        // Identity + settings: pushed by the IDENTITY ORIGINATOR only.
        // A member pushing its own profile/AIConfig would thrash the
        // owner's identity data. Members publish /members/<token>.json
        // (the redemption announce) and pull everything else.
        guard isIdentityOriginator else { return }

        // Profile: the canonical member row (name is what redemptions
        // record; the peer adopts it on pull). SwiftData @Model classes
        // aren't Codable — ship a dedicated profile payload.
        if let user = (try? context.fetch(FetchDescriptor<User>(
            predicate: #Predicate { $0.isActive }
        )))?.first {
            let profile = PearsProfilePayload(id: user.id,
                                              displayName: user.displayName,
                                              email: user.email,
                                              avatarURL: user.avatarURL)
            try await putRawAwait("/profile/\(user.id).json", bytes: encodePayload(profile))
        }

        // Settings: library registry (names/active/creates/deletes) + AI
        // settings. The AI API key lives in the Keychain and NEVER syncs.
        if let registry = LibraryScope.shared.exportRegistryPayload() {
            try await putRawAwait("/settings/libraries.json", bytes: registry)
        }
        if let ai = AIConfig.exportSyncPayload() {
            try await putRawAwait("/settings/ai.json", bytes: ai)
        }
        // Note: SharedLibrarySettings memberships ride the worklet's own
        // keys.json / members files — the redemption model owns them.
    }

    private func pullRemoteChanges(libraryID: String, context: ModelContext) async throws {
        // Discover what the peer has: the worklet's 'paths' event lists
        // the whole drive; the poll triggers it. For the v1 cycle, ask
        // for the known books we already track + any in the last listing.
        let known = await listRemotePaths()
        var changes: [SharedRecordChange] = []
        var assets: [String: Data] = [:]
        let mirror = SharedLibraryMirror()
        var index = mirror.loadIndex(libraryID: libraryID)
        let local = mirror.scan(context: context, libraryID: libraryID)
        let entriesByName = Dictionary(local.map { ($0.recordName, $0) },
                                       uniquingKeysWith: { first, _ in first })
        for path in known {
            // The worklet's drive.list('/') yields keys WITHOUT the
            // leading slash ('books/x.json') while puts use '/books/…'
            // — normalize so readRaw paths match.
            let normalized = path.hasPrefix("/") ? path : "/" + path
            if normalized.hasPrefix("/books/"), normalized.hasSuffix(".json") {
                guard let data = await readRawAwait(normalized) else { continue }
                guard let dto = try? decodePayload(SharedBook.self, from: data) else { continue }
                let recordName = SharedLibraryRecord.recordName(type: .book, id: dto.id)
                changes.append(SharedRecordChange(kind: .book(dto)))
                if let cover = await readRawAwait("/covers/\(dto.id)") {
                    assets[recordName] = cover
                }
            } else if normalized.hasPrefix("/notes/"), normalized.hasSuffix(".json") {
                guard let data = await readRawAwait(normalized),
                      let dto = try? decodePayload(SharedNote.self, from: data) else { continue }
                changes.append(SharedRecordChange(kind: .note(dto)))
            } else if normalized.hasPrefix("/lists/"), normalized.hasSuffix(".json") {
                guard let data = await readRawAwait(normalized),
                      let dto = try? decodePayload(SharedReadingList.self, from: data) else { continue }
                changes.append(SharedRecordChange(kind: .readingList(dto)))
            } else if normalized.hasPrefix("/items/"), normalized.hasSuffix(".json") {
                guard let data = await readRawAwait(normalized),
                      let dto = try? decodePayload(SharedReadingListItem.self, from: data) else { continue }
                changes.append(SharedRecordChange(kind: .readingListItem(dto)))
            }
        }
        guard !changes.isEmpty else { return }
        let applied = mirror.apply(changes: changes,
                                   assets: assets,
                                   entriesByName: entriesByName,
                                   index: &index,
                                   libraryID: libraryID,
                                   context: context)
        mirror.saveIndex(index, libraryID: libraryID)
        if applied > 0 { onRemoteChange?() }

        // Full-state sync: profile, library registry, AI settings.
        let normalized = { (p: String) in p.hasPrefix("/") ? p : "/" + p }
        if let profileData = await readRawAwait(normalized("/profile/member-primary.json")) {
            applyRemoteProfile(profileData, context: context)
        }
        if let registryData = await readRawAwait(normalized("/settings/libraries.json")) {
            LibraryScope.shared.importRegistryPayload(registryData)
        }
        if let aiData = await readRawAwait(normalized("/settings/ai.json")) {
            AIConfig.importSyncPayload(aiData)
        }
    }

    /// Adopts the peer's canonical member row: name/email/avatar land on
    /// the local primary row (the id is the stable 'member-primary').
    private func applyRemoteProfile(_ data: Data, context: ModelContext) {
        guard let profile = try? decodePayload(PearsProfilePayload.self, from: data) else { return }
        let existing = (try? context.fetch(FetchDescriptor<User>(
            predicate: #Predicate { $0.id == profile.id }
        )))?.first
        if let existing {
            if existing.displayName != profile.displayName { existing.displayName = profile.displayName }
            if existing.email != profile.email { existing.email = profile.email }
            if existing.avatarURL != profile.avatarURL { existing.avatarURL = profile.avatarURL }
        } else {
            context.insert(User(id: profile.id, email: profile.email,
                                displayName: profile.displayName,
                                avatarURL: profile.avatarURL))
        }
        try? context.save()
    }

    /// Lists the whole drive via the worklet's 'list' command (reply:
    /// paths) — the caller filters by directory.
    private func listRemotePaths() async -> [String] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            listCompletion = continuation
            send(json: ["cmd": "list"])
        }
    }

    private var listCompletion: CheckedContinuation<[String], Never>?
}

enum PearsError: LocalizedError {
    case bundleMissing(String)
    case badJoinKey

    var errorDescription: String? {
        switch self {
        case .bundleMissing(let name):
            return "Pears bundle \(name).bundle missing — rebuild the app with the bundled worklet."
        case .badJoinKey:
            return "That join key doesn't look right. Copy it again from the owner's device."
        }
    }
}

enum PearsJoinKeyGenerator {
    static func newCode() -> String {
        let alphabet = Array("0123456789abcdef")
        return String((0..<32).map { _ in alphabet.randomElement()! })
    }
}

/// Single-use join key record — mirrors the worklet's keys.json entries.
struct PearsJoinKey: Codable, Equatable, Identifiable {
    enum Role: String, Codable { case admin, editor, guest }
    enum State: String, Codable { case pending, used, revoked }

    var code: String
    var role: Role
    var createdAt: Date
    var state: State
    var usedBy: String?
    var usedAt: Date?

    var id: String { code }
}

/// Thread-safe NDJSON line splitter for the BareIPC callback thread.
/// `appendAndExtract` and `reset` are the only mutation surfaces; they
/// serialize on an NSLock so the arbitrary-queue read callback can never
/// race a reset or a second in-flight read.
final class IPCLineBuffer {
    private let lock = NSLock()
    private var buffer = Data()

    /// Appends bytes and returns every COMPLETE line parsed as a JSON
    /// dictionary. Partial trailing bytes stay buffered.
    func appendAndExtract(_ data: Data) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var events: [[String: Any]] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            events.append(obj)
        }
        return events
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }
}

/// Wire payload for the canonical member row — User is a SwiftData
/// @Model (not Codable), so the profile travels in its own struct.
/// The id is always LibraryScope.primaryMemberID; other fields are the
/// identity the peer adopts.
struct PearsProfilePayload: Codable, Equatable {
    var id: String
    var displayName: String
    var email: String
    var avatarURL: String?
}

import CoreImage.CIFilterBuiltins

/// Renders an invite string as a QR code image (the owner-side "Show QR").
enum PearsQR {
    static func image(for invite: String, scale: CGFloat = 8) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(invite.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension PearsSyncEngine {
    /// Factory-reset: stop the engine, delete the worklet's storage root
    /// (drives, primary-key credentials, library-meta, keys) and the
    /// engine's UserDefaults state. Without this, "Delete everything"
    /// leaves Documents/pears/ intact and the next launch RESTORES the
    /// supposedly-deleted identity — the reported reset-doesn't-stick bug.
    @MainActor
    static func wipeAllLocalState() {
        shared.stop()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pears").path
        try? FileManager.default.removeItem(atPath: docs)
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("pears.") {
            defaults.removeObject(forKey: key)
        }
    }
}


/// Biometric gate for identity/admin surfaces — the device-link invite
/// grants admin control over the whole library, so it stays behind
/// Face ID / Touch ID.
enum PearsAuth {
    static func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
                || ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(true)   // no passcode/biometrics on device — don't lock the user out
            return
        }
        let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        ctx.evaluatePolicy(policy, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
