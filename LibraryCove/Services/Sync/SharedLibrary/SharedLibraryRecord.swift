import CloudKit
import Foundation

/// Codec between CKRecords in the shared zone and the `Shared*` DTOs.
///
/// Record names are `<Type>/<uuid>` so a single record encodes both its model
/// type and identity; deletes surface only the record name. Every payload is
/// one JSON blob under `SharedLibraryRecord.Field.payload` plus a schema
/// version field — new model fields get added to the DTO + version bump, and
/// older readers still decode the subset they know (Codable ignores missing
/// keys that are optional; non-optional new fields must default in `init`).
enum SharedLibraryRecord {
    /// Bump when a DTO gains a field older builds can't decode. Old builds
    /// that see a newer version skip the record (logged) instead of crashing.
    static let schemaVersion: Int64 = 1

    enum RecordType: String, CaseIterable {
        case book = "BNBook"
        case note = "BNNote"
        case readingList = "BNReadingList"
        case readingListItem = "BNReadingListItem"

        /// CloudKit record-type strings must not collide with the metadata
        /// records CloudKit itself creates in shared zones (prefix `cloudKit.share`).
        var prefix: String { rawValue + "/" }

        init?(recordName: String) {
            guard let type = RecordType.allCases.first(where: { recordName.hasPrefix($0.prefix) }) else { return nil }
            self = type
        }
    }

    /// Fixed-name record carrying the share LINK's default role ("what you
    /// get when you open the link"): recordName "roles", one JSON payload
    /// `{"role": "admin|editor|guest"}`. Written by the owner at
    /// makeShare/beginShare and updated by admins via setRole; fetched by
    /// the joiner in finishJoin/sync so roles travel to devices that never
    /// saw the assigning session (both admin and editor map to .readWrite
    /// on the CKShare, so the share permission alone cannot distinguish
    /// them).
    static let rolesRecordName = "roles"

    static func encodeLinkRole(_ role: ShareParticipantRole, inZoneWith zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "BNRoles",
                              recordID: CKRecord.ID(recordName: rolesRecordName, zoneID: zoneID))
        let payload = try! JSONEncoder().encode(["role": role.rawValue])
        record[Field.payload] = payload
        record[Field.schema] = schemaVersion
        return record
    }

    static func decodeLinkRole(from record: CKRecord) -> ShareParticipantRole? {
        guard let data = record[Field.payload] as? Data,
              let json = try? JSONDecoder().decode([String: String].self, from: data),
              let raw = json["role"]
        else { return nil }
        return ShareParticipantRole(rawValue: raw)
    }

    enum Field {
        static let payload = "payload"        // JSON Data of the Shared* DTO
        static let schema = "schemaVersion"   // Int64, for forward compatibility
        static let searchTitle = "searchTitle" // plain string so CloudKit can index it
        static let cover = "cover"            // CKAsset fallback for large covers
    }

    // MARK: - Record names

    static func recordName(type: RecordType, id: String) -> String {
        type.prefix + id
    }

    static func id(fromRecordName name: String) -> String? {
        guard let type = RecordType(recordName: name) else { return nil }
        return String(name.dropFirst(type.prefix.count))
    }
    /// Encodes a DTO into a CKRecord in `zone`. Cover bytes always travel as
    /// a CKAsset (any size — URL-only fields would drop small covers); the
    /// payload's `coverImageURL` stays remote-only.
    static func encode(_ book: SharedBook, coverData: Data?, inZoneWith zoneID: CKRecordZone.ID) -> CKRecord {
        let record = record(type: .book, id: book.id, zoneID: zoneID)
        setPayload(book, in: record)
        record[Field.searchTitle] = book.title as NSString
        if let coverData, let url = stageTemporaryFile(coverData, name: book.id) {
            record[Field.cover] = CKAsset(fileURL: url)
        }
        return record
    }

    static func encode(_ note: SharedNote, inZoneWith zoneID: CKRecordZone.ID) -> CKRecord {
        let record = record(type: .note, id: note.id, zoneID: zoneID)
        setPayload(note, in: record)
        return record
    }

    static func encode(_ list: SharedReadingList, inZoneWith zoneID: CKRecordZone.ID) -> CKRecord {
        let record = record(type: .readingList, id: list.id, zoneID: zoneID)
        setPayload(list, in: record)
        return record
    }

    static func encode(_ item: SharedReadingListItem, inZoneWith zoneID: CKRecordZone.ID) -> CKRecord {
        let record = record(type: .readingListItem, id: item.id, zoneID: zoneID)
        setPayload(item, in: record)
        return record
    }

    // MARK: - Decode

    /// Decodes a changed record into a `SharedRecordChange`. Returns `nil` for
    /// foreign/unknown record types (e.g. CloudKit's own `cloudKit.share` root
    /// record) — callers must not treat that as an error.
    static func decode(_ record: CKRecord) -> SharedRecordChange? {
        guard let type = RecordType(recordName: record.recordID.recordName) else { return nil }
        guard let payload = record[Field.payload] as? Data else { return nil }
        guard (record[Field.schema] as? Int64) ?? 0 <= schemaVersion else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        switch type {
        case .book:
            guard let value = try? decoder.decode(SharedBook.self, from: payload) else { return nil }
            return SharedRecordChange(kind: .book(value))
        case .note:
            guard let value = try? decoder.decode(SharedNote.self, from: payload) else { return nil }
            return SharedRecordChange(kind: .note(value))
        case .readingList:
            guard let value = try? decoder.decode(SharedReadingList.self, from: payload) else { return nil }
            return SharedRecordChange(kind: .readingList(value))
        case .readingListItem:
            guard let value = try? decoder.decode(SharedReadingListItem.self, from: payload) else { return nil }
            return SharedRecordChange(kind: .readingListItem(value))
        }
    }

    /// Cover bytes carried as a CKAsset, if any. Cleans nothing — the asset's
    /// temp file is CloudKit-managed and valid for the session.
    static func coverData(from record: CKRecord) -> Data? {
        guard let asset = record[Field.cover] as? CKAsset, let url = asset.fileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Helpers

    private static func record(type: RecordType, id: String, zoneID: CKRecordZone.ID) -> CKRecord {
        let name = recordName(type: type, id: id)
        return CKRecord(recordType: type.rawValue, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
    }

    private static func setPayload<T: Encodable>(_ value: T, in record: CKRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys] // stable bytes → less spurious diffing
        record[Field.payload] = (try? encoder.encode(value)) as Data? ?? Data()
        record[Field.schema] = schemaVersion as NSNumber

    }
    private static func stageTemporaryFile(_ data: Data, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bn-share-\(UUID().uuidString)-\(name).jpg")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
