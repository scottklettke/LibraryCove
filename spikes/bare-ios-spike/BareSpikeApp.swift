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

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = "Bare spike — results in spike.log (app container)"
        label.textAlignment = .center
        label.frame = CGRect(x: 20, y: 300, width: 340, height: 60)
        vc.view.addSubview(label)
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = vc
        window?.makeKeyAndVisible()

        startWorklet()
        return true
    }

    private func startWorklet() {
        BareWorklet.optimize(forMemory: false)

        guard let bundleURL = Bundle.main.url(forResource: "bare-ios-sim", withExtension: "bundle"),
              let source = try? String(contentsOf: bundleURL, encoding: .utf8) else {
            log("FATAL: bare-ios-sim.bundle missing or unreadable")
            return
        }
        log("bundle loaded: \(source.utf8.count) bytes")

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
                ? "✅ Hyperswarm ready (raw sockets OK), topic \(event["topic"] ?? "")"
                : "⚠️ Hyperswarm error: \(event["msg"] ?? "")")
        case "peer":
            log("✅ peer connected: \(event["info"] ?? "")")
        default:
            break
        }
    }

    private func log(_ s: String) {
        print("BareSpike: \(s)")
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

@main
struct BareSpikeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { Text("Bare spike") }
    }
}
