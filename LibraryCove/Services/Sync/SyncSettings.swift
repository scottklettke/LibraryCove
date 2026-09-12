import Foundation

/// Persisted sync provider selection plus the one-time data hand-off used when
/// switching providers.
enum SyncSettings {
    private static let providerKey = "syncProvider"
    private static let snapshotFileName = "pending-sync-migration.zip"

    /// The provider the app should back its store with on next launch.
    /// New installs (no stored choice) default to iCloud Sync — the
    /// recommended mode. The backing store degrades gracefully to local
    /// when no iCloud account is signed in, so the default is safe.
    static var selectedProvider: LibrarySync {
        get {
            guard let raw = UserDefaults.standard.string(forKey: providerKey),
                  let kind = LibrarySync(rawValue: raw) else { return .iCloud }
            return kind
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: providerKey)
        }
    }

    /// Removes the stored provider choice; `selectedProvider` falls back to
    /// its default (.iCloud). Used by "Delete everything and start fresh"
    /// so a full reset behaves like a brand-new install.
    static func resetProvider() {
        UserDefaults.standard.removeObject(forKey: providerKey)
    }

    // MARK: - Migration snapshot

    /// Where a snapshot of the current library is stashed when the provider
    /// changes. The target store imports it on the next launch (see
    /// `SyncCoordinator`), so switching providers moves the data with you.
    static var snapshotURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent(snapshotFileName)
    }

    static var hasPendingSnapshot: Bool {
        FileManager.default.fileExists(atPath: snapshotURL.path)
    }

    /// Stores the exported library for the target provider. Returns false if it
    /// couldn't be written (caller should abort the switch).
    @discardableResult
    static func writeSnapshot(_ data: Data) -> Bool {
        try? FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try data.write(to: snapshotURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func readSnapshot() -> Data? { try? Data(contentsOf: snapshotURL) }

    static func clearSnapshot() {
        try? FileManager.default.removeItem(at: snapshotURL)
    }
}
