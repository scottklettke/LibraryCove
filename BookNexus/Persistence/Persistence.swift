import Foundation
import SwiftData

/// Central persistence layer for BookNexus.
/// Registers all SwiftData @Model types and exposes a shared container.
enum Persistence {
    /// The shared in-memory+disk ModelContainer.
    static var shared: ModelContainer = {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
            ReadingListItem.self, Connection.self, User.self,
        ])

        // Local-only persistence for now. CloudKit-backed stores can be swapped
        // in later once an iCloud container entitlement is configured.
        let config = ModelConfiguration(isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    /// A container for tests / previews backed entirely by memory.
    static var inMemory: ModelContainer = {
        let schema = Schema([
            Book.self, Note.self, ReadingList.self,
            ReadingListItem.self, Connection.self, User.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create in-memory ModelContainer: \(error)")
        }
    }()
}
