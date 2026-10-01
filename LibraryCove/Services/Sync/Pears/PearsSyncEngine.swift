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

    private var memberName = ""

    private init() {}

    // MARK: - Lifecycle

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
                // Restore or create follows the caller's intent. A writer
                // restores its own drive; a first-time creator gets a
                // create call from the UI path.
                if let persisted = self.loadPersistedIdentity(libraryID: libraryID) {
                    self.send(json: ["cmd": "join", "key": persisted.driveKey,
                                     "primaryKey": persisted.primaryKey, "wipe": false])
                } else {
                    self.send(json: ["cmd": "create", "library": libraryID])
                }
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
            // Fresh create: persist the identity for future restores.
            if let key = event["key"] as? String, let primaryKey = event["primaryKey"] as? String,
               let libraryID = activeLibraryID {
                savePersistedIdentity(libraryID: libraryID, driveKey: key, primaryKey: primaryKey)
            }
        case "peer":
            peers += 1
        case "counts":
            // Payload counts changed — run the sync cycle.
            Task { await syncNow() }
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

    // MARK: - Join keys

    /// Generates a single-use key and returns the full join string to send.
    func generateJoinKey(role: PearsJoinKey.Role) -> String? {
        guard isRunning, case .writer = self.role, let libraryID = activeLibraryID,
              let identity = loadPersistedIdentity(libraryID: libraryID) else { return nil }
        let code = PearsJoinKeyGenerator.newCode()
        let key = PearsJoinKey(code: code, role: role, createdAt: Date(), state: .pending, usedBy: nil, usedAt: nil)
        joinKeys.append(key)
        persistKeys(joinKeys)
        publishKeysToWorklet(joinKeys)
        return "lc1.\(identity.driveKey).\(identity.primaryKey).\(code)"
    }

    func revokeJoinKey(_ code: String) {
        guard let idx = joinKeys.firstIndex(where: { $0.code == code }) else { return }
        joinKeys[idx].state = .revoked
        persistKeys(joinKeys)
        publishKeysToWorklet(joinKeys)
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

    private func publishKeysToWorklet(_ keys: [PearsJoinKey]) {
        // The worklet writes /meta/keys.json; reconcileMembers runs there.
        guard let data = try? JSONEncoder().encode(keys) else { return }
        send(json: ["cmd": "putRaw", "path": "/meta/keys.json", "data": data.base64EncodedString()])
    }

    /// Joiner side: consume a pasted or link-opened join string.
    func joinWithKey(_ joinString: String, memberName: String) {
        let cleaned = joinString.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "librarycove://join?key=", with: "")
        let parts = cleaned.split(separator: ".").map(String.init)
        guard parts.count == 4, parts[0] == "lc1",
              parts[1].count == 64, parts[2].count == 64, parts[3].count == 32,
              parts[1].allSatisfy({ $0.isHexDigit }),
              parts[2].allSatisfy({ $0.isHexDigit }),
              parts[3].allSatisfy({ $0.isHexDigit }) else {
            lastError = PearsError.badJoinKey.errorDescription ?? "Bad join key"
            return
        }
        self.memberName = memberName
        role = .writer
        send(json: ["cmd": "join", "key": parts[1], "primaryKey": parts[2]])
        // Announce membership once the drive is writable (join completes
        // async in the worklet; announce also re-runs on restore).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.send(json: ["cmd": "announceMembership", "code": parts[3], "memberName": memberName])
        }
    }

    // MARK: - Payload pipeline (wired in the codec phase)

    private func pushLocalChanges(libraryID: String, context: ModelContext) async throws {
        // Next phase: scan dirty rows via SharedLibraryMirror semantics,
        // encode via SharedLibraryRecord encoder settings, putRaw each.
    }

    private func pullRemoteChanges(libraryID: String, context: ModelContext) async throws {
        // Next phase: readRaw peer paths, decode, apply via the mirror's
        // verified conflict rule (hash-dirty → LWW updatedAt, ties to server).
    }
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
