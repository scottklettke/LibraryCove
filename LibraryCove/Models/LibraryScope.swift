import Foundation
import SwiftData
import os.log

/// Diagnostics for multi-library issues (fetch/insert mismatches on device).
private let libraryLog = Logger(subsystem: "com.librarycove.app", category: "LibraryScope")

/// A user-created library: a named collection of books. The LIST of
/// libraries is stored as JSON (Application Support/libraries.json) rather
/// than SwiftData/CloudKit: the Library entity's rows failed to persist
/// reliably through the CloudKit schema on some devices (created rows
/// vanished across launches), while content isolation only needs the id —
/// which lives on the rows themselves.
struct LibraryInfo: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var isActive: Bool
    var createdAt: Date
}

/// Central multi-library plumbing. Observable so views re-render when the
/// active library changes (switch/rename/create/delete).
@MainActor
final class LibraryScope: ObservableObject {
    static let shared = LibraryScope()

    /// Posted after any registry change (create/activate/rename/delete).
    /// Views observe it to refresh the active-library name.
    static let librariesChangedNotification = Notification.Name("librariesChanged")

    /// The id used for rows created before multi-library support existed
    /// (they migrate into the first/default library, which keeps this id).
    static let defaultLibraryID = "library-default"

    /// The ACTIVE library's id — @Published so observing views (library
    /// grid, settings) re-render the moment it changes.
    @Published private(set) var activeID: String = defaultLibraryID

