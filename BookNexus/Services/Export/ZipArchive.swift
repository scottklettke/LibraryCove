import Foundation
import Compression

/// Errors surfaced while reading or writing an archive.
enum ZipArchiveError: LocalizedError {
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .corrupt(let detail): return "The file is not a valid archive: \(detail)."
        }
    }
}

/// A self-contained minimal ZIP writer/reader (entries can be stored or
/// deflated via libcompression). Handles standard archives produced by the
/// system `zip`/Finder "Compress" tools as well as the ones BookNexus writes.
///
/// Reading enforces zip-bomb caps: 256 MB per entry and 1 GB total
/// uncompressed size, checked against the central directory before allocating.
enum ZipArchive {

    // MARK: - Write

    /// Builds a ZIP file from (name, contents) pairs.
    static func create(entries: [(name: String, data: Data)]) -> Data? {
        let dos = dosDateTime(Date())
        var body = Data()
        var central = Data()
        var offset: UInt32 = 0

        for (name, fileData) in entries {
            let nameBytes = Array(name.utf8)
            guard nameBytes.count <= UInt16.max else { continue }

            let method: UInt16
            let payload: Data
            if fileData.isEmpty {
                method = 0
                payload = Data()
            } else {
                let compressed = deflate(fileData)
                if compressed.count < fileData.count && !compressed.isEmpty {
                    method = 8
                    payload = compressed
                } else {
                    method = 0
                    payload = fileData
                }
            }
            let crc = crc32(fileData)

            // Local file header
            var local = Data()
            appendUInt32(&local, 0x04034b50)
            appendUInt16(&local, 20)               // version needed to extract
            appendUInt16(&local, 0x0800)           // UTF-8 file names
            appendUInt16(&local, method)
            appendUInt16(&local, dos.0)            // mod time
            appendUInt16(&local, dos.1)            // mod date
            appendUInt32(&local, crc)
            appendUInt32(&local, UInt32(payload.count))
            appendUInt32(&local, UInt32(fileData.count))
            appendUInt16(&local, UInt16(nameBytes.count))
            appendUInt16(&local, 0)                // extra field length
            local.append(contentsOf: nameBytes)
            local.append(payload)
            body.append(local)

            // Central directory file header
            appendUInt32(&central, 0x02014b50)
            appendUInt16(&central, 20)             // version made by
            appendUInt16(&central, 20)             // version needed
            appendUInt16(&central, 0x0800)
            appendUInt16(&central, method)
            appendUInt16(&central, dos.0)
            appendUInt16(&central, dos.1)
            appendUInt32(&central, crc)
            appendUInt32(&central, UInt32(payload.count))
            appendUInt32(&central, UInt32(fileData.count))
            appendUInt16(&central, UInt16(nameBytes.count))
            appendUInt16(&central, 0)              // extra length
            appendUInt16(&central, 0)              // comment length
            appendUInt16(&central, 0)              // disk number start
            appendUInt16(&central, 0)              // internal attributes
            appendUInt32(&central, 0)              // external attributes
            appendUInt32(&central, offset)
            central.append(contentsOf: nameBytes)

            offset += UInt32(local.count)
        }

        // End of central directory record
        var eocd = Data()
        appendUInt32(&eocd, 0x06054b50)
        appendUInt16(&eocd, 0)                     // disk number
        appendUInt16(&eocd, 0)                     // disk with central dir
        appendUInt16(&eocd, UInt16(entries.count))
        appendUInt16(&eocd, UInt16(entries.count))
        appendUInt32(&eocd, UInt32(central.count))
        appendUInt32(&eocd, UInt32(body.count))
        appendUInt16(&eocd, 0)                     // comment length

        var zip = Data()
        zip.append(body)
        zip.append(central)
        zip.append(eocd)
        return zip
    }

    // MARK: - Read

