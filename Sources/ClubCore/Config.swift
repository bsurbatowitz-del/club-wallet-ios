import Foundation

public let defaultEmailBody = """
Hi {name},

Your {club} membership card for {season} is ready!

iPhone: open the attached file "{pass_filename}" and tap "Add" to put the card in Apple Wallet.
Android: tap the "Add to Google Wallet" button below.

Your card shows a QR code with your registration number ({reg}), name and email.
The card image is also attached in case you want to print it.

See you at training!
{club}
"""

/// All settings. JSON keys are snake_case and match the Ubuntu app, so its saved
/// configuration files can be imported directly. Unknown keys are ignored.
public struct AppConfig: Codable, Equatable {
    // card design
    public var clubName = "Triathlon Club"
    public var cardTitle = "Membership Card"
    public var season = "2026"
    public var expirationDate = ""
    public var bgColor = "#0B3C5D"
    public var fgColor = "#FFFFFF"
    public var labelColor = "#9FD3F5"
    public var bgOverlay = 35
    public var bgAutoColor = true
    public var photosEnabled = true
    public var qrTemplate = "Reg: {reg}\nName: {name}\nSurname: {surname}\nEmail: {email}"
    public var photoOverrides: [String: String] = [:]   // member key -> photo file name in the app
    public var bloodEnabled = true                       // print Blood type / Rh from the member list
    public var bloodHidden: [String: [String]] = [:]     // member key -> ["blood", "rh"] hidden on that card

    // Apple Wallet
    public var appleEnabled = true
    public var applePassTypeId = ""
    public var appleTeamId = ""
    public var appleLayout = "storeCard"      // generic | eventTicket | storeCard
    public var appleCertMode = "pem"          // p12 | pem
    public var appleP12Password = ""

    // Google Wallet
    public var googleEnabled = true
    public var googleIssuerId = ""
    public var googleClassSuffix = "membership"
    public var googleLogoUrl = ""
    public var googleHeroUrl = ""

    // Email
    public var smtpHost = "smtp.gmail.com"
    public var smtpPort = 465
    public var smtpSecurity = "SSL"           // SSL | None
    public var smtpUser = ""
    public var smtpPassword = ""
    public var fromName = "Triathlon Club"
    public var fromEmail = ""
    public var replyTo = ""
    public var emailSubject = "Your {club} membership card"
    public var emailBody = defaultEmailBody
    public var attachPng = true
    public var sendDelaySeconds = 2

    public init() {}

