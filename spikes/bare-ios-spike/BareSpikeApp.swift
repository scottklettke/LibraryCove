// BareSpike: boots a Bare worklet and proves the full P2P chain:
// JS boots → IPC round-trip → Hyperswarm up (raw sockets granted).
//
// Integration contract (mirrors bare-kit's own test/apple/worklet-ipc.m):
//   worklet created with NIL configuration
//   worklet.start(filename ending .bundle, source: Data) for packed bundles
//   BareIPC created AFTER start
//   reads use the completion API; a pump timer guards missed wakeups
// The JS entry must talk over the injected `BareKit.IPC` global, NOT
// process.stdout (that never reaches Swift).

import BareKit
import SwiftUI

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    weak var ipc: BareIPC?
    var buffer = Data()

    private func log(_ s: String) {
        print("BareSpike: \(s)")
        // BareKit's readable callback fires on ITS thread; SwiftUI observes
        // .spikeLog, so the notification must land on main.
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

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        startWorklet()
        return true
    }

    private func startWorklet() {
        BareWorklet.optimize(forMemory: false)

        // Device builds must load the ios-arm64 bundle; the simulator the
        // -simulator one. (bare-pack --host picks the addon architecture.)
        #if targetEnvironment(simulator)
        let bundleName = "bare-ios-sim"
        #else
        let bundleName = "bare-ios"
        #endif

        guard let bundleURL = Bundle.main.url(forResource: bundleName, withExtension: "bundle"),
              let source = try? String(contentsOf: bundleURL, encoding: .utf8) else {
            log("FATAL: \(bundleName).bundle missing from app bundle — run npm run bundle and rebuild")
            return
        }
        log("bundle loaded: \(bundleName) \(source.utf8.count) bytes")

        let worklet = BareWorklet(configuration: nil)!
        worklet.start("/bare-spike.bundle", source: Data(source.utf8), arguments: [])

        let ipc = BareIPC(worklet: worklet)!
        self.ipc = ipc

        // Completion-based read loop (the official pattern).
        func readLoop() {
            ipc.read { [weak self] data, error in
                guard let self else { return }
                if let data {
                    if data.isEmpty {
                        log("JS side closed the stream")
                        return
                    }
                    buffer.append(data)
                    drainBuffer()
                }
                readLoop()
            }
        }
        readLoop()

        log("worklet started — awaiting boot event")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.send(json: ["cmd": "ping", "n": 1])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.send(json: ["cmd": "net-start"])
        }
    }

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
            log("✅ JS booted")
        case "net":
            let state = event["state"] as? String ?? "?"
            log(state == "ready"
                ? "✅✅ WORKING: Hyperswarm DHT is live (raw sockets OK)\nTopic: \(event["topic"] ?? "…")…"
                : "⚠️ Hyperswarm error: \(event["msg"] ?? "")")
        case "peer":
            log("✅ peer connected: \(event["info"] ?? "")")
        default:
            break
        }
    }
}

@main
struct BareSpikeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    // Status mirror: AppDelegate.log() updates this via the notification.
    @State private var status: String = "Bare spike — starting…"

    var body: some Scene {
        WindowGroup {
            Text(status)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
                .onReceive(NotificationCenter.default.publisher(for: .spikeLog)) { note in
                    status = note.object as? String ?? ""
                }
        }
    }
}

extension Notification.Name {
    static let spikeLog = Notification.Name("spikeLog")
}
