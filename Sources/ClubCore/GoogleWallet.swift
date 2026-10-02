import Foundation
import Security
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GoogleWalletError: LocalizedError {
    case config(String), http(String, Int, String)
    public var errorDescription: String? {
        switch self {
        case .config(let s): return s
        case .http(let what, let code, let msg):
            var hint = ""
            if code == 401 || code == 403 {
                hint = " – check that the Google Wallet API is enabled and the service account was invited under Users in the Google Pay & Wallet Console."
            }
            return "\(what) failed (\(code)): \(msg)\(hint)"
        }
    }
}

/// Google Wallet generic passes: class/object upsert via REST + "Add to Google Wallet" link.
public final class GoogleWalletClient {
    public let issuerId: String
    public let classId: String
    let suffix: String
    public let clientEmail: String
    let keyId: String?
    let tokenURI: String
    let privateKey: SecKey
    let session: URLSession
    public var apiBase = "https://walletobjects.googleapis.com/walletobjects/v1"
    public var uploadBase = "https://walletobjects.googleapis.com/upload/walletobjects/v1"
    private var token: String?
    private var tokenExpiry = Date.distantPast
    private var classReady = false

    public static func safeID(_ s: String) -> String {
        String(s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) ? Character($0) : "_" })
    }

    public init(issuerId: String, serviceAccountJSON: Data, classSuffix: String, session: URLSession = .shared) throws {
        let issuer = issuerId.trimmingCharacters(in: .whitespaces)
        guard !issuer.isEmpty else { throw GoogleWalletError.config("Fill in the Issuer ID (Wallets tab).") }
        guard let sa = try? JSONSerialization.jsonObject(with: serviceAccountJSON) as? [String: Any],
              let email = sa["client_email"] as? String, let pem = sa["private_key"] as? String else {
            throw GoogleWalletError.config("The service account key file is not valid (needs client_email and private_key).")
        }
        self.issuerId = issuer
        self.suffix = GoogleWalletClient.safeID(classSuffix.isEmpty ? "membership" : classSuffix)
        self.classId = "\(issuer).\(suffix)"
        self.clientEmail = email
        self.keyId = sa["private_key_id"] as? String
        self.tokenURI = (sa["token_uri"] as? String) ?? "https://oauth2.googleapis.com/token"
        self.privateKey = try Keys.rsaPrivateKey(Data(pem.utf8))
        self.session = session
    }

    // MARK: JWT / auth
    public func jwt(_ claims: [String: Any]) throws -> String {
        var header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
        if let k = keyId { header["kid"] = k }
        let h = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]).base64URL
        let p = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys, .withoutEscapingSlashes]).base64URL
        let input = "\(h).\(p)"
        let sig = try Keys.sign(Data(input.utf8), key: privateKey)
        return "\(input).\(sig.base64URL)"
    }

    func accessToken() async throws -> String {
        if let t = token, Date() < tokenExpiry.addingTimeInterval(-60) { return t }
        let now = Int(Date().timeIntervalSince1970)
        let assertion = try jwt(["iss": clientEmail, "scope": "https://www.googleapis.com/auth/wallet_object.issuer",
                                 "aud": tokenURI, "iat": now, "exp": now + 3600])
        var req = URLRequest(url: URL(string: tokenURI)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)".utf8)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["access_token"] as? String else {
            throw GoogleWalletError.http("Google login", code, String(decoding: data.prefix(300), as: UTF8.self))
        }
        token = t
        tokenExpiry = Date().addingTimeInterval(TimeInterval((obj["expires_in"] as? Int) ?? 3600))
        return t
    }

    func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: "\(apiBase)/\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let b = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: b, options: [.withoutEscapingSlashes])
        }
        let (data, resp) = try await session.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    static func message(_ data: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = o["error"] as? [String: Any], let m = e["message"] as? String { return m }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    // MARK: class
    public var classBody: [String: Any] {
        func f(_ path: String) -> [String: Any] { ["firstValue": ["fields": [["fieldPath": path]]]] }
        let rows: [[String: Any]] = [
            ["twoItems": ["startItem": f("object.textModulesData['reg']"), "endItem": f("object.textModulesData['season']")]],
            ["oneItem": ["item": f("object.textModulesData['email']")]],
        ]
        return ["id": classId, "classTemplateInfo": ["cardTemplateOverride": ["cardRowTemplateInfos": rows]]]
    }

    public func ensureClass() async throws {
        if classReady { return }
        let (code, data) = try await call("GET", "genericClass/\(classId)")
        if code == 404 {
            let (c2, d2) = try await call("POST", "genericClass", body: classBody)
            guard c2 == 200 || c2 == 201 else { throw GoogleWalletError.http("Creating pass class", c2, Self.message(d2)) }
        } else if code == 200 {
            let (c2, d2) = try await call("PUT", "genericClass/\(classId)", body: classBody)
            guard c2 == 200 else { throw GoogleWalletError.http("Updating pass class", c2, Self.message(d2)) }
        } else {
            throw GoogleWalletError.http("Reading pass class", code, Self.message(data))
        }
        classReady = true
    }

    /// Issuer accounts this service account may use (empty until it's invited in the console).
    public func listIssuers() async throws -> [(id: String, name: String)] {
        let (code, data) = try await call("GET", "issuer")
        guard code == 200, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return ((o["resources"] as? [[String: Any]]) ?? []).map {
            (String(describing: $0["issuerId"] ?? ""), ($0["name"] as? String) ?? "")
        }
    }

    // MARK: objects
    public func objectId(_ m: Member) -> String { "\(issuerId).\(suffix)_\(Self.safeID(m.reg.isEmpty ? m.slug : m.reg))" }

    static func ls(_ v: String) -> [String: Any] { ["defaultValue": ["language": "en", "value": v]] }

    public func objectBody(member m: Member, config c: AppConfig, qrText: String, photoImageId: String? = nil) -> [String: Any] {
        func dash(_ s: String) -> String { s.isEmpty ? "-" : s }
        var o: [String: Any] = [
            "id": objectId(m), "classId": classId, "state": "ACTIVE",
            "cardTitle": Self.ls(c.clubName), "subheader": Self.ls(c.cardTitle), "header": Self.ls(m.fullName),
            "hexBackgroundColor": RGB.parse(c.bgColor, default: RGB(r: 11, g: 60, b: 93)).hex,
            "barcode": ["type": "QR_CODE", "value": qrText, "alternateText": "Reg. No. \(m.reg)"],
            "textModulesData": [
                ["id": "reg", "header": "Reg. No.", "body": dash(m.reg)],
                ["id": "season", "header": "Season", "body": dash(c.season)],
                ["id": "email", "header": "Email", "body": dash(m.email)],
                ["id": "name", "header": "Name", "body": dash(m.name)],
                ["id": "surname", "header": "Surname", "body": dash(m.surname)],
            ],
        ]
        let logo = c.googleLogoUrl.trimmingCharacters(in: .whitespaces)
        if !logo.isEmpty { o["logo"] = ["sourceUri": ["uri": logo], "contentDescription": Self.ls("\(c.clubName) logo")] }
        let hero = c.googleHeroUrl.trimmingCharacters(in: .whitespaces)
        if !hero.isEmpty { o["heroImage"] = ["sourceUri": ["uri": hero], "contentDescription": Self.ls(c.clubName)] }
        if let pid = photoImageId {
            o["imageModulesData"] = [["id": "photo", "mainImage": ["privateImageId": pid,
                                                                    "contentDescription": Self.ls("Photo of \(m.fullName)")]]]
        }
        let exp = c.expirationDate.trimmingCharacters(in: .whitespaces)
        if !exp.isEmpty { o["validTimeInterval"] = ["end": ["date": "\(exp)T23:59:59Z"]] }
        return o
    }

    /// Upload a member photo privately (no public link). Returns the privateImageId.
    public func uploadPrivateImage(jpeg: Data) async throws -> String {
        let url = URL(string: "\(uploadBase)/privateContent/\(issuerId)/uploadPrivateImage")!
        func attempt(_ u: URL) async throws -> (Int, Data) {
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            req.httpBody = jpeg
            let (d, r) = try await session.data(for: req)
            return ((r as? HTTPURLResponse)?.statusCode ?? 0, d)
        }
        var (code, data) = try await attempt(url)
        if code == 400, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = [URLQueryItem(name: "uploadType", value: "media")]
            (code, data) = try await attempt(comps.url!)
        }
        guard code == 200 || code == 201,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["privateImageId"] as? String else {
            throw GoogleWalletError.http("Uploading member photo", code, Self.message(data))
        }
        return id
    }

    public func upsertObject(member m: Member, config c: AppConfig, qrText: String, photoJPEG: Data?,
                             log: (String) -> Void = { _ in }) async throws -> String {
        try await ensureClass()
        var photoId: String?
        if let jpeg = photoJPEG {
            do { photoId = try await uploadPrivateImage(jpeg: jpeg) } catch {
                log("  ! Google photo for \(m.fullName) skipped: \(error.localizedDescription)")
            }
        }
        let body = objectBody(member: m, config: c, qrText: qrText, photoImageId: photoId)
        var (code, data) = try await call("POST", "genericObject", body: body)
        if code == 409 { (code, data) = try await call("PUT", "genericObject/\(objectId(m))", body: body) }
        guard code == 200 || code == 201 else { throw GoogleWalletError.http("Saving pass", code, Self.message(data)) }
        return objectId(m)
    }

    public func saveLink(objectId: String) throws -> String {
        let claims: [String: Any] = [
            "iss": clientEmail, "aud": "google", "typ": "savetowallet",
            "iat": Int(Date().timeIntervalSince1970), "origins": [String](),
            "payload": ["genericObjects": [["id": objectId, "classId": classId]]],
        ]
        return "https://pay.google.com/gp/v/save/" + (try jwt(claims))
    }

    /// Create/update the member's pass and return the "Add to Google Wallet" link.
    public func createPass(member m: Member, config c: AppConfig, qrText: String, photoJPEG: Data?,
                           log: (String) -> Void = { _ in }) async throws -> String {
        try saveLink(objectId: try await upsertObject(member: m, config: c, qrText: qrText, photoJPEG: photoJPEG, log: log))
    }
}
