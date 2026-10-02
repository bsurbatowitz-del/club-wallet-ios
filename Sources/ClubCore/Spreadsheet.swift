import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum SheetError: LocalizedError {
    case unsupported(String), empty, columns(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let e): return "Unsupported file type .\(e) – use .ods, .xlsx or .csv."
        case .empty: return "The spreadsheet is empty."
        case .columns(let s): return s
        }
    }
}

/// Reads the first sheet of .ods / .xlsx / .csv into rows of strings.
public enum Spreadsheet {
    public static func rows(from data: Data, fileExtension ext: String) throws -> [[String]] {
        switch ext.lowercased() {
        case "csv", "txt": return csv(String(decoding: data, as: UTF8.self))
        case "xlsx", "xlsm": return try xlsx(data)
        case "ods": return try ods(data)
        default: throw SheetError.unsupported(ext)
        }
    }

    // MARK: CSV
    public static func csv(_ input: String) -> [[String]] {
        var text = input
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let firstLine = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        let candidates: [Character] = [",", ";", "\t"]
        var delim: Character = ","
        var best = -1
        for c in candidates {
            let n = firstLine.filter { $0 == c }.count
            if n > best { best = n; delim = c }
        }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delim {
                row.append(field); field = ""
            } else if c.isNewline {
                row.append(field); field = ""; rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: XLSX
    public static func xlsx(_ data: Data) throws -> [[String]] {
        let zip = try ZipReader(data)
        var shared: [String] = []
        if let ss = zip.files["xl/sharedStrings.xml"] {
            let d = SharedStringsParser()
            let p = XMLParser(data: ss); p.delegate = d; p.parse()
            shared = d.strings
        }
        let sheetName = zip.files.keys.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }.first
        guard let name = sheetName, let sheet = zip.files[name] else { throw SheetError.empty }
        let d = XLSXSheetParser(shared: shared)
        let p = XMLParser(data: sheet); p.delegate = d; p.parse()
        return d.rows
    }

    // MARK: ODS
    public static func ods(_ data: Data) throws -> [[String]] {
        let zip = try ZipReader(data)
        guard let content = zip.files["content.xml"] else { throw ZipError.corrupt("content.xml missing") }
        let d = ODSParser()
        let p = XMLParser(data: content); p.delegate = d; p.parse()
        return d.rows
    }
}

final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var inSI = false, inT = false, inPhonetic = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "si": inSI = true; current = ""
        case "t": inT = true
        case "rPh": inPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inSI && inT && !inPhonetic { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "si": strings.append(current); inSI = false
        case "t": inT = false
        case "rPh": inPhonetic = false
        default: break
        }
    }
}

final class XLSXSheetParser: NSObject, XMLParserDelegate {
    let shared: [String]
    var rows: [[String]] = []
    private var row: [Int: String] = [:]
    private var cellCol = 0, cellType = "", value = "", capture = false
    private var nextCol = 0

    init(shared: [String]) { self.shared = shared }

    static func column(_ ref: String) -> Int? {
        var n = 0
        var any = false
        for ch in ref.uppercased().unicodeScalars {
            guard ch.value >= 65 && ch.value <= 90 else { break }
            n = n * 26 + Int(ch.value - 64); any = true
        }
        return any ? n - 1 : nil
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "row": row = [:]; nextCol = 0
        case "c":
            cellCol = attributes["r"].flatMap(XLSXSheetParser.column) ?? nextCol
            cellType = attributes["t"] ?? ""; value = ""
        case "v", "t": capture = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if capture { value += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t": capture = false
        case "c":
            var v = value
            if cellType == "s", let idx = Int(value.trimmingCharacters(in: .whitespaces)), idx < shared.count { v = shared[idx] }
            row[cellCol] = v
            nextCol = cellCol + 1
        case "row":
            let maxCol = row.keys.max() ?? -1
            rows.append(maxCol < 0 ? [] : (0...maxCol).map { row[$0] ?? "" })
        default: break
        }
    }
}

final class ODSParser: NSObject, XMLParserDelegate {
    var rows: [[String]] = []
    private var tableDepth = 0, tablesSeen = 0
    private var row: [String] = []
    private var rowRepeat = 1
    private var cellRepeat = 1, cellType = "", cellValue: String?, text = "", inCell = false, paragraphs = 0

    private var active: Bool { tableDepth > 0 && tablesSeen == 1 }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        switch name {
        case "table:table":
            tableDepth += 1
            if tableDepth == 1 { tablesSeen += 1 }
        case "table:table-row" where active:
            row = []; rowRepeat = Int(a["table:number-rows-repeated"] ?? "1") ?? 1
        case "table:table-cell", "table:covered-table-cell":
            guard active else { return }
            inCell = true; text = ""; paragraphs = 0
            cellRepeat = Int(a["table:number-columns-repeated"] ?? "1") ?? 1
            cellType = a["office:value-type"] ?? ""
            cellValue = a["office:value"]
        case "text:p" where inCell:
            if paragraphs > 0 { text += "\n" }
            paragraphs += 1
        case "text:s" where inCell:
            text += String(repeating: " ", count: Int(a["text:c"] ?? "1") ?? 1)
        case "text:tab" where inCell: text += "\t"
        case "text:line-break" where inCell: text += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inCell { text += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "table:table": tableDepth -= 1
        case "table:table-cell", "table:covered-table-cell":
            guard active, inCell else { return }
            inCell = false
            let numeric = ["float", "percentage", "currency"].contains(cellType)
            let v = (numeric ? cellValue : nil) ?? text
            row.append(contentsOf: Array(repeating: v, count: min(cellRepeat, v.isEmpty ? 64 : 1024)))
        case "table:table-row":
            guard active else { return }
            while let last = row.last, last.isEmpty { row.removeLast() }
            if row.isEmpty {
                rows.append([])               // keep one empty row; huge repeats are just padding
            } else {
                for _ in 0..<min(rowRepeat, 10_000) { rows.append(row) }
            }
        default: break
        }
    }
}