    private let registryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("libraries.json")
    }()

    /// Test seam: the registry file location (tests delete it between runs).
    var registryURLForTesting: URL { registryURL }

    private init() {
        activeID = loadRegistry().first(where: { $0.isActive })?.id ?? Self.defaultLibraryID
    }

    /// All libraries, oldest first.
    func all(context: ModelContext) -> [LibraryInfo] {
        let result = loadRegistry()
        libraryLog.debug("LibraryScope.all -> \(result.count) libraries")
        return result
    }

    /// The active library, creating the default one when absent.
    func active(context: ModelContext) -> LibraryInfo? {
        if let active = all(context: context).first(where: { $0.id == activeID }) {
            return active
        }
        return ensureDefault(context: context)
    }

    /// Convenience: the active library's id (creates the default if absent).
    func activeID(context: ModelContext) -> String {
        if all(context: context).contains(where: { $0.id == activeID }) {
            return activeID
        }
        return ensureDefault(context: context)?.id ?? Self.defaultLibraryID
    }

    /// The active library's display name (defaults to the classic
    /// "<member>'s Library" when the user hasn't named it).
    func activeName(context: ModelContext, memberName: String) -> String {
        guard let library = active(context: context), !library.name.isEmpty else {
            return SharedLibrarySettings.defaultShareTitle(for: memberName)
        }
        return library.name
    }

    /// Marks `library` as the only active one.
    func activate(_ library: LibraryInfo, context: ModelContext) {
        var registry = loadRegistry().map { info in
            LibraryInfo(id: info.id, name: info.name,
                        isActive: info.id == library.id, createdAt: info.createdAt)
        }
        if !registry.contains(where: { $0.id == library.id }) {
            registry.append(library)
        }
        saveRegistry(registry)
        activeID = library.id
        notifyChanged()
    }

    /// Creates a library (and makes it active when requested).
    /// - Throws: the underlying save error, so UI can surface it.
    @discardableResult
    func create(name: String, makeActive: Bool, context: ModelContext) throws -> LibraryInfo {
        let library = LibraryInfo(id: UUID().uuidString, name: name,
                                  isActive: false, createdAt: Date())
        var registry = all(context: context)
        registry.append(library)
        if makeActive {
            for i in registry.indices { registry[i].isActive = registry[i].id == library.id }
        }
        do {
            try saveRegistry(registry)
            libraryLog.notice("LibraryScope.create saved")
        } catch {
            libraryLog.error("LibraryScope.create save FAILED")
            throw error
        }
        if makeActive {
            activeID = library.id
        }
        notifyChanged()
        return library
    }

    /// Deletes a library and ALL of its content. Members (User rows) are
    /// shared across libraries and are NOT touched. If the deleted library
    /// was active, the oldest remaining library becomes active.
    func delete(_ library: LibraryInfo, context: ModelContext) {
        let id = library.id
        let wasActive = id == activeID

        saveRegistry(all(context: context).filter { $0.id != id })

        for row in (try? context.fetch(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == id }
        ))) ?? [] { context.delete(row) }
        for row in (try? context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.libraryID == id }
        ))) ?? [] { context.delete(row) }
        for row in (try? context.fetch(FetchDescriptor<ReadingList>(
            predicate: #Predicate { $0.libraryID == id }
        ))) ?? [] { context.delete(row) }
        for row in (try? context.fetch(FetchDescriptor<ReadingListItem>(
            predicate: #Predicate { $0.libraryID == id }
        ))) ?? [] { context.delete(row) }
        for row in (try? context.fetch(FetchDescriptor<Connection>(
            predicate: #Predicate { $0.libraryID == id }
        ))) ?? [] { context.delete(row) }
        try? context.save()

        if wasActive {
            let remaining = all(context: context)
            if let next = remaining.first {
                activeID = next.id
                var registry = loadRegistry()
                for i in registry.indices { registry[i].isActive = registry[i].id == next.id }
                saveRegistry(registry)
            } else {
                _ = ensureDefault(context: context)
            }
        }
        notifyChanged()
    }

    /// One-time launch migration: ensures a default library exists and tags
    /// every legacy row (libraryID == nil) with it. Idempotent.
    func migrateIfNeeded(context: ModelContext) {
        var registry = loadRegistry()
        if registry.isEmpty {
            registry = [LibraryInfo(id: Self.defaultLibraryID, name: "",
                                    isActive: true, createdAt: Date(timeIntervalSinceReferenceDate: 0))]
            saveRegistry(registry)
        }
        guard let defaultLibrary = registry.first(where: { $0.id == Self.defaultLibraryID }) else {
            let oldest = registry.first
            tagLegacyRows(context: context, libraryID: oldest?.id ?? Self.defaultLibraryID)
            activeID = oldest?.id ?? Self.defaultLibraryID
            return
        }
        if !registry.contains(where: { $0.isActive }) {
            for i in registry.indices { registry[i].isActive = registry[i].id == defaultLibrary.id }
            saveRegistry(registry)
        }
        activeID = registry.first(where: { $0.isActive })?.id ?? defaultLibrary.id
        tagLegacyRows(context: context, libraryID: defaultLibrary.id)
    }

    /// Remove every library (Delete everything) — content rows are cleared
    /// separately by the caller.
    func deleteAllLibraries() {
        saveRegistry([])
        activeID = Self.defaultLibraryID
        notifyChanged()
    }

    /// Re-ids a library entry (used when a joined share maps to a derived
    /// share-scoped id). Content rows must be re-tagged by the caller.
    func renameIDForSharing(from oldID: String, to newID: String, context: ModelContext) {
        var registry = loadRegistry()
        guard let idx = registry.firstIndex(where: { $0.id == oldID }) else { return }
        registry[idx].id = newID
        saveRegistry(registry)
        if activeID == oldID { activeID = newID }
        for row in (try? context.fetch(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == oldID }
        ))) ?? [] { row.libraryID = newID }
        for row in (try? context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.libraryID == oldID }
        ))) ?? [] { row.libraryID = newID }
        for row in (try? context.fetch(FetchDescriptor<ReadingList>(
            predicate: #Predicate { $0.libraryID == oldID }
        ))) ?? [] { row.libraryID = newID }
        for row in (try? context.fetch(FetchDescriptor<ReadingListItem>(
            predicate: #Predicate { $0.libraryID == oldID }
        ))) ?? [] { row.libraryID = newID }
        for row in (try? context.fetch(FetchDescriptor<Connection>(
            predicate: #Predicate { $0.libraryID == oldID }
        ))) ?? [] { row.libraryID = newID }
        try? context.save()
        notifyChanged()
    }

    /// Renames a library (by id). No-op when absent.
    func rename(id: String, to name: String, context: ModelContext) {
        var registry = loadRegistry()
        guard let idx = registry.firstIndex(where: { $0.id == id }) else { return }
        registry[idx].name = name
        saveRegistry(registry)
        notifyChanged()
    }

    /// A fetch descriptor for the ACTIVE library's books (helper for view
    /// layer call sites).
    func activeBooksDescriptor(context: ModelContext) -> FetchDescriptor<Book> {
        let id = activeID(context: context)
        return FetchDescriptor<Book>(predicate: #Predicate { $0.libraryID == id })
    }

    private func ensureDefault(context: ModelContext) -> LibraryInfo? {
        var registry = loadRegistry()
        if let existing = registry.first {
            if !registry.contains(where: { $0.isActive }) {
                for i in registry.indices { registry[i].isActive = registry[i].id == existing.id }
                saveRegistry(registry)
            }
            activeID = existing.id
            return existing
        }
        let library = LibraryInfo(id: Self.defaultLibraryID, name: "",
                                  isActive: true, createdAt: Date(timeIntervalSinceReferenceDate: 0))
        registry.append(library)
        saveRegistry(registry)
        activeID = library.id
        return library
    }

    private func tagLegacyRows(context: ModelContext, libraryID: String) {
        var changed = false
        for row in (try? context.fetch(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == nil }
        ))) ?? [] { row.libraryID = libraryID; changed = true }
        for row in (try? context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.libraryID == nil }
        ))) ?? [] { row.libraryID = libraryID; changed = true }
        for row in (try? context.fetch(FetchDescriptor<ReadingList>(
            predicate: #Predicate { $0.libraryID == nil }
        ))) ?? [] { row.libraryID = libraryID; changed = true }
        for row in (try? context.fetch(FetchDescriptor<ReadingListItem>(
            predicate: #Predicate { $0.libraryID == nil }
        ))) ?? [] { row.libraryID = libraryID; changed = true }
        for row in (try? context.fetch(FetchDescriptor<Connection>(
            predicate: #Predicate { $0.libraryID == nil }
        ))) ?? [] { row.libraryID = libraryID; changed = true }
        if changed { try? context.save() }
    }

    // MARK: - JSON registry

    private func loadRegistry() -> [LibraryInfo] {
        guard let data = try? Data(contentsOf: registryURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LibraryInfo].self, from: data)) ?? []
    }

    private func saveRegistry(_ libraries: [LibraryInfo]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(libraries)
            try data.write(to: registryURL, options: .atomic)
        } catch {
            libraryLog.error("LibraryScope registry save FAILED")
        }
        notifyChanged()
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.librariesChangedNotification, object: nil)
    }
}