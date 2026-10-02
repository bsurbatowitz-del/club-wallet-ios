import SwiftUI
import UIKit
import ClubCore

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Files the app keeps (privately, in Application Support/ClubWallet/Setup).
enum Asset: String, CaseIterable {
    case logo, background, members
    case appleP12 = "apple_p12", appleCert = "apple_cert", appleKey = "apple_key", appleWWDR = "apple_wwdr"
    case googleServiceAccount = "google_service_account"

    var title: String {
        switch self {
        case .logo: return "Logo"
        case .background: return "Background picture"
        case .members: return "Member list"
        case .appleP12: return ".p12 certificate"
        case .appleCert: return "Pass certificate (.cer)"
        case .appleKey: return "Private key (.pem)"
        case .appleWWDR: return "Apple WWDR certificate"
        case .googleServiceAccount: return "Service account key (.json)"
        }
    }
}

struct GeneratedCard {
    var png: Data
    var pngURL: URL
    var pkpass: Data? = nil
    var pkpassURL: URL? = nil
    var googleURL: String? = nil
}

struct SimpleError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

@MainActor
final class Store: ObservableObject {
    @Published var config: AppConfig { didSet { if config != oldValue { saveConfig() } } }
    @Published var members: [Member] = []
    @Published var membersFileName = ""
    @Published var sent: [String: String] = [:]
    @Published var log: [String] = []
    @Published var busy = false
    @Published var showProgress = false
    @Published var progress: Double = 0
    @Published var progressTitle = ""
    @Published var alert: AlertMessage?
    @Published var revision = 0
    @Published var pendingTransfer: Data?      // encrypted .clubwallet waiting for its password
    var stopRequested = false

