import Foundation
import Compression

public enum ZipError: LocalizedError {
    case notZip, corrupt(String), unsupported(Int)
    public var errorDescription: String? {
        switch self {
        case .notZip: return "The file is not a valid .ods/.xlsx (zip) file."
        case .corrupt(let s): return "The file is damaged (\(s))."
        case .unsupported(let m): return "Unsupported compression method \(m)."
        }
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for b in p { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendLE16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func appendLE32(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
}

/// Writes a zip archive (deflate when it helps, otherwise stored).
public struct ZipWriter {
    private var entries: [(name: String, data: Data)] = []
    public init() {}

    public mutating func add(_ name: String, _ data: Data) { entries.append((name, data)) }

    static func deflate(_ data: Data) -> Data? {
        let src = [UInt8](data)
        guard src.count > 64 else { return nil }
        var dst = [UInt8](repeating: 0, count: src.count + 4096)
        let dstCount = dst.count
        let n = src.withUnsafeBufferPointer { s -> Int in
            dst.withUnsafeMutableBufferPointer { d -> Int in
                compression_encode_buffer(d.baseAddress!, dstCount, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0, n < src.count else { return nil }
        return Data(dst[0..<n])
    }

    public func finish() -> Data {
        var out = Data()
        var central = Data()
        for e in entries {
            let name = Data(e.name.utf8)
            let crc = CRC32.checksum(e.data)
            let packed = ZipWriter.deflate(e.data)
            let method: UInt16 = packed == nil ? 0 : 8
            let body = packed ?? e.data
            let offset = UInt32(out.count)

            out.appendLE32(0x0403_4B50); out.appendLE16(20); out.appendLE16(0x0800); out.appendLE16(method)
            out.appendLE16(0); out.appendLE16(0x21)                 // 1980-01-01 00:00
            out.appendLE32(crc); out.appendLE32(UInt32(body.count)); out.appendLE32(UInt32(e.data.count))
            out.appendLE16(UInt16(name.count)); out.appendLE16(0)
            out.append(name); out.append(body)

            central.appendLE32(0x0201_4B50); central.appendLE16(20); central.appendLE16(20)
            central.appendLE16(0x0800); central.appendLE16(method); central.appendLE16(0); central.appendLE16(0x21)
            central.appendLE32(crc); central.appendLE32(UInt32(body.count)); central.appendLE32(UInt32(e.data.count))
            central.appendLE16(UInt16(name.count)); central.appendLE16(0); central.appendLE16(0)
            central.appendLE16(0); central.appendLE16(0); central.appendLE32(0); central.appendLE32(offset)
            central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.appendLE32(0x0605_4B50); out.appendLE16(0); out.appendLE16(0)
        out.appendLE16(UInt16(entries.count)); out.appendLE16(UInt16(entries.count))
        out.appendLE32(UInt32(central.count)); out.appendLE32(cdOffset); out.appendLE16(0)
        return out
    }
}

/// Reads all files of a (non-zip64) zip archive into memory.
public struct ZipReader {
    public let files: [String: Data]

    public init(_ data: Data) throws {
        let b = [UInt8](data)
        func le16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func le32(_ i: Int) -> Int { le16(i) | le16(i + 2) << 16 }
        guard b.count >= 22 else { throw ZipError.notZip }
        var eocd = -1
        var i = b.count - 22
        let stop = max(0, b.count - 65_557)
        while i >= stop {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = le16(eocd + 10)
        var p = le32(eocd + 16)
        var files: [String: Data] = [:]
        for _ in 0..<count {
            guard p + 46 <= b.count, le32(p) == 0x0201_4B50 else { throw ZipError.corrupt("central directory") }
            let method = le16(p + 10)
            let csize = le32(p + 20), usize = le32(p + 24)
            let nlen = le16(p + 28), elen = le16(p + 30), clen = le16(p + 32)
            let local = le32(p + 42)
            guard p + 46 + nlen <= b.count else { throw ZipError.corrupt("name") }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            p += 46 + nlen + elen + clen
            guard local + 30 <= b.count, le32(local) == 0x0403_4B50 else { throw ZipError.corrupt("local header") }
            let start = local + 30 + le16(local + 26) + le16(local + 28)
            guard start + csize <= b.count else { throw ZipError.corrupt("data") }
            if name.hasSuffix("/") { continue }
            let raw = Array(b[start..<(start + csize)])
            switch method {
            case 0: files[name] = Data(raw)
            case 8: files[name] = try ZipReader.inflate(raw, size: usize)
            default: throw ZipError.unsupported(method)
            }
        }
        self.files = files
    }

    static func inflate(_ src: [UInt8], size: Int) throws -> Data {
        if size == 0 { return Data() }
        var dst = [UInt8](repeating: 0, count: size)
        let n = src.withUnsafeBufferPointer { s -> Int in
            dst.withUnsafeMutableBufferPointer { d -> Int in
                compression_decode_buffer(d.baseAddress!, size, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == size else { throw ZipError.corrupt("inflate") }
        return Data(dst)
    }
}
