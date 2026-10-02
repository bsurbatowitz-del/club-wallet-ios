import Foundation

/// Text helpers shared by member matching, file names and templates.
public enum TextUtil {
    /// Fold accents and special letters to plain ASCII ("Šurbatović" -> "Surbatovic").
    public static func ascii(_ s: String) -> String {
        var t = s
        let table: [(String, String)] = [("đ", "dj"), ("Đ", "Dj"), ("ß", "ss"), ("ø", "o"), ("Ø", "O"), ("ł", "l"), ("Ł", "L")]
        for (a, b) in table { t = t.replacingOccurrences(of: a, with: b) }
        t = t.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(String.UnicodeScalarView(t.unicodeScalars.filter { $0.isASCII }))
    }

    /// Lowercase ASCII letters and digits only, used to compare names and headers.
    public static func norm(_ s: String) -> String {
        String(ascii(s).lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
            .map { Character($0) })
    }

    /// Replace {placeholders}; unknown ones are left as they are.
    public static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = template
        for (k, v) in values { out = out.replacingOccurrences(of: "{\(k)}", with: v) }
        return out
    }

    public static func slugPart(_ s: String) -> String {
        let a = ascii(s)
        var out = ""
        var lastDash = false
        for ch in a.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) || ch == "_" || ch == "-" {
                out.unicodeScalars.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// An sRGB colour parsed from "#RRGGBB".
public struct RGB: Equatable {
    public var r: Int, g: Int, b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = max(0, min(255, r)); self.g = max(0, min(255, g)); self.b = max(0, min(255, b))
    }

    public init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        self.init(r: (v >> 16) & 0xff, g: (v >> 8) & 0xff, b: v & 0xff)
    }

    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    public var css: String { "rgb(\(r), \(g), \(b))" }

    public static func parse(_ hex: String, default d: RGB) -> RGB { RGB(hex: hex) ?? d }
}
