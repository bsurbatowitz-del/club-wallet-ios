import Foundation

public struct Member: Identifiable, Hashable, Codable {
    public var id: Int { row }
    public var reg: String
    public var name: String
    public var surname: String
    public var email: String
    public var photoColumn: String
    public var row: Int
    public var bloodType: String
    public var rhRaw: String

    public init(reg: String, name: String, surname: String, email: String, photoColumn: String = "", row: Int = 0,
                bloodType: String = "", rh: String = "") {
        self.reg = reg; self.name = name; self.surname = surname; self.email = email
        self.photoColumn = photoColumn; self.row = row; self.bloodType = bloodType; self.rhRaw = rh
    }

    /// Rh shown as "+" or "−" ("pos", "Rh+", "negative" … are understood).
    public var rh: String { MemberList.normalizeRh(rhRaw) }

    public var fullName: String { "\(name) \(surname)".trimmingCharacters(in: .whitespaces) }

    public var emailValid: Bool {
        email.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }

    /// Folder/file-name friendly id, e.g. "1_Surbatovic_Bojan".
    public var slug: String {
        let s = TextUtil.slugPart("\(reg)_\(surname)_\(name)")
        return s.isEmpty ? "row\(row)" : s
    }

    /// Key used for photos and the send log.
    public var key: String { reg.isEmpty ? "row\(row)" : reg }

    public func fields(_ config: AppConfig? = nil) -> [String: String] {
        var d = ["reg": reg, "name": name, "surname": surname, "full_name": fullName, "email": email]
        d["blood_type"] = bloodType; d["rh"] = rh
        if let c = config {
            d["club"] = c.clubName; d["season"] = c.season; d["card_title"] = c.cardTitle
        }
        return d
    }
}

public enum MemberList {
    static func clean(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["nan", "none", "nat"].contains(s.lowercased()) { return "" }
        if s.range(of: #"^-?\d+\.0+$"#, options: .regularExpression) != nil {
            s = String(s.split(separator: ".")[0])
        }
        return s
    }

    /// Find which column holds what, by header names (English + Croatian/Serbian), like the desktop app.
    public static func detectColumns(_ headers: [String]) throws -> [String: Int] {
        let norm = headers.map(TextUtil.norm)
        var found: [String: Int] = [:]
        func pick(_ key: String, _ exact: Set<String>, _ contains: [String]) {
            for (i, h) in norm.enumerated() where !found.values.contains(i) && exact.contains(h) { found[key] = i; return }
            for (i, h) in norm.enumerated() where !found.values.contains(i) && contains.contains(where: { h.contains($0) }) {
                found[key] = i; return
            }
        }
        pick("email", ["email", "mail", "emailaddress", "eposta", "adresa"], ["mail"])
        pick("surname", ["surname", "lastname", "familyname", "prezime"], ["surname", "lastname", "prezime"])
        pick("name", ["name", "firstname", "givenname", "ime"], ["firstname", "name", "ime"])
        pick("reg", ["reg", "regnumber", "regno", "registrationnumber", "number", "no", "id", "membernumber",
                     "memberno", "broj", "regbroj", "clanskibroj"], ["reg", "number", "broj", "id", "no"])
        for (i, h) in norm.enumerated() where !found.values.contains(i) &&
            ["photo", "photofile", "picture", "image", "slika", "fotografija", "foto"].contains(h) {
            found["photo"] = i; break
        }
        for (i, h) in norm.enumerated() where !found.values.contains(i) &&
            (["rh", "rhfactor", "rhfaktor", "rhd", "faktorrh"].contains(h) || h.hasPrefix("rh")) {
            found["rh"] = i; break
        }
        for (i, h) in norm.enumerated() where !found.values.contains(i) &&
            (h.contains("blood") || h.contains("krv") || ["bloodtype", "bloodgroup", "grupa", "abo"].contains(h)) {
            found["blood"] = i; break
        }
        let required = ["reg", "name", "surname", "email"]
        let missing = required.filter { found[$0] == nil }
        if !missing.isEmpty && headers.count >= 4 {
            let fallback = ["reg": 0, "name": 1, "surname": 2, "email": 3]
            for k in missing { found[k] = fallback[k] }
        } else if !missing.isEmpty {
            throw SheetError.columns("Could not find column(s): \(missing.joined(separator: ", ")). Headers: \(headers)")
        }
        return found
    }

