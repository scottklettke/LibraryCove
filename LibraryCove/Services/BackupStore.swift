import Foundation
import SwiftData

/// Manages named library backups: zipped `LibraryDataService.export`
/// archives stored under Application Support/Backups. Files are named
/// `yyyy-MM-dd (<bookCount> books) <n>.zip` where `<n>` is a same-day
/// sequence number starting at 1 (omitted for the first backup of a day).
///
/// Backups live on-device only. The "moved between local and iCloud like
/// the library" behavior comes from BackupStore mirroring the backup
/// directory between `default.store`'s and `default-cloud.store`'s
/// companion folders whenever the provider switches.
enum BackupStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("Backups", isDirectory: true)
    }

    struct Item: Identifiable {
        let url: URL
        let name: String
        let size: Int64
        let date: Date
        var id: String { name }
        var sizeText: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
    }

    /// All backups, newest first.
    static func list() -> [Item] {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return contents
            .filter { $0.pathExtension == "zip" }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return Item(url: url,
                            name: url.deletingPathExtension().lastPathComponent,
                            size: Int64(values?.fileSize ?? 0),
                            date: values?.contentModificationDate ?? Date.distantPast)
            }
            .sorted { $0.date > $1.date }
    }

    /// Saves `data` as a backup named by today's date, the book count, and a
    /// same-day sequence number. Returns the file name.
    @discardableResult
    static func save(data: Data, bookCount: Int, date: Date = Date()) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        // Sequence: how many backups already exist for today's date?
        let existing = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let sameDay = existing.filter { $0.lastPathComponent.hasPrefix("\(day) (") }.count
        let sequence = sameDay + 1
        let books = bookCount == 1 ? "1 book" : "\(bookCount) books"
        let base = sequence == 1 ? "\(day) (\(books))" : "\(day) (\(books)) \(sequence)"
        let url = directory.appendingPathComponent(base).appendingPathExtension("zip")
        // Defensive: never overwrite (sequence math should prevent it).
        var finalURL = url
        var bump = sequence
        while fm.fileExists(atPath: finalURL.path) {
            bump += 1
            finalURL = directory.appendingPathComponent("\(day) (\(books)) \(bump)").appendingPathExtension("zip")
        }
        try data.write(to: finalURL, options: .atomic)
        return finalURL.deletingPathExtension().lastPathComponent
    }

    static func delete(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func deleteAll() {
        // Remove the live folder AND both parked companions so a provider
        // switch can't resurrect "deleted" backups from Backups-local or
        // Backups-cloud.
        for url in [directory, localBackupDirectory, cloudBackupDirectory] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Provider-switch mirroring

    /// Companion backup directories for the local and iCloud stores. On a
    /// provider switch the whole `Backups` folder is MOVED (renamed) between
    /// these two, mirroring how the library itself travels between
    /// `default.store` and `default-cloud.store` — so backups follow the
    /// library wherever it lives.
    static var localBackupDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("Backups-local", isDirectory: true)
    }

    static var cloudBackupDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("Backups-cloud", isDirectory: true)
    }

    /// Called BEFORE a provider switch snapshot is poured into the target
    /// store: carries the backups along with the library. The live
    /// `directory` moves to the destination provider's companion folder, and
    /// the destination's companion (if any) becomes the live one — so
    /// switching to iCloud shows the backups last seen under iCloud, and
    /// switching back to Local restores the local set. Nothing is deleted.
    @MainActor
    static func mirrorForProviderSwitch(to newProvider: LibrarySync) {
        let fm = FileManager.default
        guard directoryExists(at: directory) else { return }
        let target: URL = newProvider == .iCloud ? cloudBackupDirectory : localBackupDirectory
        // Park the current set under the outgoing provider's companion.
        let outgoing: URL = newProvider == .iCloud ? localBackupDirectory : cloudBackupDirectory
        try? fm.createDirectory(at: outgoing, withIntermediateDirectories: true)
        // Move current contents into the outgoing companion (merge; skip name clashes).
        if let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files {
                let dest = outgoing.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: file, to: dest)
                }
            }
        }
        // Bring the destination companion's contents into the live folder.
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let files = try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil) {
            for file in files {
                let dest = directory.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: file, to: dest)
                }
            }
        }
    }

    static func directoryExists(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
