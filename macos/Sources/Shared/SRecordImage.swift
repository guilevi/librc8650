// Reading the firmware image off disk.
//
// librc8650 takes the image as Motorola S-record text, which for this firmware
// is about 900 KB of ASCII and compresses to roughly a third of that, so a
// .gz is worth accepting.  Foundation has no gunzip; the Compression framework
// has raw deflate, which is all a gzip member is once its header and trailer
// are off, so that is what this does.

import Foundation
import Compression

public enum SRecordImage {

    public enum Failure: Error {
        case truncated
        case notGzip
        case inflateFailed
    }

    /// The image as bytes, transparently decompressing a .gz.
    public static func load(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b {
            return try gunzip(data)
        }
        return data
    }

    /// Inflate a single-member gzip stream.
    public static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
            throw Failure.notGzip
        }
        let flags = bytes[3]
        var offset = 10
        func need(_ n: Int) throws {
            guard offset + n <= bytes.count else { throw Failure.truncated }
        }
        if flags & 0x04 != 0 {              // FEXTRA
            try need(2)
            let extra = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            offset += 2 + extra
        }
        if flags & 0x08 != 0 {              // FNAME
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {              // FCOMMENT
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        try need(8)

        // The last four bytes of a gzip member are ISIZE, the uncompressed size
        // modulo 2^32 — the right first guess at how much room to allocate.
        let isize = bytes[(bytes.count - 4)...].enumerated()
            .reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let deflated = bytes[offset..<(bytes.count - 8)]

        var capacity = max(isize, deflated.count * 4)
        for _ in 0..<8 {
            let out = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { out.deallocate() }
            let written = Array(deflated).withUnsafeBufferPointer { input -> Int in
                compression_decode_buffer(out, capacity,
                                          input.baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
            if written == 0 { throw Failure.inflateFailed }
            // A full buffer means it may have been truncated; grow and retry.
            if written < capacity { return Data(bytes: out, count: written) }
            capacity *= 2
        }
        throw Failure.inflateFailed
    }
}
