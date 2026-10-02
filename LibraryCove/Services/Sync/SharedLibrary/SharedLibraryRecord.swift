import Foundation

/// Wire codec for the Shared* DTOs.
///
/// Historical note: this was a CKRecord codec for the iCloud shared
/// zone. The byte format it defined — JSONEncoder with
/// .millisecondsSince1970 dates and .sortedKeys, stored as an opaque
/// payload blob keyed by a stable record name — is now the PEARS wire
/// format: the same bytes travel in Hyperdrive files (books/<id>.json,
/// covers/<id>) instead of CKRecords. The encoder settings are the
/// contract; do not change them.
enum SharedLibraryRecord {
    static let schemaVersion = 1

    enum RecordType: String {
        case book = "CDBook"
        case note = "CDNote"
        case readingList = "CDReadingList"
        case readingListItem = "CDReadingListItem"

        var rank: Int {
            switch self {
            case .book: return 0
            case .note: return 1
            case .readingList: return 2
            case .readingListItem: return 3
            }
        }

        init?(recordName: String) {
            guard let idPart = recordName.split(separator: "/").first else { return nil }
            self.init(rawValue: String(idPart))
        }
    }

    struct Field {
        static let payload = "payload"
        static let schema = "schema"
    }

    // MARK: - Record names

    static func recordName(type: RecordType, id: String) -> String {
        "\(type.rawValue)/\(id)"
    }

    static func id(fromRecordName name: String) -> String? {
        name.split(separator: "/").last.map(String.init)
    }

    // MARK: - Payload codec (the wire format)

    /// The canonical bytes for a DTO payload. Pears stores these VERBATIM
    /// (opaque) — the encoder settings ARE the compatibility contract.
    static func payloadData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    static func decodePayload<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(type, from: data)
    }
}