    /// Extracts every file entry from a ZIP archive, keyed by name.
    /// Directories and macOS `__MACOSX` sidecar entries are skipped.
    static func unzip(_ data: Data) throws -> [String: Data] {
        guard data.count >= 22 else { throw ZipArchiveError.corrupt("too small") }

        // Locate the End Of Central Directory record by scanning backwards
        // from the end (it may carry a trailing comment in foreign files).
        let eocd = findEOCD(data)
        let entryCount = Int(u16(data, eocd + 10))
        let centralSize = Int(u32(data, eocd + 12))
        let centralOffset = Int(u32(data, eocd + 16))
        guard centralOffset >= 0, centralOffset + centralSize <= data.count,
              eocd + 22 <= data.count else {
            throw ZipArchiveError.corrupt("central directory out of bounds")
        }

        var files: [String: Data] = [:]
        var totalUncompressed = 0
        var cursor = centralOffset
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count else {
                throw ZipArchiveError.corrupt("truncated central directory")
            }
            guard u32(data, cursor) == 0x02014b50 else {
                throw ZipArchiveError.corrupt("bad central directory signature")
            }
            let method = u16(data, cursor + 10)
            let compressedSize = Int(u32(data, cursor + 20))
            let uncompressedSize = Int(u32(data, cursor + 24))
            let nameLength = Int(u16(data, cursor + 28))
            let extraLength = Int(u16(data, cursor + 30))
            let commentLength = Int(u16(data, cursor + 32))
            let localOffset = Int(u32(data, cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else {
                throw ZipArchiveError.corrupt("entry name out of bounds")
            }
            guard let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8) else {
                throw ZipArchiveError.corrupt("entry name not UTF-8")
            }

            // Skip directories and macOS metadata sidecars.
            if !name.hasSuffix("/") && !name.hasPrefix("__MACOSX/") && !name.contains("/__MACOSX/") {
                // Zip-bomb guards: no single entry may claim more than
                // 256 MB, and the whole archive may not decompress past
                // 1 GB. The declared sizes come from the central directory
                // and are checked BEFORE any allocation or inflation, so a
                // hostile archive can't get a byte of memory past the caps.
                // 1 GB total because cover JPEGs are stored nearly
                // uncompressed — a large library export is legitimately huge.
                guard uncompressedSize <= 256_000_000 else {
                    throw ZipArchiveError.corrupt("entry '\(name)' exceeds 256 MB uncompressed size limit")
                }
                totalUncompressed += uncompressedSize
                guard totalUncompressed <= 1_000_000_000 else {
                    throw ZipArchiveError.corrupt("archive exceeds 1 GB total uncompressed size limit")
                }
                let payload = try dataOfEntry(data,
                                              localOffset: localOffset,
                                              method: method,
                                              compressedSize: compressedSize,
                                              uncompressedSize: uncompressedSize)
                files[name] = payload
            }

            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return files
    }

    private static func dataOfEntry(_ data: Data,
                                    localOffset: Int,
                                    method: UInt16,
                                    compressedSize: Int,
                                    uncompressedSize: Int) throws -> Data {
        // Local file header: 30 bytes, then name + extra, then the payload.
        guard localOffset + 30 <= data.count else { throw ZipArchiveError.corrupt("bad local header offset") }
        let nameLength = Int(u16(data, localOffset + 26))
        let extraLength = Int(u16(data, localOffset + 28))
        let payloadStart = localOffset + 30 + nameLength + extraLength
        guard payloadStart >= 0, payloadStart + compressedSize <= data.count else {
            throw ZipArchiveError.corrupt("entry payload out of bounds")
        }
        let payload = data.subdata(in: payloadStart..<(payloadStart + compressedSize))

        switch method {
        case 0: // stored
            return payload
        case 8: // deflate (zlib-wrapped)
            guard let inflated = inflate(payload, expectedSize: uncompressedSize) else {
                throw ZipArchiveError.corrupt("could not decompress entry")
            }
            guard inflated.count == uncompressedSize else {
                throw ZipArchiveError.corrupt("decompressed size mismatch")
            }
            return inflated
        default:
            throw ZipArchiveError.corrupt("unsupported compression method \(method)")
        }
    }

    private static func findEOCD(_ data: Data) -> Int {
        let searchFrom = max(0, data.count - 66_000 - 22)
        var index = data.count - 22
        while index >= searchFrom {
            if u32(data, index) == 0x06054b50 {
                return index
            }
            index -= 1
        }
        return data.count - 22
    }

    // MARK: - Compression helpers

    private static func deflate(_ data: Data) -> Data {
        let srcSize = data.count
        let capacity = srcSize + (srcSize >> 4) + 4096
        var dst = [UInt8](repeating: 0, count: capacity)
        let written = dst.withUnsafeMutableBytes { dstBuf -> Int in
            data.withUnsafeBytes { srcBuf -> Int in
                guard let dstBase = dstBuf.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = srcBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dstBase, capacity, srcBase, srcSize, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return Data() }
        return Data(dst.prefix(written))
    }

    private static func inflate(_ data: Data, expectedSize: Int?) -> Data? {
        let srcSize = data.count
        guard srcSize > 0 else { return Data() }
        // The exact uncompressed size comes from the central directory; when it
        // is absent (rare foreign edge case) use a generous heuristic buffer.
        let target: Int
        if let expectedSize, expectedSize > 0 {
            target = expectedSize
        } else {
            target = max(4096, min(srcSize * 8, 100_000_000))
        }
        var out = Data(count: target)
        let written = out.withUnsafeMutableBytes { dstBuf -> Int in
            data.withUnsafeBytes { srcBuf -> Int in
                guard let dstBase = dstBuf.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = srcBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, target, srcBase, srcSize, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Data(out.prefix(written))
    }

    // MARK: - Little-endian byte helpers (ZIP stores everything little-endian)

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        return table
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    /// DOS-style modification time/date fields for a ZIP header.
    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = UInt16(max(0, (c.year ?? 1980) - 1980))
        let month = UInt16(c.month ?? 1)
        let day = UInt16(c.day ?? 1)
        let hour = UInt16(c.hour ?? 0)
        let minute = UInt16(c.minute ?? 0)
        let second = UInt16((c.second ?? 0) / 2)
        let time = (hour << 11) | (minute << 5) | second
        let datePart = (year << 9) | (month << 5) | day
        return (time, datePart)
    }
}
