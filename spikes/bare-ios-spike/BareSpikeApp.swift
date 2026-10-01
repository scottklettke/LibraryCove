// BareSpike 2: library replication between two devices.
//
// The app is BOTH roles via the UI:
//   • "Create Library" — becomes the writer, shows the join key
//   • "Join" (paste key) — becomes the reader, pulls books live
//   • "Add Book" — writers push a sample book into the drive
//   • reader screen live-updates: library name + synced book list
//
// JS side: entry-spike2.js (hyperdrive per library over BareKit.IPC).
// Transport: LAN TCP today (writer listens :8787, reader connects);
// Hyperswarm discovery joins the topic in parallel and takes over when
// the DHT path is reachable — the replication protocol is identical.

import BareKit
import Network
import SwiftUI

/// Pokes the local network once at boot so iOS shows the Local Network
/// permission prompt (Hyperswarm's device-to-device discovery is otherwise
/// silently blocked — the app never appears in Settings → Local Network
/// unless something actually sends a multicast/broadcast packet).
enum LocalNetworkProbe {
    static func trigger() {
        let connection = NWConnection(host: "255.255.255.255", port: 5353, using: .udp)
        connection.stateUpdateHandler = { _ in }
        connection.send(content: Data([0]), completion: .contentProcessed { _ in
            connection.cancel()
        })
        connection.start(queue: .global())
    }
}

