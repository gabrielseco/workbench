import CZlib
import Foundation

/// gzip (RFC 1952) over zlib's raw DEFLATE (the system zlib on macOS and Linux), so `zcat` and `gzip -t` read what Workbench writes. Whole buffers: a transcript is bounded (`TranscriptFile.maxCompressedBytes`), not a stream.
enum Gzip {
    enum Failure: Error, Equatable {
        case notGzip
        case corrupt(String)
        /// The data would inflate past the cap; nothing past it was produced.
        case tooLarge
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    static func compress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let size = Int32(MemoryLayout<z_stream>.size)
        let started = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, size)
        guard started == Z_OK else { throw Failure.corrupt("cannot start deflating") }
        defer { deflateEnd(&stream) }
        var deflated = Data(count: Int(deflateBound(&stream, UInt(data.count))))
        let status: Int32 = deflated.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = UInt32(input.count)
                stream.next_out = output.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = UInt32(output.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw Failure.corrupt("cannot deflate") }
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])  // deflate, no name, no time, Unix
        out.append(deflated.prefix(Int(stream.total_out)))
        out.append(le32(crc32(data)))
        out.append(le32(UInt32(truncatingIfNeeded: data.count)))
        return out
    }

    static func decompress(_ data: Data, limit: Int = TranscriptFile.maxCompressedBytes) throws -> Data {
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
        let inflated = try inflateRaw(body, limit: limit)
        let trailer = Array(bytes.suffix(8))
        let crc = trailer[0..<4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        let size = trailer[4..<8].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        guard crc == crc32(inflated), size == UInt32(truncatingIfNeeded: inflated.count) else {
            throw Failure.corrupt("checksum")
        }
        return inflated
    }

    /// Raw DEFLATE to bytes, in chunks, stopping with `tooLarge` as soon as the output would pass `limit`: a file
    /// that was replaced or made elsewhere cannot make a reader allocate what it likes.
    private static func inflateRaw(_ body: Data, limit: Int) throws -> Data {
        let chunk = 1 << 16
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { scratch.deallocate() }
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.corrupt("cannot start inflating")
        }
        defer { inflateEnd(&stream) }

        var out = Data()
        return try body.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Data in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(input.count)
            while true {
                stream.next_out = scratch
                stream.avail_out = UInt32(chunk)
                let status = CZlib.inflate(&stream, Z_NO_FLUSH)
                let produced = chunk - Int(stream.avail_out)
                if out.count + produced > limit { throw Failure.tooLarge }
                out.append(scratch, count: produced)
                switch status {
                case Z_STREAM_END: return out
                // Output space left over and no input left: the stream ends early.
                case Z_OK where stream.avail_out == 0: continue
                default: throw Failure.corrupt("not a DEFLATE stream")
                }
            }
        }
    }

    private static func le32(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) })
    }
}