    enum CodingKeys: String, CodingKey {
        case clubName, cardTitle, season, expirationDate, bgColor, fgColor, labelColor, bgOverlay, bgAutoColor
        case photosEnabled, qrTemplate, photoOverrides, bloodEnabled, bloodHidden
        case appleEnabled, applePassTypeId, appleTeamId, appleLayout, appleCertMode, appleP12Password
        case googleEnabled, googleIssuerId, googleClassSuffix, googleLogoUrl, googleHeroUrl
        case smtpHost, smtpPort, smtpSecurity, smtpUser, smtpPassword, fromName, fromEmail, replyTo
        case emailSubject, emailBody, attachPng, sendDelaySeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        func str(_ k: CodingKeys, _ def: String) -> String {
            if let v = try? c.decodeIfPresent(String.self, forKey: k) { return v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: k) { return String(v) }
            return def
        }
        func int(_ k: CodingKeys, _ def: Int) -> Int {
            if let v = try? c.decodeIfPresent(Int.self, forKey: k) { return v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: k) { return Int(v) }
            if let v = try? c.decodeIfPresent(String.self, forKey: k), let i = Int(v.trimmingCharacters(in: .whitespaces)) { return i }
            return def
        }
        func bool(_ k: CodingKeys, _ def: Bool) -> Bool {
            if let v = try? c.decodeIfPresent(Bool.self, forKey: k) { return v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: k) { return v != 0 }
            return def
        }
        clubName = str(.clubName, d.clubName)
        cardTitle = str(.cardTitle, d.cardTitle)
        season = str(.season, d.season)
        expirationDate = str(.expirationDate, d.expirationDate)
        bgColor = str(.bgColor, d.bgColor)
        fgColor = str(.fgColor, d.fgColor)
        labelColor = str(.labelColor, d.labelColor)
        bgOverlay = int(.bgOverlay, d.bgOverlay)
        bgAutoColor = bool(.bgAutoColor, d.bgAutoColor)
        photosEnabled = bool(.photosEnabled, d.photosEnabled)
        qrTemplate = str(.qrTemplate, d.qrTemplate)
        photoOverrides = (try? c.decodeIfPresent([String: String].self, forKey: .photoOverrides)) ?? [:]
        bloodEnabled = bool(.bloodEnabled, d.bloodEnabled)
        bloodHidden = (try? c.decodeIfPresent([String: [String]].self, forKey: .bloodHidden)) ?? [:]
        appleEnabled = bool(.appleEnabled, d.appleEnabled)
        applePassTypeId = str(.applePassTypeId, d.applePassTypeId)
        appleTeamId = str(.appleTeamId, d.appleTeamId)
        appleLayout = str(.appleLayout, d.appleLayout)
        appleCertMode = str(.appleCertMode, d.appleCertMode)
        appleP12Password = str(.appleP12Password, d.appleP12Password)
        googleEnabled = bool(.googleEnabled, d.googleEnabled)
        googleIssuerId = str(.googleIssuerId, d.googleIssuerId)
        googleClassSuffix = str(.googleClassSuffix, d.googleClassSuffix)
        googleLogoUrl = str(.googleLogoUrl, d.googleLogoUrl)
        googleHeroUrl = str(.googleHeroUrl, d.googleHeroUrl)
        smtpHost = str(.smtpHost, d.smtpHost)
        smtpPort = int(.smtpPort, d.smtpPort)
        smtpSecurity = str(.smtpSecurity, d.smtpSecurity)
        smtpUser = str(.smtpUser, d.smtpUser)
        smtpPassword = str(.smtpPassword, d.smtpPassword)
        fromName = str(.fromName, d.fromName)
        fromEmail = str(.fromEmail, d.fromEmail)
        replyTo = str(.replyTo, d.replyTo)
        emailSubject = str(.emailSubject, d.emailSubject)
        emailBody = str(.emailBody, d.emailBody)
        attachPng = bool(.attachPng, d.attachPng)
        sendDelaySeconds = int(.sendDelaySeconds, d.sendDelaySeconds)
    }

    public static func decode(_ data: Data) throws -> AppConfig {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(AppConfig.self, from: data)
    }

    public func encoded(includeSecrets: Bool = true) throws -> Data {
        var copy = self
        if !includeSecrets { copy.smtpPassword = ""; copy.appleP12Password = "" }
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(copy)
    }

    public func qrText(for m: Member) -> String {
        TextUtil.fill(qrTemplate.replacingOccurrences(of: "\\n", with: "\n"), m.fields(self))
    }

    /// Blood type and Rh to print on this member's card (nil when empty or switched off).
    public func bloodFields(for m: Member) -> (blood: String?, rh: String?) {
        guard bloodEnabled else { return (nil, nil) }
        let hidden = bloodHidden[m.key] ?? []
        return (m.bloodType.isEmpty || hidden.contains("blood") ? nil : m.bloodType,
                m.rh.isEmpty || hidden.contains("rh") ? nil : m.rh)
    }

    public func isBloodShown(_ field: String, for m: Member) -> Bool {
        !(bloodHidden[m.key] ?? []).contains(field)
    }

    public mutating func setBlood(_ field: String, shown: Bool, for m: Member) {
        var list = Set(bloodHidden[m.key] ?? [])
        if shown { list.remove(field) } else { list.insert(field) }
        bloodHidden[m.key] = list.isEmpty ? nil : list.sorted()
    }

    public func passFileName(for m: Member) -> String {
        let club = TextUtil.slugPart(clubName)
        return "\(club.isEmpty ? "club" : club)-\(m.slug).pkpass"
    }
}
