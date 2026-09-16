import CloudKit
import Foundation

/// Role of a participant in a shared library. Maps to CloudKit share
/// permissions:
/// - admin: full control — edit anything, share links, stop sharing, and
///   change other participants' roles.
/// - editor: edit anything and share links, but cannot stop sharing or
///   manage roles.
/// - guest: view only — no edits, no sharing.
enum ShareParticipantRole: String, Codable, CaseIterable {
    case admin
    case editor
    case guest

    var displayName: String {
        switch self {
        case .admin: return "Admin"
        case .editor: return "Editor"
        case .guest: return "Guest"
        }
    }

    /// CloudKit participation permission for this role (admin maps to
    /// read-write too — CloudKit has no "manage participants" bit; admin
    /// powers are enforced by the app over a role record).
    var ckPermission: CKShare.ParticipantPermission {
        switch self {
        case .admin, .editor: return .readWrite
        case .guest: return .readOnly
        }
    }

    static func from(_ permission: CKShare.ParticipantPermission) -> ShareParticipantRole {
        permission == .readOnly ? .guest : .editor
    }
}

/// Roles are stored per library + participant record name in UserDefaults
/// (the CKShare itself cannot carry arbitrary role metadata that non-owner
/// devices can read before joining).
enum ShareRoleStore {
    private static let d = UserDefaults.standard

    static func role(libraryID: String, participantRecordName: String) -> ShareParticipantRole {
        ShareParticipantRole(rawValue: d.string(
            forKey: "sharedLibrary.\(libraryID).role.\(participantRecordName)") ?? "") ?? .editor
    }

    static func setRole(_ role: ShareParticipantRole, libraryID: String,
                        participantRecordName: String) {
        d.set(role.rawValue, forKey: "sharedLibrary.\(libraryID).role.\(participantRecordName)")
    }

    static func allRoles(libraryID: String) -> [String: ShareParticipantRole] {
        let prefix = "sharedLibrary.\(libraryID).role."
        var result: [String: ShareParticipantRole] = [:]
        for key in d.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            if let role = ShareParticipantRole(rawValue: d.string(forKey: key) ?? "") {
                result[String(key.dropFirst(prefix.count))] = role
            }
        }
        return result
    }
}

/// Wire-format structs for the shared library. These travel inside CKRecords
/// (`SharedLibraryRecord` codec) and are the neutral form between the cloud
/// zone and the local SwiftData mirror store. Kept field-identical to the
/// `@Model` classes so round-tripping is lossless.
struct SharedBook: Codable, Equatable {
    var id: String
    var title: String = ""
    var authors: [String] = []
    var isbn: String?
    var publicationYear: Int?
    var tags: [String] = []
    var kind: String = ""
    var shelves: [String] = []
    /// Only remote (http(s)) cover references travel in the record. Image
    /// bytes travel separately as a CKAsset (see the codec) — data: URLs are
    var coverImageURL: String?
    /// SHA256 of the cover bytes the sender had — lets the receiver detect
    /// cover-only changes even though bytes travel as a CKAsset, not a field.
    var coverFingerprint: String?
    var publisher: String?
    var pageCount: Int?
    var bookDescription: String?
    var descriptionSource: String?
    /// Open Library work key — internal enrichment data, shared like any other
    /// field so a participant's app can fetch descriptions deterministically.
    var olKey: String?
    var series: String?
    var genre: String?
    var language: String?
    var physicalLocation: String?
    var status: String = "to-read"
    var acquiredDate: Date?
    var purchasePrice: Double?
    var rating: Int?
    var loanedTo: String?
    var loanedDate: Date?
    var ownerID: String?
    var sharedLibraryID: String?
    var isPersonal: Bool = true
    var createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    var updatedAt: Date = Date(timeIntervalSinceReferenceDate: 0)
}

struct SharedNote: Codable, Equatable {
    var id: String
    var bookID: String
    var userID: String = ""
    var title: String?
    var content: String = ""
    var noteType: String = "general"
    var visibility: String = "private"
    var sharedLibraryID: String?
    var pageReference: String?
    var mentions: [String] = []
    var createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    var updatedAt: Date = Date(timeIntervalSinceReferenceDate: 0)
}

struct SharedReadingList: Codable, Equatable {
    var id: String
    var name: String = ""
    var listDescription: String?
    var ownerID: String = ""
    var sharedLibraryID: String?
    var isPrivate: Bool = true
    var createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    var updatedAt: Date = Date(timeIntervalSinceReferenceDate: 0)
}

struct SharedReadingListItem: Codable, Equatable {
    var id: String
    var listID: String
    var bookID: String
    var addedByID: String?
    var position: Int = 0
    var priority: String = "normal"
    var targetDate: Date?
    var createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)
}

/// One pull/push batch in DTO form, tagged by record type so the mirror can
/// apply deletes before upserts and repair relationships by ID.
struct SharedRecordChange: Equatable {
    enum Kind: Equatable {
        case book(SharedBook)
        case note(SharedNote)
        case readingList(SharedReadingList)
        case readingListItem(SharedReadingListItem)
        case deleted(recordName: String)
    }

    var kind: Kind

    /// Stable CloudKit record name ("<Type>/<uuid>") the change refers to.
    var recordName: String {
        switch kind {
        case .book(let v): return SharedLibraryRecord.recordName(type: .book, id: v.id)
        case .note(let v): return SharedLibraryRecord.recordName(type: .note, id: v.id)
        case .readingList(let v): return SharedLibraryRecord.recordName(type: .readingList, id: v.id)
        case .readingListItem(let v): return SharedLibraryRecord.recordName(type: .readingListItem, id: v.id)
        case .deleted(let name): return name
        }
    }
}
