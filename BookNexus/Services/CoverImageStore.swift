import Foundation

/// Stores cover images as real JPEG files on the filesystem instead of
/// embedding them in the database or the export JSON.
///
/// Files live in `Application Support/covers/<bookID>.jpg` (Application Support,
/// not Caches, so the system never purges them) and travel inside exports as
/// `covers/<bookID>.jpg` zip entries under the same name.
enum CoverImageStore {
    static let zipPrefix = "covers/"

    /// Application Support/covers, created on demand.
    static var directoryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent(zipPrefix, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// A safe filename for a book id (IDs are UUIDs; sanitise anyway so an
    /// odd id can't escape the covers directory).
    private static func safeName(forBookID id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }

    /// Absolute local file URL for a book's cover on disk.
    static func fileURL(forBookID id: String) -> URL {
        directoryURL.appendingPathComponent(safeName(forBookID: id)).appendingPathExtension("jpg")
    }

    /// The `covers/<bookID>.jpg` entry name used inside an export zip — matches
    /// what `fileURL` produces so bundling and restoring line up.
    static func zipEntryName(forBookID id: String) -> String {
        zipPrefix + fileURL(forBookID: id).lastPathComponent
    }

    @discardableResult
    static func save(_ data: Data, forBookID id: String) -> Bool {
        do {
            try data.write(to: fileURL(forBookID: id), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func data(forBookID id: String) -> Data? {
        try? Data(contentsOf: fileURL(forBookID: id))
    }

    static func delete(forBookID id: String) {
        try? FileManager.default.removeItem(at: fileURL(forBookID: id))
    }

    static func removeAll() {
        guard let contents = try? FileManager.default
            .contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else { return }
        for file in contents {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Decodes a `data:image/...;base64,` URL back to image bytes.
    static func data(fromDataURL urlString: String) -> Data? {
        guard urlString.hasPrefix("data:"),
              let comma = urlString.firstIndex(of: ",") else { return nil }
        let base64 = urlString[urlString.index(after: comma)...]
        return Data(base64Encoded: String(base64))
    }

    /// Resolves any stored cover form (local file, data URL) to image bytes.
    /// Remote URLs return `nil` — they have no local bytes yet.
    static func localData(forCover cover: String?) -> Data? {
        guard let cover else { return nil }
        if cover.hasPrefix("file://") {
            guard let url = URL(string: cover) else { return nil }
            return try? Data(contentsOf: url)
        }
        if cover.hasPrefix("data:") {
            return data(fromDataURL: cover)
        }
        return nil
    }
}
