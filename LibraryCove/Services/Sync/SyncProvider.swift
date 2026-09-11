import Foundation

/// A single change record used by the sync engine (tombstones included).
struct SyncChange: Codable, Sendable {
    let entity: SyncEntity
    let recordID: String
    let operation: SyncOperation
    var updatedAt: Date
    var deviceID: String
    var payload: [String: String]

    init(
        entity: SyncEntity,
        recordID: String,
        operation: SyncOperation,
        updatedAt: Date = .init(),
        deviceID: String = "",
        payload: [String: String] = [:]
    ) {
        self.entity = entity
        self.recordID = recordID
        self.operation = operation
        self.updatedAt = updatedAt
        self.deviceID = deviceID
        self.payload = payload
    }
}

enum SyncEntity: String, Codable, Sendable {
    case book
    case note
    case readingList
    case readingListItem
    case connection
    case user
}

enum SyncOperation: String, Codable, Sendable {
    case upsert
    case delete
}

/// Pluggable sync provider. iCloud (CloudKit) and self-hosted backends both
/// implement this protocol.
protocol SyncProvider: AnyObject, Sendable {
    var id: String { get }
    func push(_ changes: [SyncChange]) async throws
    func pull(since: Date) async throws -> [SyncChange]
    func createShare(for libraryID: String, participants: [String]) async throws
}

/// A CloudKit-backed provider (implementation pending entitlement/config).
final class CloudKitSyncProvider: SyncProvider {
    let id = "cloudkit"

    func push(_ changes: [SyncChange]) async throws {
        // TODO: CKRecord zone upload
    }

    func pull(since: Date) async throws -> [SyncChange] {
        // TODO: CKQuery fetch since date
        return []
    }

    func createShare(for libraryID: String, participants: [String]) async throws {
        // TODO: CKShare creation for family sharing
    }
}

/// A self-hosted provider that talks to the existing FastAPI backend.
final class SelfHostedSyncProvider: SyncProvider {
    let id = "selfhosted"
    private let baseURL: URL
    private let token: String

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    func push(_ changes: [SyncChange]) async throws {
        // TODO: POST /api/sync/push with JWT
    }

    func pull(since: Date) async throws -> [SyncChange] {
        // TODO: GET /api/sync/pull?since=...
        return []
    }

    func createShare(for libraryID: String, participants: [String]) async throws {
        // TODO: POST /api/libraries/{id}/members
    }
}
