import Foundation

/// gzip (RFC 1952) over Foundation's raw DEFLATE, so `zcat` and `gzip -t` read what Workbench writes and no library
/// is linked. Whole buffers: a transcript is bounded (`TranscriptFile.maxCompressedBytes`), not a stream.
enum Gzip {
    enum Failure: Error, Equatable {
        case notGzip
        case corrupt(String)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])  // deflate, no name, no time, Unix
        out.append(deflated)
        out.append(le32(crc32(data)))
        out.append(le32(UInt32(truncatingIfNeeded: data.count)))
        return out
    }

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else { throw Failure.notGzip }
        let flags = bytes[3]
        var start = 10
        if flags & 0x04 != 0 {  // extra field
            guard bytes.count >= start + 2 else { throw Failure.corrupt("truncated header") }
            start += 2 + Int(bytes[start]) + Int(bytes[start + 1]) << 8
        }
        for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {  // file name, comment: zero-terminated
            guard let end = bytes[min(start, bytes.count)...].firstIndex(of: 0) else { throw Failure.corrupt("truncated header") }
            start = end + 1
        }
        if flags & 0x02 != 0 { start += 2 }  // header CRC
        guard start <= bytes.count - 8 else { throw Failure.corrupt("truncated") }
        let body = Data(bytes[start..<(bytes.count - 8)])
        let inflated: Data
        do { inflated = try (body as NSData).decompressed(using: .zlib) as Data } catch {
            throw Failure.corrupt("not a DEFLATE stream")
        }
        let trailer = Array(bytes.suffix(8))
        let crc = trailer[0..<4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        let size = trailer[4..<8].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        guard crc == crc32(inflated), size == UInt32(truncatingIfNeeded: inflated.count) else {
            throw Failure.corrupt("checksum")
        }
        return inflated
    }

    private static func le32(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) })
    }
}
