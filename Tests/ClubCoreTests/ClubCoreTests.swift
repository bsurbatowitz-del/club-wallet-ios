import XCTest
import Foundation
import CryptoKit
@testable import ClubCore

/// These run on macOS (`swift test`) in GitHub Actions. Signatures are checked with the real
/// `openssl` tool and emails with Python's email parser, so we know other software accepts them.
final class ClubCoreTests: XCTestCase {

    // MARK: helpers
    func fixture(_ name: String) throws -> URL {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard let url = Bundle.module.url(forResource: parts[0], withExtension: parts.count > 1 ? parts[1] : nil,
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("missing fixture \(name)")
        }
        return url
    }

    func fixtureData(_ name: String) throws -> Data { try Data(contentsOf: fixture(name)) }

    lazy var tmp: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("clubcore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    @discardableResult
    func run(_ exe: String, _ args: [String], cwd: URL? = nil) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    var openssl: String {
        for p in ["/opt/homebrew/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl", "/usr/local/bin/openssl", "/usr/bin/openssl"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/usr/bin/openssl"
    }

    var python: String {
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/usr/bin/python3"
    }

    func signer() throws -> PassSigner {
        try PassSigner.fromPEM(certificate: fixtureData("test_pass_cert.pem"), key: fixtureData("test_pass_key.pem"),
                               wwdr: fixtureData("test_wwdr.pem"))
    }

    // MARK: certificates
    func testCertificateFields() throws {
        let cert = try CertificateInfo(data: fixtureData("test_pass_cert.pem"))
        XCTAssertEqual(cert.passTypeID, "pass.hr.triclub.member")
        XCTAssertEqual(cert.teamID, "ABCDE12345")
        XCTAssertNotNil(cert.notAfter)
        XCTAssertNotNil(cert.publicKeyData)
    }

    func testKeyMismatchIsDetected() throws {
        let otherKey = try Keys.rsaPrivateKey(Data((try JSONSerialization.jsonObject(
            with: fixtureData("test_service_account.json")) as! [String: Any])["private_key"] as! String).utf8)
        XCTAssertThrowsError(try PassSigner(certificate: CertificateInfo(data: fixtureData("test_pass_cert.pem")),
                                            key: otherKey, wwdr: CertificateInfo(data: fixtureData("test_wwdr.pem"))))
    }

    func testP12() throws {
        do {
            let s = try PassSigner.fromP12(fixtureData("test_pass.p12"), password: "secret", wwdr: fixtureData("test_wwdr.pem"))
            XCTAssertEqual(s.certificate.teamID, "ABCDE12345")
        } catch KeyError.p12(let msg) where !msg.contains("wrong password") {
            throw XCTSkip("p12 import not available in this test environment: \(msg)")
        }
        XCTAssertThrowsError(try PassSigner.fromP12(fixtureData("test_pass.p12"), password: "nope", wwdr: fixtureData("test_wwdr.pem")))
    }

    // MARK: Apple pass
    func testPKPassSignatureVerifiesWithOpenSSL() throws {
        var c = AppConfig()
        c.applePassTypeId = "pass.hr.triclub.member"; c.appleTeamId = "ABCDE12345"; c.expirationDate = "2026-12-31"
        let m = Member(reg: "1", name: "Bojan", surname: "Šurbatović", email: "bojan@example.com")
        for layout in ["storeCard", "eventTicket", "generic"] {
            c.appleLayout = layout
            let json = try AppleWallet.passJSON(member: m, config: c, qrText: c.qrText(for: m))
            let icon = Data(repeating: 7, count: 500)
            let pass = try AppleWallet.pkpass(passJSON: json, images: ["icon.png": icon, "icon@2x.png": icon], signer: signer())

            let files = try ZipReader(pass).files
            XCTAssertEqual(Set(files.keys), ["pass.json", "icon.png", "icon@2x.png", "manifest.json", "signature"])
            let manifest = try JSONSerialization.jsonObject(with: files["manifest.json"]!) as! [String: String]
            for (name, hash) in manifest { XCTAssertEqual(Data(Insecure.SHA1.hash(data: files[name]!)).hex, hash) }
            let pj = try JSONSerialization.jsonObject(with: files["pass.json"]!) as! [String: Any]
            XCTAssertNotNil(pj[layout]); XCTAssertEqual(pj["serialNumber"] as? String, "1")
            XCTAssertNotNil(pj["expirationDate"])

            let dir = tmp.appendingPathComponent(layout)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try pass.write(to: dir.appendingPathComponent("p.pkpass"))
            try files["manifest.json"]!.write(to: dir.appendingPathComponent("manifest.json"))
            try files["signature"]!.write(to: dir.appendingPathComponent("signature"))
            try fixtureData("test_wwdr.pem").write(to: dir.appendingPathComponent("ca.pem"))
            let (code, out) = try run(openssl, ["smime", "-verify", "-in", "signature", "-inform", "DER", "-content",
                                                 "manifest.json", "-CAfile", "ca.pem", "-purpose", "any", "-binary",
                                                 "-out", "/dev/null"], cwd: dir)
            XCTAssertEqual(code, 0, "openssl verify failed for \(layout): \(out)")
            let (zcode, zout) = try run("/usr/bin/unzip", ["-t", "p.pkpass"], cwd: dir)
            XCTAssertEqual(zcode, 0, "unzip -t failed: \(zout)")
        }
    }

    // MARK: zip
    func testZipRoundTrip() throws {
        var z = ZipWriter()
        let big = Data(String(repeating: "hello wallet ", count: 2000).utf8)
        z.add("a.txt", Data("short".utf8)); z.add("dir/b.txt", big); z.add("empty", Data())
        let r = try ZipReader(z.finish())
        XCTAssertEqual(r.files["a.txt"], Data("short".utf8))
        XCTAssertEqual(r.files["dir/b.txt"], big)
        XCTAssertEqual(r.files["empty"], Data())
    }

    // MARK: spreadsheets
    func checkMembers(_ ms: [Member], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ms.count, 4, file: file, line: line)
        XCTAssertEqual(ms.first?.reg, "1", file: file, line: line)
        XCTAssertEqual(ms.first?.surname, "Šurbatović", file: file, line: line)
        XCTAssertEqual(ms[1].reg, "7", file: file, line: line)
        XCTAssertEqual(ms[1].photoColumn, "ana.jpg", file: file, line: line)
        XCTAssertFalse(ms[2].emailValid, file: file, line: line)
        XCTAssertEqual(ms[3].fullName, "Ivana Horvat", file: file, line: line)
    }

    func testODS() throws { checkMembers(try MemberList.load(data: fixtureData("members.ods"), fileExtension: "ods")) }
    func testXLSX() throws { checkMembers(try MemberList.load(data: fixtureData("members.xlsx"), fileExtension: "xlsx")) }

    func testCSV() throws {
        let ms = try MemberList.load(data: fixtureData("members.csv"), fileExtension: "csv")
        XCTAssertEqual(ms.count, 2)
        XCTAssertEqual(ms[1].reg, "007")
        XCTAssertEqual(ms[1].surname, "Đokić, Jr.")
    }

    func testPhotoMatching() {
        let m = Member(reg: "1", name: "Bojan", surname: "Šurbatović", email: "bojan@example.com")
        for f in ["1.jpg", "001.png", "Surbatovic_Bojan.jpeg", "1_Bojan_Surbatovic.JPG", "bojan@example.com.jpg", "Bojan Šurbatović.heic"] {
            XCTAssertEqual(PhotoMatcher.match(m, fileNames: ["zzz.jpg", f, "notes.txt"]), f, f)
        }
        XCTAssertNil(PhotoMatcher.match(m, fileNames: ["2.jpg", "Ana.jpg"]))
    }

    // MARK: config / transfer file
    func testUbuntuConfigImport() throws {
        let c = try AppConfig.decode(fixtureData("ubuntu_config.json"))
        XCTAssertEqual(c.clubName, "Triatlon Klub Budva")
        XCTAssertEqual(c.smtpPort, 587)        // was a string in the file
        XCTAssertEqual(c.bgOverlay, 40)
        XCTAssertEqual(c.appleLayout, "storeCard")
        let again = try AppConfig.decode(c.encoded())
        XCTAssertEqual(again, c)
        XCTAssertTrue(String(decoding: try c.encoded(), as: UTF8.self).contains("\"apple_p12_password\""))
    }

    func testBundlePlainAndEncrypted() throws {
        let plain = try ClubBundle(data: fixtureData("bundle_plain.clubwallet"))
        XCTAssertEqual(plain.config.clubName, "Triatlon Klub Budva")
        XCTAssertEqual(plain.config.smtpPassword, "app-pw")
        XCTAssertNotNil(plain.files["apple_cert"]); XCTAssertNotNil(plain.files["apple_key"])
        XCTAssertNotNil(plain.files["google_service_account"]); XCTAssertNotNil(plain.files["members"])
        XCTAssertNotNil(plain.photos["1"])
        _ = try PassSigner.fromPEM(certificate: plain.files["apple_cert"]!.data, key: plain.files["apple_key"]!.data,
                                   wwdr: plain.files["apple_wwdr"]!.data)

        let enc = try fixtureData("bundle_encrypted.clubwallet")
        XCTAssertTrue(ClubBundle.isEncrypted(enc))
        XCTAssertThrowsError(try ClubBundle(data: enc)) { XCTAssertEqual($0 as? BundleError, .needsPassword) }
        XCTAssertThrowsError(try ClubBundle(data: enc, password: "wrong")) { XCTAssertEqual($0 as? BundleError, .wrongPassword) }
        let b = try ClubBundle(data: enc, password: "test123")
        XCTAssertEqual(b.config.smtpPassword, "")   // exported without passwords
        XCTAssertEqual(b.files["members"]?.data, plain.files["members"]?.data)
    }

    // MARK: Google
    func testGoogleJWTVerifiesWithOpenSSL() throws {
        let sa = try fixtureData("test_service_account.json")
        let g = try GoogleWalletClient(issuerId: "3388000000012345678", serviceAccountJSON: sa, classSuffix: "membership")
        let link = try g.saveLink(objectId: "3388000000012345678.membership_1")
        XCTAssertTrue(link.hasPrefix("https://pay.google.com/gp/v/save/"))
        let token = String(link.dropFirst("https://pay.google.com/gp/v/save/".count))
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        func unb64(_ s: String) -> Data {
            var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while t.count % 4 != 0 { t += "=" }
            return Data(base64Encoded: t)!
        }
        let payload = try JSONSerialization.jsonObject(with: unb64(parts[1])) as! [String: Any]
        XCTAssertEqual(payload["aud"] as? String, "google")
        XCTAssertEqual(payload["typ"] as? String, "savetowallet")

        let dir = tmp.appendingPathComponent("jwt")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saObj = try JSONSerialization.jsonObject(with: sa) as! [String: Any]
        try (saObj["private_key"] as! String).write(to: dir.appendingPathComponent("key.pem"), atomically: true, encoding: .utf8)
        try Data("\(parts[0]).\(parts[1])".utf8).write(to: dir.appendingPathComponent("input"))
        try unb64(parts[2]).write(to: dir.appendingPathComponent("sig"))
        try run(openssl, ["rsa", "-in", "key.pem", "-pubout", "-out", "pub.pem"], cwd: dir)
        let (code, out) = try run(openssl, ["dgst", "-sha256", "-verify", "pub.pem", "-signature", "sig", "input"], cwd: dir)
        XCTAssertEqual(code, 0, out)

        var c = AppConfig(); c.googleHeroUrl = "https://example.com/hero.jpg"
        let body = g.objectBody(member: Member(reg: "1", name: "A", surname: "B", email: "a@b.c"), config: c,
                                qrText: "qr", photoImageId: "PRIV")
        XCTAssertEqual(body["id"] as? String, "3388000000012345678.membership_1")
        XCTAssertNotNil(body["heroImage"]); XCTAssertNotNil(body["imageModulesData"])
    }

    // MARK: email
    func testEmailParsesAndSendsOverSMTP() async throws {
        var c = AppConfig()
        c.clubName = "Triatlon Klub Budva"; c.fromEmail = "club@example.com"; c.fromName = "Triatlon Klub Budva"
        let m = Member(reg: "1", name: "Bojan", surname: "Šurbatović", email: "bojan@example.com")
        let msg = CardEmail.build(config: c, member: m, pkpass: Data(repeating: 1, count: 3000), passFileName: "x.pkpass",
                                  googleURL: "https://pay.google.com/gp/v/save/abc", cardPNG: Data(repeating: 2, count: 2000))

        // Send it through our SMTP client to a tiny local server, then parse with Python's email module.
        let port = Int.random(in: 20_000...40_000)
        let out = tmp.appendingPathComponent("mail.eml")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: python)
        server.arguments = [try fixture("fake_smtp.py").path, String(port), out.path]
        let pipe = Pipe(); server.standardOutput = pipe
        try server.run()
        _ = pipe.fileHandleForReading.availableData   // wait for "ready"

        let s = SMTPClient(host: "127.0.0.1", port: port, useTLS: false)
        try await s.connect()
        try await s.login(user: "club@example.com", password: "pw")
        try await s.send(from: "club@example.com", to: [m.email], message: msg)
        await s.close()
        server.waitUntilExit()

        let script = """
        import email, sys
        from email import policy
        m = email.message_from_bytes(open(sys.argv[1], 'rb').read(), policy=policy.default)
        print(m['Subject']); print(m['To'])
        for p in m.walk(): print(p.get_content_type(), p.get_filename() or '')
        print(m.get_body(('plain',)).get_content())
        """
        let py = tmp.appendingPathComponent("parse.py")
        try script.write(to: py, atomically: true, encoding: .utf8)
        let (code, text) = try run(python, [py.path, out.path])
        XCTAssertEqual(code, 0, text)
        XCTAssertTrue(text.contains("Your Triatlon Klub Budva membership card"), text)
        XCTAssertTrue(text.contains("Šurbatović"), text)
        XCTAssertTrue(text.contains("application/vnd.apple.pkpass x.pkpass"), text)
        XCTAssertTrue(text.contains("image/png membership-card.png"), text)
        XCTAssertTrue(text.contains("Add to Google Wallet: https://pay.google.com/gp/v/save/abc"), text)
    }
}
