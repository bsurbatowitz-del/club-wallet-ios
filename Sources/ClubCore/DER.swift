import Foundation

public enum DERError: LocalizedError {
    case truncated, badLength, unexpected(String)
    public var errorDescription: String? {
        switch self {
        case .truncated: return "Certificate/key data is truncated."
        case .badLength: return "Certificate/key data has an invalid length."
        case .unexpected(let s): return "Unexpected certificate/key data: \(s)"
        }
    }
}

/// Minimal DER encoder (only what CMS signatures need).
public enum DER {
    public static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    public static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    public static func seq(_ parts: [UInt8]...) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    public static func set(_ parts: [UInt8]...) -> [UInt8] { tlv(0x31, parts.flatMap { $0 }) }

    public static func int(_ v: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var x = v
        repeat { bytes.insert(UInt8(x & 0xff), at: 0); x >>= 8 } while x > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    public static let null: [UInt8] = [0x05, 0x00]
    public static func octets(_ d: [UInt8]) -> [UInt8] { tlv(0x04, d) }

    public static func oid(_ s: String) -> [UInt8] {
        let arcs = s.split(separator: ".").compactMap { UInt64($0) }
        precondition(arcs.count >= 2, "bad OID")
        var out: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for a in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(a & 0x7f)]
            var v = a >> 7
            while v > 0 { chunk.insert(UInt8(v & 0x7f) | 0x80, at: 0); v >>= 7 }
            out += chunk
        }
        return tlv(0x06, out)
    }

    public static func utcTime(_ date: Date) -> [UInt8] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Array(f.string(from: date).utf8))
    }
}

/// Minimal DER reader.
public struct DERNode {
    public let tag: UInt8
    public let bytes: [UInt8]     // whole TLV
    public let content: [UInt8]

    public func children() throws -> [DERNode] { try DERNode.parseAll(content) }

    public static func parse(_ data: [UInt8], at start: Int = 0) throws -> (DERNode, Int) {
        guard start + 2 <= data.count else { throw DERError.truncated }
        let tag = data[start]
        var i = start + 1
        var len = Int(data[i]); i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard n > 0, n <= 4, i + n <= data.count else { throw DERError.badLength }
            len = 0
            for _ in 0..<n { len = (len << 8) | Int(data[i]); i += 1 }
        }
        guard len >= 0, i + len <= data.count else { throw DERError.truncated }
        let node = DERNode(tag: tag, bytes: Array(data[start..<(i + len)]), content: Array(data[i..<(i + len)]))
        return (node, i + len)
    }

    public static func parseAll(_ data: [UInt8]) throws -> [DERNode] {
        var out: [DERNode] = []
        var i = 0
        while i < data.count {
            let (n, next) = try parse(data, at: i)
            out.append(n); i = next
        }
        return out
    }

    public var oidString: String? {
        guard tag == 0x06, !content.isEmpty else { return nil }
        var arcs: [UInt64] = []
        let first = UInt64(content[0])
        arcs.append(min(first / 40, 2)); arcs.append(first - min(first / 40, 2) * 40)
        var v: UInt64 = 0
        for b in content.dropFirst() {
            v = (v << 7) | UInt64(b & 0x7f)
            if b & 0x80 == 0 { arcs.append(v); v = 0 }
        }
        return arcs.map(String.init).joined(separator: ".")
    }

    public var stringValue: String? {
        switch tag {
        case 0x0C, 0x13, 0x16, 0x14, 0x1A: return String(decoding: content, as: UTF8.self)
        case 0x1E: // BMPString (UTF-16BE)
            var units: [UInt16] = []
            var i = 0
            while i + 1 < content.count { units.append(UInt16(content[i]) << 8 | UInt16(content[i + 1])); i += 2 }
            return String(decoding: units, as: UTF16.self)
        default: return nil
        }
    }

    public var dateValue: Date? {
        guard tag == 0x17 || tag == 0x18 else { return nil }
        let s = String(decoding: content, as: UTF8.self)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return f.date(from: s)
    }
}

/// PEM text -> DER blocks.
public enum PEM {
    public static func blocks(_ text: String) -> [(type: String, der: [UInt8])] {
        var out: [(String, [UInt8])] = []
        var current: String?
        var body = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-----BEGIN ") && line.hasSuffix("-----") {
                current = String(line.dropFirst(11).dropLast(5)); body = ""
            } else if line.hasPrefix("-----END "), let t = current {
                if let d = Data(base64Encoded: body) { out.append((t, [UInt8](d))) }
                current = nil
            } else if current != nil, !line.contains(":") {
                body += line
            }
        }
        return out
    }

    public static func isPEM(_ data: Data) -> Bool {
        guard let s = String(data: data.prefix(4096), encoding: .utf8) else { return false }
        return s.contains("-----BEGIN ")
    }

    /// The DER bytes of the first block of one of `types` (or the raw bytes if the data isn't PEM).
    public static func der(_ data: Data, types: [String]) throws -> [UInt8] {
        guard isPEM(data), let s = String(data: data, encoding: .utf8) else { return [UInt8](data) }
        for b in blocks(s) where types.contains(b.type) { return b.der }
        throw DERError.unexpected("no \(types.joined(separator: "/")) block in PEM file")
    }
}
