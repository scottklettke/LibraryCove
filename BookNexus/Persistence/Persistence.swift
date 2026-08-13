import Foundation
import SwiftData

/// Central persistence layer for BookNexus.
/// Registers all SwiftData @Model types and exposes the shared container.
///
/// The backing store depends on the selected sync provider (`SyncSettings`):
/// local-only by default, iCloud (CloudKit) when the user opts in. Because the
/// container is bound at launch, provider switches apply on relaunch.
enum Persistence {
    /// The shared on-device ModelContainer (local or CloudKit-backed).
    static var shared: ModelContainer =
        SyncStoreRegistry.makeContainer(for: SyncSettings.selectedProvider)

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
