import Foundation
import SwiftData

/// Manages named library backups: zipped `LibraryDataService.export`
/// archives stored in the app's iCloud Drive container
/// (`iCloud.com.librarycove.app`, Documents/Backups). Files are named
/// `<library> yyyy-MM-dd (<bookCount> books) <n>.zip` where `<library>` is
/// the active library's display name and `<n>` is a same-day sequence
/// number starting at 1 (omitted for the first backup of a day). The
/// library name tells the user which library a backup came from when
/// several exist.
///
/// Backups sync between the account's devices: the container is an iCloud
/// Drive (ubiquity) container, so macOS/iOS propagate new, renamed, and
/// deleted files automatically. Locally the files appear under the
/// same-named folder in Files → iCloud Drive → LibraryCove.
enum BackupStore {
    /// The iCloud Drive container root. Nil when iCloud Drive is
    /// unavailable (no account, or the container hasn't materialized yet).
    static var ubiquityRoot: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier:
            SwiftDataiCloudSync.containerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    /// Where backups live: the container's Documents/Backups. Falls back
    /// to a local Application Support folder ONLY when the ubiquity
    /// container is unavailable (offline/no account) so a backup is never
    /// lost — the next successful container probe still lists those files
    /// once the folder is re-pointed there is NOT attempted; the local
    /// fallback keeps this session's saves browsable.
    static var directory: URL {
        if let root = ubiquityRoot {
            return root.appendingPathComponent("Backups", isDirectory: true)
        }
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

    /// Backups, newest first. One synced set — no per-provider companions.
    static func list() -> [Item] {
        let fm = FileManager.default
        let dir = directory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
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

    /// Alias kept for call sites that want the "everything" semantics;
    /// there is exactly one (synced) set now.
    static func listAll() -> [Item] {
        list()
    }

    /// Saves `data` as a backup named by the library it came from, today's
    /// date, the book count, and a same-day sequence number. Returns the
    /// file name.
    @discardableResult
    static func save(data: Data, bookCount: Int, libraryName: String, date: Date = Date()) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        let library = sanitizedLibraryName(libraryName)
        // Sequence: how many backups already exist for today's date for
        // THIS library (or any library when this one is unnamed)? Counted
        // per library so same-day backups of different libraries each get
        // their own 1, 2, 3… run.
        let existing = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let marker = " \(day) ("
        let sameDay = existing.filter {
            library.isEmpty
                ? $0.lastPathComponent.hasPrefix(marker.trimmingCharacters(in: .whitespaces))
                : $0.lastPathComponent.hasPrefix(library + marker)
        }.count
        let sequence = sameDay + 1
        let books = bookCount == 1 ? "1 book" : "\(bookCount) books"
        let stem = "\(day) (\(books))"
        let base = library.isEmpty
            ? (sequence == 1 ? stem : "\(stem) \(sequence)")
            : (sequence == 1 ? "\(library) \(stem)" : "\(library) \(stem) \(sequence)")
        let url = directory.appendingPathComponent(base).appendingPathExtension("zip")
        // Defensive: never overwrite (sequence math should prevent it).
        var finalURL = url
        var bump = sequence
        while fm.fileExists(atPath: finalURL.path) {
            bump += 1
            finalURL = directory.appendingPathComponent(library.isEmpty
                ? "\(stem) \(bump)"
                : "\(library) \(stem) \(bump)").appendingPathExtension("zip")
        }
        try data.write(to: finalURL, options: .atomic)
        return finalURL.deletingPathExtension().lastPathComponent
    }

    /// Makes a library name safe for a filename: path separators stripped,
    /// trimmed, capped. Empty (or fully stripped) names yield "" — the
    /// caller falls back to the date-only name shape.
    private static func sanitizedLibraryName(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 40 else { return cleaned }
        return String(cleaned.prefix(40))
    }

    static func delete(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func deleteAll() {
        // Backups sync via the iCloud container; removing the folder
        // propagates the deletions to the account's other devices.
        try? FileManager.default.removeItem(at: directory)
    }

    /// Legacy cleanup: the retired per-provider companion folders
    /// (Backups-local / Backups-cloud). Their contents predate iCloud
    /// syncing — merge them into the synced folder once, so nothing a user
    /// made under the old two-folder model is stranded on-device.
    static func migrateLegacyCompanionsIfNeeded() {
        let fm = FileManager.default
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let legacy = [
            base.appendingPathComponent("Backups-local", isDirectory: true),
            base.appendingPathComponent("Backups-cloud", isDirectory: true),
        ]
        let dest = directory
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for folder in legacy {
            guard directoryExists(at: folder) else { continue }
            if let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "zip" {
                    let target = dest.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: target.path) {
                        try? fm.moveItem(at: file, to: target)
                    }
                }
            }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    static func directoryExists(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
