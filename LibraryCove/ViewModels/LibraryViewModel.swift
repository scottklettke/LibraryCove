import Foundation
import SwiftData

/// LibraryViewModel — exposes queryable collections and sync operations.
@MainActor
final class LibraryViewModel {
    private let container: ModelContainer
    private let provider: SyncProvider?

    init(container: ModelContainer, provider: SyncProvider? = nil) {
        self.container = container
        self.provider = provider
    }

    /// Pull remote changes into the local store.
    func sync() async throws {
        guard let provider else { return }
        let changes = try await provider.pull(since: .distantPast)
        let context = container.mainContext
        for change in changes where change.operation == .upsert {
            // TODO: apply payload to matching model
            _ = context
        }
    }
}