/// The device's Wi-Fi (en0) IPv4 address — shown on the writer so the
/// reader can type it into Connect when auto-discovery fails.
enum DeviceIP {
    static func wifi() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let name = String(cString: current.pointee.ifa_name)
            if name == "en0", let sa = current.pointee.ifa_addr {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: host)
                }
            }
            ptr = current.pointee.ifa_next
        }
        freeifaddrs(first)
        return address
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var ipc: BareIPC?
    var buffer = Data()
    var role: Role = .none
    var driveKey: String?
    var primaryKey: String?

    enum Role { case none, writer, reader }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        LocalNetworkProbe.trigger()
        startWorklet()
        return true
    }

    /// UI-test seam: SPIKE_ROLE=writer|reader + SPIKE_KEY=<hex> +
    /// SPIKE_PEER=<writer-ip> drive the flow without taps (writer→reader
    /// two-simulator test). Checked after the worklet boots.
    private func runAutomatedFlowIfAny() {
        let env = ProcessInfo.processInfo.environment
        guard let role = env["SPIKE_ROLE"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            switch role {
            case "writer":
                self.createLibrary(name: "Automated Library")
                // add two books so the reader has content to pull
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.addBook(title: "Dune")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.addBook(title: "The Dispossessed")
                }
            case "reader":
                joinLibrary(key: env["SPIKE_KEY"] ?? "")
                if let peer = env["SPIKE_PEER"] {
                    let port = Int(env["SPIKE_PORT"] ?? "8787") ?? 8787
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.connectToWriter(peer, port: port)
                    }
                }
            default:
                break
            }
        }
    }

    private func startWorklet() {
        BareWorklet.optimize(forMemory: false)

        // SPIKE_BUNDLE env selects the entry (spike2 default, spike3 for
        // A1 payload-fidelity tests) — set via scheme env or xcrun simctl.
        #if targetEnvironment(simulator)
        let bundleName = (ProcessInfo.processInfo.environment["SPIKE_BUNDLE"] ?? "spike2") + "-sim"
        let device = "simulator"
        #else
        let bundleName = (ProcessInfo.processInfo.environment["SPIKE_BUNDLE"] ?? "spike2") + "-ios"
        let device = UIDevice.current.name
        #endif
        log("device: \(device)")

        guard let bundleURL = Bundle.main.url(forResource: bundleName, withExtension: "bundle"),
              let source = try? String(contentsOf: bundleURL, encoding: .utf8) else {
            log("FATAL: \(bundleName).bundle missing — run npm run bundle, then rebuild")
            return
        }
        log("bundle loaded: \(bundleName) (\(source.utf8.count) bytes)")

        let worklet = BareWorklet(configuration: nil)!
        worklet.start("/bare-spike.bundle", source: Data(source.utf8), arguments: [])

        let ipc = BareIPC(worklet: worklet)!
        self.ipc = ipc

        func readLoop() {
            ipc.read { [weak self] data, error in
                guard let self else { return }
                if let data {
                    if data.isEmpty {
                        log("JS stream closed")
                        return
                    }
                    buffer.append(data)
                    drainBuffer()
                }
                readLoop()
            }
        }
        readLoop()

        log("worklet started")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            // Documents is the sync storage root — per-app, sandboxed.
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
            self?.send(json: ["cmd": "init", "storageRoot": docs])
            self?.runAutomatedFlowIfAny()
        }
    }

    // MARK: - UI actions (called from the SwiftUI views)

    func createLibrary(name: String) {
        role = .writer
        send(json: ["cmd": "create", "library": name])
    }

    /// Accepts "<driveKey>" (read-only, legacy) or "<driveKey>:<primaryKey>"
    /// (bidirectional — the primary key derives the drive's writer keypair).
    func joinLibrary(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":").map(String.init)
        guard let drivePart = parts.first, drivePart.count == 64,
              drivePart.allSatisfy({ $0.isHexDigit }) else {
            log("⚠️ Join key looks wrong (\(trimmed.count) chars, need 64 or 64:64 hex). Copy it again from the writer's screen.")
            NotificationCenter.default.post(name: .spikeJoinFailed, object: nil)
            role = .none
            return
        }
        var primaryPart: String?
        if parts.count > 1 {
            let p = parts[1]
            if p.count == 64 && p.allSatisfy({ $0.isHexDigit }) {
                primaryPart = p
            } else {
                log("⚠️ Primary key part malformed — joining READ-ONLY. Recopy the full key for write access.")
            }
        }
        role = primaryPart != nil ? .writer : .reader
        driveKey = drivePart
        primaryKey = primaryPart
        if let primaryPart {
            send(json: ["cmd": "join", "key": drivePart, "primaryKey": primaryPart])
        } else {
            send(json: ["cmd": "join", "key": drivePart])
        }
    }

    func addBook(title: String) {
        log("addBook called, role=\(role), title=\(title)")
        guard role == .writer else { log("addBook BLOCKED: not writer"); return }
        let id = UUID().uuidString.prefix(8)
        send(json: ["cmd": "put", "path": "books/\(id).json",
                    "data": ["title": title, "addedBy": UIDevice.current.name,
                             "addedAt": ISO8601DateFormatter().string(from: Date())]])
        // Writers listen once, from the created event (a second listen hits
        // EADDRINUSE and aborts the worklet).
    }

    func connectToWriter(_ host: String, port: Int = 8787) {
        send(json: ["cmd": "connect", "host": host, "port": port])
    }

    // MARK: - IPC plumbing

    private func send(json: [String: Any]) {
        guard let ipc, let data = try? JSONSerialization.data(withJSONObject: json),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        log("→ \(line.trimmingCharacters(in: .newlines))")
        ipc.write(Data(line.utf8)) { error in
            if let error { self.log("write failed: \(error.localizedDescription)") }
        }
    }

    private func drainBuffer() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            log("← \(line)")
            if let obj = try? JSONSerialization.jsonObject(with: lineData),
               let dict = obj as? [String: Any] {
                handle(event: dict)
            }
        }
    }

    private func handle(event: [String: Any]) {
        switch event["evt"] as? String {
        case "boot":
            log("✅ JS booted — pick Create or Join")
        case "created":
            let key = event["key"] as? String ?? "?"
            driveKey = key
            // The store's primary key derives every drive keypair — sharing
            // it makes the joiner a full writer (bidirectional sync).
            if let primaryKey = event["primaryKey"] as? String {
                self.primaryKey = primaryKey
            }
            log("📚 Library created.\nJoin key (send to the other device):\n\(key)")
            // Writers listen immediately for readers on the LAN.
            send(json: ["cmd": "listen", "port": 8787])
            if ProcessInfo.processInfo.environment["SPIKE_ROLE"] == "writer" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.addBook(title: "Dune")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.addBook(title: "The Dispossessed")
                }
            }
        case "joined":
            log("🔗 Joined library — connecting to writer…")
        case "library":
            log("📖 Library: \(event["name"] ?? "?")")
        case "sync":
            log("📥 Synced books: \(event["count"] ?? 0)")
        case "written":
            log("✍️ Book written to drive")
        case "peer":
            let via = event["via"] ?? "?"
            let role = event["role"] as? String
            let remote = event["remote"] as? String
            var line = "🤝 Peer connected via \(via)"
            if let role {
                line += " (\(role)"
                if let remote { line += " \(remote)" }
                line += ")"
            } else if let remote {
                line += " (\(remote))"
            }
            log(line)
        case "listening":
            log("👂 Listening on port \(event["port"] ?? "?")")
        case "data":
            if let path = event["path"] as? String, let data = event["data"] {
                log("📥 \(path): \(data)")
            }
        case "list":
            let paths = event["paths"] as? [String] ?? []
            log("📚 Books in library: \(paths.filter { $0.contains("books/") }.count)")
        case "error":
            log("⚠️ \(event["msg"] ?? "unknown error")")
        default:
            break
        }
    }

    private func log(_ s: String) {
        print("BareSpike: \(s)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .spikeLog, object: s)
        }
        let line = "\(Date()): \(s)\n"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spike.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - UI

struct RootView: View {
    @State private var logLines: [String] = []
    @State private var libraryName = "My Library"
    @State private var joinKey = ""
    @State private var bookTitle = ""
    @State private var writerHost = ""
    @State private var copied = false
    @State private var joinFailed = false
    let appDelegate: AppDelegate

    /// Writer's join key — surfaced with a Copy button.
    private var writerKey: String? {
        appDelegate.role == .writer ? appDelegate.driveKey : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appDelegate.role == .none {
                if joinFailed {
                    Text("⚠️ That key didn't look right. On the writer device, tap Copy next to the join key, then paste it here.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    TextField("Library name", text: $libraryName)
                        .textFieldStyle(.roundedBorder)
                    Button("Create") { appDelegate.createLibrary(name: libraryName) }
                        .buttonStyle(.borderedProminent)
                }
                HStack {
                    TextField("Join key (from writer)", text: $joinKey)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Join") { appDelegate.joinLibrary(key: joinKey.trimmingCharacters(in: .whitespaces)) }
                        .buttonStyle(.borderedProminent)
                }
            } else if appDelegate.role == .writer {
                HStack {
                    TextField("Book title", text: $bookTitle)
                        .textFieldStyle(.roundedBorder)
                    Button("Add Book") {
                        appDelegate.addBook(title: bookTitle)
                        bookTitle = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bookTitle.isEmpty)
                }
                if let key = writerKey {
                    // Bidirectional share: driveKey:primaryKey — the joiner
                    // becomes a full writer (adds books from their device).
                    let shareKey = appDelegate.primaryKey != nil
                        ? key + ":" + appDelegate.primaryKey!
                        : key
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Join key — paste into Join on the other device (grants write access):")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text(shareKey)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(4)
                                .textSelection(.enabled)
                            Button {
                                UIPasteboard.general.string = shareKey
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                            } label: {
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } else {
                // READER: after joining, devices on the same Wi-Fi usually
                // find each other automatically (Hyperswarm). The manual
                // IP fallback stays for networks that block discovery.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Writer's IP — only if auto-discovery fails", text: $writerHost)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                        Button("Connect") { appDelegate.connectToWriter(writerHost) }
                            .buttonStyle(.bordered)
                            .disabled(writerHost.isEmpty)
                    }
                    Text("Waiting for the writer… discovery runs automatically. If nothing happens in ~30s, ask the writer for their IP (shown on their screen) and tap Connect.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button {
                    UIPasteboard.general.string = logLines.joined(separator: "\n")
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "Logs copied" : "Copy logs", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Spacer()
                Text("\(logLines.count) lines")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(logLines.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(12)
        .onReceive(NotificationCenter.default.publisher(for: .spikeLog)) { note in
            if let line = note.object as? String { logLines.append(line) }
            if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .spikeJoinFailed)) { _ in
            joinFailed = true
        }
    }
}

@main
struct BareSpikeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { RootView(appDelegate: delegate) }
    }
}

extension Notification.Name {
    static let spikeLog = Notification.Name("spikeLog")
    static let spikeJoinFailed = Notification.Name("spikeJoinFailed")
}
