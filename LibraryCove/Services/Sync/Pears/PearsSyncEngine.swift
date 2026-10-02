import Foundation
import SwiftData
import BareKit

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

    private var memberName = ""

    private init() {}

    // MARK: - Lifecycle

    /// Fresh admin: create the library (first-time owner on this device).
    /// The worklet persists the primary-key credential locally.
    func createLibrary(name: String, libraryID: String, memberName: String) {
        self.memberName = memberName
        role = .writer
        send(json: ["cmd": "create", "library": name])
    }

    func start(libraryID: String, memberName: String) {
        guard !isRunning else { return }
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
                // v2 protocol: the worklet decides admin-vs-member itself
                // (admin = local primary-key credential file exists) and
                // emits 'restored' (admin) or nothing (fresh). A fresh
                // admin gets 'create' from the UI path; a member joins
                // via joinWithKey.
                self.send(json: ["cmd": "restore"])
                self.role = .writer
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

    struct PersistedIdentity: Codable {
        var driveKey: String
        var primaryKey: String
    }

    private func identityDefaultsKey(libraryID: String) -> String {
        "pears.\(libraryID).identity"
    }

    private func loadPersistedIdentity(libraryID: String) -> PersistedIdentity? {
        guard let data = UserDefaults.standard.data(forKey: identityDefaultsKey(libraryID: libraryID)) else { return nil }
        return try? JSONDecoder().decode(PersistedIdentity.self, from: data)
    }

    private func savePersistedIdentity(libraryID: String, driveKey: String, primaryKey: String) {
        let identity = PersistedIdentity(driveKey: driveKey, primaryKey: primaryKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(identity), forKey: identityDefaultsKey(libraryID: libraryID))
    }

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
            }
        case "restored":
            // Admin restore: worklet reopened the writer drive locally.
            if let key = event["key"] as? String { currentDriveKey = key }
            refreshJoinKeys()
        case "redeemFailed":
            // Joiner stayed read-only — surface why (already-used,
            // revoked, unknown, timeout). Guest onboarding continues.
            lastError = "Join link not accepted: \(event["why"] ?? "rejected")"
        case "peer":
            peers += 1
        case "counts":
            // Payload counts changed — run the sync cycle.
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
        defer { isSyncing = false }
        let context = Persistence.shared.mainContext
        do {
            try await pushLocalChanges(libraryID: libraryID, context: context)
            try await pullRemoteChanges(libraryID: libraryID, context: context)
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
        send(json: ["cmd": "joinV2", "key": parts[1], "token": parts[2], "memberName": memberName])
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
    }

    private func pullRemoteChanges(libraryID: String, context: ModelContext) async throws {
        // Discover what the peer has: the worklet's 'paths' event lists
        // the whole drive; the poll triggers it. For the v1 cycle, ask
        // for the known books we already track + any in the last listing.
        let known = await listRemoteBookPaths()
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
            guard normalized.hasPrefix("/books/"), normalized.hasSuffix(".json") else { continue }
            guard let data = await readRawAwait(normalized) else { continue }
            guard let dto = try? decodePayload(SharedBook.self, from: data) else { continue }
            let recordName = SharedLibraryRecord.recordName(type: .book, id: dto.id)
            changes.append(SharedRecordChange(kind: .book(dto)))
            if let cover = await readRawAwait("/covers/\(dto.id)") {
                assets[recordName] = cover
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
    }

    /// Lists /books/*.json via the worklet's 'list' command (reply: paths).
    private func listRemoteBookPaths() async -> [String] {
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