    let base: URL, setupDir: URL, photosDir: URL, cardsDir: URL
    private var thumbs: [String: UIImage] = [:]
    private var photoNames: [String] = []
    private var photoNamesRevision = -1

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClubWallet")
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        base = support
        setupDir = support.appendingPathComponent("Setup")
        photosDir = support.appendingPathComponent("Photos")
        cardsDir = docs.appendingPathComponent("Cards")
        for d in [setupDir, photosDir, cardsDir] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        if let d = try? Data(contentsOf: support.appendingPathComponent("config.json")), let c = try? AppConfig.decode(d) {
            config = c
        } else {
            config = AppConfig()
        }
        if let d = try? Data(contentsOf: support.appendingPathComponent("sent.json")),
           let s = try? JSONDecoder().decode([String: String].self, from: d) {
            sent = s
        }
        membersFileName = UserDefaults.standard.string(forKey: "membersFileName") ?? ""
        loadMembersFromAsset()
    }

    // MARK: persistence
    func saveConfig() {
        try? config.encoded().write(to: base.appendingPathComponent("config.json"), options: [.atomic, .completeFileProtection])
    }

    func saveSent() {
        try? JSONEncoder().encode(sent).write(to: base.appendingPathComponent("sent.json"), options: .atomic)
    }

    func addLog(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(s)")
    }

    func show(_ title: String, _ message: String) { alert = AlertMessage(title: title, message: message) }
    func show(_ error: Error, title: String = "Problem") { show(title, error.localizedDescription) }

    /// Read a file picked in Files / iCloud Drive (handles security scope and not-yet-downloaded files).
    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordError: NSError?
        var result: Result<Data, Error> = .failure(SimpleError("Could not read \(url.lastPathComponent)"))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            result = Result { try Data(contentsOf: u) }
        }
        if let e = coordError { throw e }
        return try result.get()
    }

    // MARK: assets
    func assetURL(_ a: Asset) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: setupDir, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent == a.rawValue }
    }

    func assetData(_ a: Asset) -> Data? { assetURL(a).flatMap { try? Data(contentsOf: $0) } }
    func hasAsset(_ a: Asset) -> Bool { assetURL(a) != nil }
    func image(_ a: Asset) -> UIImage? { assetData(a).flatMap { UIImage(data: $0) } }

    func setAsset(_ a: Asset, data: Data, ext: String) throws {
        if let old = assetURL(a) { try? FileManager.default.removeItem(at: old) }
        let e = ext.isEmpty ? "bin" : ext.lowercased()
        try data.write(to: setupDir.appendingPathComponent("\(a.rawValue).\(e)"), options: [.atomic, .completeFileProtection])
        revision += 1
        thumbs.removeAll()
    }

    func removeAsset(_ a: Asset) {
        if let u = assetURL(a) { try? FileManager.default.removeItem(at: u) }
        revision += 1
    }

    func importAsset(_ a: Asset, from url: URL) {
        do {
            let data = try Store.read(url)
            if a == .logo || a == .background, UIImage(data: data) == nil { throw SimpleError("That file is not a picture.") }
            try setAsset(a, data: data, ext: url.pathExtension)
            if a == .members { importMembers(data: data, fileName: url.lastPathComponent) }
            if a == .appleCert || a == .appleP12 || a == .appleKey || a == .appleWWDR { autofillApple(quiet: true) }
        } catch { show(error, title: "Import failed") }
    }

    // MARK: members
    func loadMembersFromAsset() {
        guard let u = assetURL(.members), let d = try? Data(contentsOf: u) else { members = []; return }
        members = (try? MemberList.load(data: d, fileExtension: u.pathExtension)) ?? []
    }

    func importMembers(data: Data, fileName: String) {
        do {
            let ext = URL(fileURLWithPath: fileName).pathExtension
            members = try MemberList.load(data: data, fileExtension: ext)
            try setAsset(.members, data: data, ext: ext)
            membersFileName = fileName
            UserDefaults.standard.set(fileName, forKey: "membersFileName")
            let bad = members.filter { !$0.emailValid }.count
            addLog("Loaded \(members.count) members from \(fileName)")
            if bad > 0 { show("Member list loaded", "\(members.count) members, \(bad) with a missing or invalid email.") }
        } catch { show(error, title: "Could not read the member list") }
    }

    func sentKey(_ m: Member) -> String { "\(m.reg)|\(m.email.lowercased())" }
    func sentDate(_ m: Member) -> String? { sent[sentKey(m)] }

    func markSent(_ m: Member) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        sent[sentKey(m)] = f.string(from: Date())
        saveSent()
    }

    // MARK: photos
    var allPhotoNames: [String] {
        if photoNamesRevision != revision {
            photoNames = (try? FileManager.default.contentsOfDirectory(atPath: photosDir.path)) ?? []
            photoNamesRevision = revision
        }
        return photoNames
    }

    func photoURL(_ m: Member) -> URL? {
        guard config.photosEnabled else { return nil }
        let names = allPhotoNames
        if let o = config.photoOverrides[m.key], names.contains(o) { return photosDir.appendingPathComponent(o) }
        return PhotoMatcher.match(m, fileNames: names).map { photosDir.appendingPathComponent($0) }
    }

    func photo(_ m: Member) -> UIImage? { photoURL(m).flatMap { UIImage(contentsOfFile: $0.path) } }

    func thumbnail(_ m: Member) -> UIImage? {
        let k = "\(m.key)#\(revision)"
        if let t = thumbs[k] { return t }
        guard let p = photo(m) else { return nil }
        let t = CardRenderer.cover(p, CGSize(width: 120, height: 120), focusY: 0.42)
        thumbs[k] = t
        return t
    }

    func setPhoto(_ m: Member, data: Data) {
        guard let img = UIImage(data: data), let jpeg = CardRenderer.jpeg(img, maxSide: 1600) else {
            show("Photo", "That file could not be opened as a picture."); return
        }
        if let old = photoURL(m) { try? FileManager.default.removeItem(at: old) }
        let name = "\(TextUtil.slugPart(m.key)).jpg"
        do {
            try jpeg.write(to: photosDir.appendingPathComponent(name), options: .atomic)
            config.photoOverrides[m.key] = name
            revision += 1
        } catch { show(error, title: "Could not save the photo") }
    }

    func removePhoto(_ m: Member) {
        if let u = photoURL(m) { try? FileManager.default.removeItem(at: u) }
        config.photoOverrides[m.key] = nil
        revision += 1
    }

    func importPhotos(_ urls: [URL]) {
        var n = 0
        for u in urls {
            guard let d = try? Store.read(u), UIImage(data: d) != nil else { continue }
            if (try? d.write(to: photosDir.appendingPathComponent(u.lastPathComponent), options: .atomic)) != nil { n += 1 }
        }
        revision += 1
        let matched = members.filter { photoURL($0) != nil }.count
        show("Photos imported", "\(n) photo(s) added. \(matched) of \(members.count) members now have a photo.\n\n" +
             "Photos are matched by file name: 1.jpg, 001.png, \"Name Surname.jpg\", \"Surname_Name.png\" …")
    }

    // MARK: wallets
    func effectiveConfig() -> AppConfig {
        var c = config
        if c.bgAutoColor, let bg = image(.background) {
            let col = CardRenderer.colors(from: bg)
            c.bgColor = col.bg; c.fgColor = col.fg; c.labelColor = col.label
        }
        return c
    }

    func makeSigner() throws -> PassSigner {
        guard let wwdr = assetData(.appleWWDR) else { throw KeyError.missing("Import the Apple WWDR certificate (Wallets tab).") }
        if config.appleCertMode == "p12" {
            guard let p12 = assetData(.appleP12) else { throw KeyError.missing("Import your .p12 pass certificate (Wallets tab).") }
            return try PassSigner.fromP12(p12, password: config.appleP12Password, wwdr: wwdr)
        }
        guard let cert = assetData(.appleCert), let key = assetData(.appleKey) else {
            throw KeyError.missing("Import the pass certificate (.cer) and its private key (.pem) on the Wallets tab.")
        }
        return try PassSigner.fromPEM(certificate: cert, key: key, wwdr: wwdr)
    }

    func makeGoogle(issuer: String? = nil) throws -> GoogleWalletClient {
        guard let sa = assetData(.googleServiceAccount) else {
            throw GoogleWalletError.config("Import the service account key (.json) on the Wallets tab.")
        }
        return try GoogleWalletClient(issuerId: issuer ?? config.googleIssuerId, serviceAccountJSON: sa,
                                      classSuffix: config.googleClassSuffix)
    }

    @discardableResult
    func autofillApple(quiet: Bool = false) -> Bool {
        do {
            let s = try makeSigner()
            if let p = s.certificate.passTypeID { config.applePassTypeId = p }
            if let t = s.certificate.teamID { config.appleTeamId = t }
            if !quiet {
                let f = DateFormatter(); f.dateStyle = .medium
                show("Certificate OK ✓", "Pass Type ID: \(s.certificate.passTypeID ?? "?")\nTeam ID: \(s.certificate.teamID ?? "?")\n" +
                     "Valid until: \(s.certificate.notAfter.map { f.string(from: $0) } ?? "?")")
            }
            return true
        } catch {
            if !quiet { show(error, title: "Certificate problem") }
            return false
        }
    }

    func testGoogle() {
        Task {
            do {
                let g = try makeGoogle()
                try await g.ensureClass()
                show("Google Wallet OK ✓", "Pass class \(g.classId) is ready.")
            } catch { show(error, title: "Google Wallet problem") }
        }
    }

    func findIssuer() {
        Task {
            do {
                let g = try makeGoogle(issuer: "0")
                let list = try await g.listIssuers()
                if let first = list.first {
                    config.googleIssuerId = first.id
                    show("Issuer found ✓", "\(first.name) – \(first.id)" + (list.count > 1 ? "\n(\(list.count) issuers; using the first)" : ""))
                } else {
                    UIPasteboard.general.string = g.clientEmail
                    show("No issuer access yet",
                         "In the Google Pay & Wallet Console open Users → Invite a user and add\n\n\(g.clientEmail)\n\n" +
                         "as Developer (the address is copied). Then try again in a minute.")
                }
            } catch { show(error, title: "Google Wallet problem") }
        }
    }

    // MARK: generating
    func generate(_ m: Member, cfg: AppConfig, signer: PassSigner?, google: GoogleWalletClient?,
                  warnings: inout [String]) async throws -> GeneratedCard {
        let dir = cardsDir.appendingPathComponent(m.slug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let qr = cfg.qrText(for: m)
        let ph = photo(m)
        let logo = image(.logo), bg = image(.background)
        let png = CardRenderer.renderCard(member: m, config: cfg, qrText: qr, photo: ph, logo: logo, background: bg).pngData() ?? Data()
        let pngURL = dir.appendingPathComponent("\(m.slug)-card.png")
        try png.write(to: pngURL, options: .atomic)
        var card = GeneratedCard(png: png, pngURL: pngURL)
        if let s = signer {
            let json = try AppleWallet.passJSON(member: m, config: cfg, qrText: qr)
            let imgs = CardRenderer.appleImages(config: cfg, layout: cfg.appleLayout, photo: ph, logo: logo, background: bg)
            let data = try AppleWallet.pkpass(passJSON: json, images: imgs, signer: s)
            let u = dir.appendingPathComponent(cfg.passFileName(for: m))
            try data.write(to: u, options: .atomic)
            card.pkpass = data; card.pkpassURL = u
        }
        if let g = google {
            let jpeg = ph.flatMap { CardRenderer.squareJPEG($0, side: 600) }
            var notes: [String] = []
            card.googleURL = try await g.createPass(member: m, config: cfg, qrText: qr, photoJPEG: jpeg) { notes.append($0) }
            warnings += notes
            try? Data((card.googleURL! + "\n").utf8).write(to: dir.appendingPathComponent("google_wallet_link.txt"))
        }
        return card
    }

    /// One member, for the detail screen (Apple and/or Google only).
    func generateSingle(_ m: Member, apple: Bool, google: Bool) async throws -> GeneratedCard {
        let cfg = effectiveConfig()
        let s = apple ? try makeSigner() : nil
        if apple && (cfg.applePassTypeId.isEmpty || cfg.appleTeamId.isEmpty) { throw AppleWalletError.missingIDs }
        let g = google ? try makeGoogle() : nil
        var warnings: [String] = []
        let card = try await generate(m, cfg: cfg, signer: s, google: g, warnings: &warnings)
        warnings.forEach(addLog)
        return card
    }

    func connectSMTP(_ cfg: AppConfig) async throws -> SMTPClient {
        guard !cfg.smtpHost.isEmpty else { throw SimpleError("Fill in the SMTP server on the Email tab.") }
        guard !(cfg.fromEmail.isEmpty && cfg.smtpUser.isEmpty) else { throw SimpleError("Fill in your email address on the Email tab.") }
        addLog("Connecting to \(cfg.smtpHost)…")
        let s = SMTPClient(host: cfg.smtpHost, port: cfg.smtpPort, useTLS: cfg.smtpSecurity != "None")
        try await s.connect()
        try await s.login(user: cfg.smtpUser, password: cfg.smtpPassword)
        return s
    }

    func fromAddress(_ c: AppConfig) -> String { c.fromEmail.isEmpty ? c.smtpUser : c.fromEmail }

    /// Generate (and optionally email) cards for a list of members, with a progress sheet.
    func run(_ list: [Member], send: Bool) {
        guard !busy, !list.isEmpty else { return }
        busy = true; showProgress = true; stopRequested = false; log = []; progress = 0
        progressTitle = send ? "Emailing cards…" : "Generating cards…"
        UIApplication.shared.isIdleTimerDisabled = true
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "cards") { [weak self] in
            Task { @MainActor in self?.endBackgroundWork() }
        }
        Task {
            await runBatch(list, send: send)
            busy = false
            UIApplication.shared.isIdleTimerDisabled = false
            endBackgroundWork()
        }
    }

    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private func endBackgroundWork() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    private func runBatch(_ list: [Member], send: Bool) async {
        let cfg = effectiveConfig()
        var signer: PassSigner?
        var google: GoogleWalletClient?
        var smtp: SMTPClient?
        do {
            if cfg.appleEnabled {
                signer = try makeSigner()
                if cfg.applePassTypeId.isEmpty || cfg.appleTeamId.isEmpty { throw AppleWalletError.missingIDs }
            }
            if cfg.googleEnabled {
                let g = try makeGoogle()
                addLog("Google Wallet: checking pass class…")
                try await g.ensureClass()
                google = g
            }
            if !cfg.appleEnabled && !cfg.googleEnabled { addLog("Apple and Google Wallet are both off – making card images only.") }
            if send { smtp = try await connectSMTP(cfg) }
        } catch {
            addLog("✗ \(error.localizedDescription)")
            progressTitle = "Setup problem – see below"
            await smtp?.close()
            return
        }
        var ok = 0, fail = 0
        for (i, m) in list.enumerated() {
            if stopRequested { addLog("Stopped."); break }
            progress = Double(i) / Double(list.count)
            progressTitle = "\(i + 1) of \(list.count): \(m.fullName)"
            if send && !m.emailValid { addLog("✗ \(m.fullName): invalid email '\(m.email)' – skipped"); fail += 1; continue }
            do {
                var warnings: [String] = []
                let card = try await generate(m, cfg: cfg, signer: signer, google: google, warnings: &warnings)
                warnings.forEach(addLog)
                let parts = [card.pkpass != nil ? "Apple" : nil, card.googleURL != nil ? "Google" : nil].compactMap { $0 }
                let what = parts.isEmpty ? "image only" : parts.joined(separator: " + ")
                if send {
                    let msg = CardEmail.build(config: cfg, member: m, pkpass: card.pkpass, passFileName: cfg.passFileName(for: m),
                                              googleURL: card.googleURL, cardPNG: card.png)
                    do {
                        try await smtp?.send(from: fromAddress(cfg), to: [m.email], message: msg)
                    } catch {
                        addLog("  … connection lost, reconnecting")
                        await smtp?.close()
                        smtp = try await connectSMTP(cfg)
                        try await smtp?.send(from: fromAddress(cfg), to: [m.email], message: msg)
                    }
                    markSent(m)
                    addLog("✓ \(m.fullName) <\(m.email)> – emailed (\(what))")
                    if cfg.sendDelaySeconds > 0 && i < list.count - 1 {
                        try? await Task.sleep(nanoseconds: UInt64(cfg.sendDelaySeconds) * 1_000_000_000)
                    }
                } else {
                    addLog("✓ \(m.fullName) – card made (\(what))")
                }
                ok += 1
            } catch {
                fail += 1
                addLog("✗ \(m.fullName): \(error.localizedDescription)")
            }
        }
        await smtp?.close()
        progress = 1
        progressTitle = "Done: \(ok) \(send ? "emailed" : "made")" + (fail > 0 ? ", \(fail) failed" : "")
        addLog(progressTitle)
    }

    func sendTestEmail(using member: Member?) {
        let to = fromAddress(config)
        guard !to.isEmpty else { show("Email", "Fill in your email address first."); return }
        var m = member ?? members.first ?? Member(reg: "123", name: "Ana", surname: "Example", email: to)
        m.email = to
        let target = m
        busy = true; showProgress = true; log = []; progress = 0
        progressTitle = "Sending a test email to \(to)…"
        Task {
            defer { busy = false }
            do {
                var cfg = effectiveConfig()
                cfg.emailSubject = "[TEST] " + cfg.emailSubject
                var warnings: [String] = []
                let signer = cfg.appleEnabled ? try makeSigner() : nil
                let google = cfg.googleEnabled ? try makeGoogle() : nil
                let card = try await generate(target, cfg: cfg, signer: signer, google: google, warnings: &warnings)
                warnings.forEach(addLog)
                let smtp = try await connectSMTP(cfg)
                let msg = CardEmail.build(config: cfg, member: target, pkpass: card.pkpass, passFileName: cfg.passFileName(for: target),
                                          googleURL: card.googleURL, cardPNG: card.png)
                try await smtp.send(from: fromAddress(cfg), to: [to], message: msg)
                await smtp.close()
                progress = 1
                progressTitle = "Test email sent to \(to) ✓"
                addLog(progressTitle)
            } catch {
                progressTitle = "Test email failed"
                addLog("✗ \(error.localizedDescription)")
            }
        }
    }

    // MARK: transfer file / settings
    func openTransfer(_ data: Data, password: String? = nil) {
        do {
            let b = try ClubBundle(data: data, password: password)
            var c = b.config
            let roles: [(String, Asset)] = [("logo", .logo), ("background", .background), ("apple_p12", .appleP12),
                                            ("apple_cert", .appleCert), ("apple_key", .appleKey), ("apple_wwdr", .appleWWDR),
                                            ("google_service_account", .googleServiceAccount), ("members", .members)]
            for (role, a) in roles {
                if let f = b.files[role] { try setAsset(a, data: f.data, ext: URL(fileURLWithPath: f.name).pathExtension) }
            }
            if b.files["apple_cert"] != nil && b.files["apple_key"] != nil && b.files["apple_p12"] == nil { c.appleCertMode = "pem" }
            if b.files["apple_p12"] != nil && b.files["apple_cert"] == nil { c.appleCertMode = "p12" }
            if c.smtpPassword.isEmpty { c.smtpPassword = config.smtpPassword }
            if c.appleP12Password.isEmpty { c.appleP12Password = config.appleP12Password }
            c.photoOverrides = config.photoOverrides
            for (key, f) in b.photos {
                let name = "\(TextUtil.slugPart(key)).jpg"
                try f.data.write(to: photosDir.appendingPathComponent(name), options: .atomic)
                c.photoOverrides[key] = name
            }
            config = c
            if let mf = b.files["members"] {
                membersFileName = mf.name
                UserDefaults.standard.set(mf.name, forKey: "membersFileName")
            }
            loadMembersFromAsset()
            revision += 1
            pendingTransfer = nil
            show("Imported ✓", "Settings, \(b.files.count) files, \(b.photos.count) photos and \(members.count) members " +
                 "were imported from the Ubuntu app.")
        } catch BundleError.needsPassword {
            pendingTransfer = data
        } catch BundleError.wrongPassword {
            pendingTransfer = data
            show("Wrong password", "Try again.")
        } catch {
            pendingTransfer = nil
            show(error, title: "Import failed")
        }
    }

    func handleIncoming(_ url: URL) {
        do {
            let data = try Store.read(url)
            let ext = url.pathExtension.lowercased()
            if ext == "clubwallet" || ClubBundle.isEncrypted(data) { openTransfer(data); return }
            if ["ods", "xlsx", "csv"].contains(ext) { importMembers(data: data, fileName: url.lastPathComponent); return }
            if ext == "json", let c = try? AppConfig.decode(data) { config = c; show("Settings imported", "From \(url.lastPathComponent)."); return }
            openTransfer(data)
        } catch { show(error, title: "Could not open the file") }
    }

    func exportSettingsFile(includeSecrets: Bool) -> URL? {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("club-wallet-settings.json")
        guard (try? config.encoded(includeSecrets: includeSecrets).write(to: u, options: .atomic)) != nil else { return nil }
        return u
    }

    func importSettings(from url: URL) {
        do {
            var c = try AppConfig.decode(Store.read(url))
            if c.photoOverrides.isEmpty { c.photoOverrides = config.photoOverrides }
            config = c
            show("Settings imported", "From \(url.lastPathComponent).")
        } catch { show(error, title: "Not a settings file") }
    }

    func resetAll() {
        config = AppConfig()
        for a in Asset.allCases { removeAsset(a) }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: photosDir.path) {
            for n in names { try? FileManager.default.removeItem(at: photosDir.appendingPathComponent(n)) }
        }
        members = []; sent = [:]; saveSent(); membersFileName = ""
        revision += 1
    }
}
