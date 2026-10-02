import Foundation

/// Persisted sync state. Provider selection is RETIRED — every value
/// normalizes to the local store (PearsSyncEngine overlays P2P sync).
/// The snapshot mechanism stays: backups/imports remain user-initiated
/// and the pending-migration file is still cleared by resets.
enum SyncSettings {
    private static let providerKey = "syncProvider"

    /// Always the local store. The stored raw value (legacy .iCloud /
    /// .sharedLibrary choices) is ignored, not erased — resetting it adds
    /// nothing since the getter normalizes anyway.
    static var selectedProvider: LibrarySync {
        .localOnly
    }

    /// Legacy no-op: there is no provider choice anymore. Kept for the
    /// reset/delete-everything call sites.
    static func resetProvider() {
        UserDefaults.standard.removeObject(forKey: providerKey)
    }

    // MARK: - Bulk-change window (legacy, now inert)

    private static let lastBulkChangeKey = "lastBulkChangeAt"

    static var lastBulkChangeAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: lastBulkChangeKey)
            return t == 0 ? nil : Date(timeIntervalSince1970: t)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: lastBulkChangeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastBulkChangeKey)
            }
        }
    }

    static func markBulkChange(now: Date = Date()) {
        lastBulkChangeAt = now
    }

    // MARK: - Migration snapshot

    /// Where an export/import hand-off is stashed. Only used by
    /// SyncCoordinator's pending-pour path now.
    static var snapshotURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("pending-sync-migration.zip")
    }

    static var hasPendingSnapshot: Bool {
        FileManager.default.fileExists(atPath: snapshotURL.path)
    }

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