    public static func parse(rows: [[String]]) throws -> [Member] {
        guard let headerIndex = rows.firstIndex(where: { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } })
        else { throw SheetError.empty }
        let cols = try detectColumns(rows[headerIndex])
        var members: [Member] = []
        for (offset, r) in rows.enumerated() where offset > headerIndex {
            func v(_ k: String) -> String {
                guard let i = cols[k], i < r.count else { return "" }
                return clean(r[i])
            }
            let m = Member(reg: v("reg"), name: v("name"), surname: v("surname"), email: v("email"),
                           photoColumn: v("photo"), row: offset + 1, bloodType: v("blood"), rh: v("rh"))
            if m.reg.isEmpty && m.name.isEmpty && m.surname.isEmpty && m.email.isEmpty { continue }
            members.append(m)
        }
        return members
    }

    public static func normalizeRh(_ v: String) -> String {
        let s = v.trimmingCharacters(in: .whitespaces)
        let t = s.lowercased().replacingOccurrences(of: "rh", with: "").replacingOccurrences(of: "d", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        if ["+", "pos", "positive", "pozitivan", "poz", "plus"].contains(t) { return "+" }
        if ["-", "−", "–", "neg", "negative", "negativan", "minus"].contains(t) { return "−" }
        return s
    }

    public static func load(data: Data, fileExtension: String) throws -> [Member] {
        try parse(rows: Spreadsheet.rows(from: data, fileExtension: fileExtension))
    }
}

/// Matches photo file names to members: 1.jpg, 001.png, "Name Surname.jpg", "Surname_Name.png",
/// "1_Name_Surname.jpg", "email@address.jpg" (case and accents ignored).
public enum PhotoMatcher {
    public static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tif", "tiff"]

    public static func keys(_ m: Member) -> [String] {
        var keys: [String] = []
        let reg = TextUtil.norm(m.reg)
        if !reg.isEmpty {
            keys.append(reg)
            let stripped = String(reg.drop(while: { $0 == "0" }))
            keys.append(stripped.isEmpty ? "0" : stripped)
        }
        let n = TextUtil.norm(m.name), s = TextUtil.norm(m.surname)
        keys += [n + s, s + n, reg + n + s, reg + s + n, n + s + reg, s + n + reg]
        if !m.email.isEmpty {
            keys.append(TextUtil.norm(m.email))
            keys.append(TextUtil.norm(String(m.email.split(separator: "@").first ?? "")))
        }
        return keys.filter { !$0.isEmpty }
    }

    /// Pick the member's photo from a list of file names (not paths).
    public static func match(_ m: Member, fileNames: [String]) -> String? {
        var index: [String: String] = [:]
        for f in fileNames.sorted() {
            let url = URL(fileURLWithPath: f)
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let k = TextUtil.norm(url.deletingPathExtension().lastPathComponent)
            if index[k] == nil { index[k] = f }
        }
        if !m.photoColumn.isEmpty {
            if let exact = fileNames.first(where: { $0 == m.photoColumn }) { return exact }
            let k = TextUtil.norm(URL(fileURLWithPath: m.photoColumn).deletingPathExtension().lastPathComponent)
            if let f = index[k] { return f }
        }
        for k in keys(m) { if let f = index[k] { return f } }
        let reg = TextUtil.norm(m.reg)
        if !reg.isEmpty, reg.allSatisfy(\.isNumber) {
            let r = String(reg.drop(while: { $0 == "0" }))
            for (k, f) in index where !k.isEmpty && k.allSatisfy(\.isNumber) && String(k.drop(while: { $0 == "0" })) == r {
                return f
            }
        }
        return nil
    }
}
