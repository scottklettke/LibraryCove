import Foundation
import SwiftData

/// Central multi-library plumbing: the active library, its id, and the
/// one-time migration of pre-multi-library rows into the default library.
@MainActor
enum LibraryScope {
    /// The id used for rows created before multi-library support existed
    /// (they migrate into the first/default library, which keeps this id).
    static let defaultLibraryID = "library-default"

    /// All libraries, oldest first.
    static func all(context: ModelContext) -> [Library] {
        let descriptor = FetchDescriptor<Library>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The active library, creating the default one when absent (first
    /// launch or legacy store). Never nil after `migrateIfNeeded` runs.
    static func active(context: ModelContext) -> Library? {
        if let active = (try? context.fetch(FetchDescriptor<Library>(
            predicate: #Predicate { $0.isActive }
        )))?.first {
            return active
        }
        return ensureDefault(context: context)
    }

    /// Convenience: the active library's id (creates the default if absent).
    static func activeID(context: ModelContext) -> String {
        active(context: context)?.id ?? defaultLibraryID
    }

    /// The active library's display name (defaults to the classic
    /// "<member>'s Library" when the user hasn't named it).
    static func activeName(context: ModelContext, memberName: String) -> String {
        guard let library = active(context: context), !library.name.isEmpty else {
            return SharedLibrarySettings.defaultShareTitle(for: memberName)
        }
        return library.name
    }

    /// A fetch descriptor for the ACTIVE library's books (helper for view
    /// layer call sites).
    static func activeBooksDescriptor(context: ModelContext) -> FetchDescriptor<Book> {
        let id = activeID(context: context)
        return FetchDescriptor<Book>(predicate: #Predicate { $0.libraryID == id })
    }

    /// Marks `library` as the only active one (CloudKit syncs the flag).
    static func activate(_ library: Library, context: ModelContext) {
        for other in all(context: context) where other.id != library.id {
            other.isActive = false
        }
        library.isActive = true
        try? context.save()
    }

    /// Creates a library (and makes it active when requested).
    @discardableResult
    static func create(name: String, makeActive: Bool, context: ModelContext) -> Library {
        let library = Library(name: name, isActive: false)
        context.insert(library)
        if makeActive {
            activate(library, context: context)
        } else {
            try? context.save()
        }
        return library
    }

    /// Deletes a library and ALL of its content (books, notes, lists, items,
    /// connections). Members (User rows) are shared across libraries and are
    /// NOT touched. If the deleted library was active, the oldest remaining
    /// library becomes active (or a fresh default is created).
    static func delete(_ library: Library, context: ModelContext) {
        let id = library.id
        let wasActive = library.isActive
        context.delete(library)

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
                activate(next, context: context)
            } else {
                _ = ensureDefault(context: context)
            }
        }
    }

    /// One-time launch migration: ensures a default library exists and tags
    /// every legacy row (libraryID == nil) with it. Idempotent.
    static func migrateIfNeeded(context: ModelContext) {
        if all(context: context).isEmpty {
            let defaultLibrary = Library(id: defaultLibraryID, name: "", isActive: true)
            context.insert(defaultLibrary)
            try? context.save()
        }
        guard let defaultLibrary = (try? context.fetch(FetchDescriptor<Library>(
            predicate: #Predicate { $0.id == defaultLibraryID }
        )))?.first else {
            // A default exists under another id (created elsewhere); legacy
            // rows attach to the oldest library.
            let oldest = all(context: context).first
            tagLegacyRows(context: context, libraryID: oldest?.id ?? defaultLibraryID)
            return
        }
        if !defaultLibrary.isActive {
            activate(defaultLibrary, context: context)
        }
        tagLegacyRows(context: context, libraryID: defaultLibrary.id)
    }

    private static func tagLegacyRows(context: ModelContext, libraryID: String) {
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

    private static func ensureDefault(context: ModelContext) -> Library? {
        if let existing = all(context: context).first {
            activate(existing, context: context)
            return existing
        }
        let library = Library(id: defaultLibraryID, name: "", isActive: true)
        context.insert(library)
        try? context.save()
        return library
    }
}
