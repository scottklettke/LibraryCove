import Foundation
import SwiftData

/// RETIRED with iCloud sharing. The call sites that remain (backup
/// replace-import, factory reset) previously tore down CKShare state;
/// there is no CKShare state anymore. Pears revocation is handled by
/// the PearsSyncEngine (token refusal / key rotation).
enum SharedLibraryCoordinator {
    /// No-op: nothing to discard without a CKShare zone.
    static func discardSharedContent() async throws {}

    /// No-op: the local store IS the only store.
    @MainActor
    static func privateContextAfterDiscard() throws -> ModelContext {
        Persistence.shared.mainContext
    }
}

extension SharedLibraryCoordinator {
    /// No-op: no CKShare state exists to discard.
    static func discardAllSharedContent() async {}
}
