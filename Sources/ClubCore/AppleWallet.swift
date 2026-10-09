import Foundation
import CryptoKit

public enum AppleWalletError: LocalizedError {
    case missingIDs
    public var errorDescription: String? { "Fill in the Pass Type ID and Team ID (Wallets tab → Check certificate fills them in)." }
}

/// Builds pass.json and the signed .pkpass archive.
public enum AppleWallet {
    public static func passJSON(member m: Member, config c: AppConfig, qrText: String) throws -> Data {
        guard !c.applePassTypeId.isEmpty, !c.appleTeamId.isEmpty else { throw AppleWalletError.missingIDs }
        let fg = RGB.parse(c.fgColor, default: RGB(r: 255, g: 255, b: 255))
        let bg = RGB.parse(c.bgColor, default: RGB(r: 11, g: 60, b: 93))
        let lc = RGB.parse(c.labelColor, default: RGB(r: 159, g: 211, b: 245))
        let barcode: [String: Any] = ["format": "PKBarcodeFormatQR", "message": qrText,
                                      "messageEncoding": "utf-8", "altText": "Reg. No. \(m.reg)"]
        var p: [String: Any] = [
            "formatVersion": 1,
            "passTypeIdentifier": c.applePassTypeId,
            "teamIdentifier": c.appleTeamId,
            "serialNumber": m.reg.isEmpty ? m.slug : m.reg,
            "organizationName": c.clubName,
            "description": "\(c.clubName) \(c.cardTitle)",
            "logoText": c.clubName,
            "foregroundColor": fg.css,
            "backgroundColor": bg.css,
            "labelColor": lc.css,
            "barcodes": [barcode],
            "barcode": barcode,
        ]
        let layout = ["generic", "eventTicket", "storeCard"].contains(c.appleLayout) ? c.appleLayout : "generic"
        func field(_ key: String, _ label: String, _ value: String) -> [String: Any] {
            ["key": key, "label": label, "value": value]
        }
        let header: [[String: Any]] = c.season.isEmpty ? [] : [field("season", "SEASON", c.season)]
        var body: [String: Any]
        if layout == "storeCard" {
            // banner stays clear for the picture + photo; Reg. No. sits right under the member name
            body = ["headerFields": header,
                    "primaryFields": [[String: Any]](),
                    "secondaryFields": [field("member", "MEMBER", m.fullName)],
                    "auxiliaryFields": [field("reg", "REG. NO.", m.reg)]]
        } else {
            var secondary = [field("reg", "REG. NO.", m.reg)]
            if layout == "generic" { secondary.append(field("card", "CARD", c.cardTitle)) }
            body = ["headerFields": header,
                    "primaryFields": [field("member", "MEMBER", m.fullName)],
                    "secondaryFields": secondary,
                    "auxiliaryFields": [field("email", "EMAIL", m.email)]]
        }
        var back = [
            field("b_reg", "Registration number", m.reg),
            field("b_name", "Name", m.name),
            field("b_surname", "Surname", m.surname),
            field("b_email", "Email", m.email),
            field("b_club", "Club", c.clubName),
        ]
        let blood = c.bloodFields(for: m)
        var aux = (body["auxiliaryFields"] as? [[String: Any]]) ?? []
        func centered(_ f: [String: Any]) -> [String: Any] { f.merging(["textAlignment": "PKTextAlignmentCenter"]) { $1 } }
        if let bt = blood.blood {
            aux.append(centered(field("blood", "🩸", bt))); back.append(field("b_blood", "🩸 Blood type", bt))
        }
        if let rh = blood.rh {
            aux.append(centered(field("rh", "RH", rh))); back.append(field("b_rh", "Rh", rh))
        }
        if layout == "storeCard" {
            // Apple shows at most 4 secondary + auxiliary fields on store cards; email goes there only if there's room
            let used = 1 + aux.count
            if used < 4 { aux.insert(field("email", "EMAIL", m.email), at: 1) }
        }
        body["auxiliaryFields"] = aux
        body["backFields"] = back
        p[layout] = body
        let exp = c.expirationDate.trimmingCharacters(in: .whitespaces)
        if !exp.isEmpty {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: exp) {
                let iso = ISO8601DateFormatter()
                p["expirationDate"] = iso.string(from: d.addingTimeInterval(23 * 3600 + 59 * 60))
            }
        }
        return try JSONSerialization.data(withJSONObject: p, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Signed .pkpass from pass.json + images (icon.png etc.).
    public static func pkpass(passJSON: Data, images: [String: Data], signer: PassSigner) throws -> Data {
        var files = images
        files["pass.json"] = passJSON
        let names = files.keys.sorted()
        var manifest: [String: String] = [:]
        for n in names { manifest[n] = Data(Insecure.SHA1.hash(data: files[n]!)).hex }
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        let signature = try CMS.detachedSignature(content: manifestData, signer: signer)
        var zip = ZipWriter()
        for n in names { zip.add(n, files[n]!) }
        zip.add("manifest.json", manifestData)
        zip.add("signature", signature)
        return zip.finish()
    }
}
