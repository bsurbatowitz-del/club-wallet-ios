import Foundation
import Network

public struct MailPart {
    public var mimeType: String
    public var fileName: String
    public var data: Data
    public var contentID: String?
    public init(mimeType: String, fileName: String, data: Data, contentID: String? = nil) {
        self.mimeType = mimeType; self.fileName = fileName; self.data = data; self.contentID = contentID
    }
}

/// Builds a MIME message: mixed { alternative { text, related { html, inline images } }, attachments }.
public enum MIME {
    static func encodedWord(_ s: String) -> String {
        s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) ? s : "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    public static func address(_ name: String, _ email: String) -> String {
        guard !name.isEmpty else { return "<\(email)>" }
        let n = encodedWord(name)
        return n.hasPrefix("=?") ? "\(n) <\(email)>" : "\"\(n.replacingOccurrences(of: "\"", with: "'"))\" <\(email)>"
    }

    static func b64(_ d: Data) -> String {
        d.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    static func boundary() -> String { "=_cw_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }

    public static func build(from: (name: String, email: String), to: (name: String, email: String), replyTo: String?,
                             subject: String, text: String, html: String, inline: [MailPart], attachments: [MailPart],
                             date: Date = Date()) -> Data {
        let mixed = boundary(), alt = boundary(), rel = boundary()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let domain = from.email.split(separator: "@").last.map(String.init) ?? "localhost"
        var h = [
            "From: \(address(from.name, from.email))",
            "To: \(address(to.name, to.email))",
            "Subject: \(encodedWord(subject))",
            "Date: \(df.string(from: date))",
            "Message-ID: <\(UUID().uuidString)@\(domain)>",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"\(mixed)\"",
        ]
        if let r = replyTo, !r.isEmpty { h.insert("Reply-To: \(r)", at: 2) }
        var s = h.joined(separator: "\r\n") + "\r\n\r\n"
        s += "--\(mixed)\r\nContent-Type: multipart/alternative; boundary=\"\(alt)\"\r\n\r\n"
        s += "--\(alt)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        s += b64(Data(text.utf8)) + "\r\n"
        s += "--\(alt)\r\nContent-Type: multipart/related; boundary=\"\(rel)\"\r\n\r\n"
        s += "--\(rel)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        s += b64(Data(html.utf8)) + "\r\n"
        for p in inline {
            s += "--\(rel)\r\nContent-Type: \(p.mimeType)\r\nContent-Transfer-Encoding: base64\r\n"
            s += "Content-ID: <\(p.contentID ?? UUID().uuidString)>\r\n"
            s += "Content-Disposition: inline; filename=\"\(p.fileName)\"\r\n\r\n" + b64(p.data) + "\r\n"
        }
        s += "--\(rel)--\r\n"
        s += "--\(alt)--\r\n"
        for p in attachments {
            s += "--\(mixed)\r\nContent-Type: \(p.mimeType); name=\"\(p.fileName)\"\r\nContent-Transfer-Encoding: base64\r\n"
            s += "Content-Disposition: attachment; filename=\"\(p.fileName)\"\r\n\r\n" + b64(p.data) + "\r\n"
        }
        s += "--\(mixed)--\r\n"
        return Data(s.utf8)
    }

    public static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// The membership-card email (same content as the desktop app).
public enum CardEmail {
    public static func build(config c: AppConfig, member m: Member, pkpass: Data?, passFileName: String,
                             googleURL: String?, cardPNG: Data?) -> Data {
        var values = m.fields(c)
        values["pass_filename"] = passFileName
        let subject = TextUtil.fill(c.emailSubject, values)
        let body = TextUtil.fill(c.emailBody, values)
        var text = body
        if let g = googleURL { text += "\n\nAdd to Google Wallet: \(g)\n" }

        let paras = body.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n").map {
            "<p style='margin:0 0 12px'>\(MIME.escapeHTML($0).replacingOccurrences(of: "\n", with: "<br>"))</p>"
        }.joined()
        var buttons = ""
        if let g = googleURL {
            buttons += "<a href='\(MIME.escapeHTML(g))' style='display:inline-block;background:#1f1f1f;color:#fff;" +
                "text-decoration:none;padding:12px 22px;border-radius:24px;font-weight:600;font-family:Arial,sans-serif;" +
                "margin:6px 8px 6px 0'>&#10010; Add to Google Wallet</a>"
        }
        if pkpass != nil {
            buttons += "<div style='font-size:13px;color:#555;margin-top:6px'>Apple Wallet: open the attached " +
                "<b>\(MIME.escapeHTML(passFileName))</b> on your iPhone.</div>"
        }
        let cid = "card-\(UUID().uuidString)@clubwallet"
        let img = cardPNG == nil ? "" :
            "<p><img src='cid:\(cid)' alt='Membership card' width='420' style='max-width:100%;border-radius:14px'></p>"
        let bg = MIME.escapeHTML(RGB.parse(c.bgColor, default: RGB(r: 11, g: 60, b: 93)).hex)
        let html = """
        <!doctype html><html><body style="font-family:Arial,Helvetica,sans-serif;font-size:15px;color:#222;line-height:1.45">
        <div style="max-width:560px;margin:auto">
        <div style="background:\(bg);height:6px;border-radius:3px;margin-bottom:18px"></div>
        \(paras)
        <div style="margin:18px 0">\(buttons)</div>
        \(img)
        </div></body></html>
        """
        var inline: [MailPart] = []
        var attachments: [MailPart] = []
        if let png = cardPNG { inline.append(MailPart(mimeType: "image/png", fileName: "membership-card.png", data: png, contentID: cid)) }
        if let p = pkpass { attachments.append(MailPart(mimeType: "application/vnd.apple.pkpass", fileName: passFileName, data: p)) }
        if let png = cardPNG, c.attachPng { attachments.append(MailPart(mimeType: "image/png", fileName: "\(m.slug)-card.png", data: png)) }
        let fromEmail = c.fromEmail.isEmpty ? c.smtpUser : c.fromEmail
        return MIME.build(from: (c.fromName, fromEmail), to: (m.fullName, m.email), replyTo: c.replyTo,
                          subject: subject, text: text, html: html, inline: inline, attachments: attachments)
    }
}

public enum SMTPError: LocalizedError {
    case closed, timeout, server(Int, String)
    public var errorDescription: String? {
        switch self {
        case .closed: return "The mail server closed the connection."
        case .timeout: return "The mail server did not answer in time."
        case .server(let code, let text):
            var hint = ""
            if code == 535 || code == 534 { hint = " – for Gmail use an App password (myaccount.google.com/apppasswords)." }
            return "Mail server error \(code): \(text)\(hint)"
        }
    }
}

/// Small SMTP client (implicit TLS on port 465, or plain for testing).
public final class SMTPClient {
    public let host: String
    public let port: UInt16
    public let useTLS: Bool
    private var conn: NWConnection?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "club-wallet.smtp")

    public init(host: String, port: Int, useTLS: Bool) {
        self.host = host; self.port = UInt16(clamping: port); self.useTLS = useTLS
    }

    public func connect(timeout: TimeInterval = 30) async throws {
        let params: NWParameters = useTLS ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()) : .tcp
        guard let p = NWEndpoint.Port(rawValue: port) else { throw SMTPError.closed }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        conn = c
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var done = false
            func finish(_ r: Result<Void, Error>) {
                lock.lock(); defer { lock.unlock() }
                if done { return }
                done = true
                cont.resume(with: r)
            }
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let e): finish(.failure(e))
                case .waiting(let e): c.cancel(); finish(.failure(e))
                case .cancelled: finish(.failure(SMTPError.closed))
                default: break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                lock.lock(); let alreadyDone = done; lock.unlock()
                if !alreadyDone { c.cancel(); finish(.failure(SMTPError.timeout)) }
            }
        }
        _ = try await expect([220])
        let (code, _) = try await command("EHLO club-wallet.local")
        if code != 250 { _ = try await command("HELO club-wallet.local", expect: [250]) }
    }

    private func receive() async throws -> Data {
        guard let c = conn else { throw SMTPError.closed }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(throwing: SMTPError.closed) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    private func readResponse() async throws -> (Int, String) {
        var lines: [String] = []
        let crlf = Data("\r\n".utf8)
        while true {
            if let r = buffer.range(of: crlf) {
                let line = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
                buffer = Data(buffer[r.upperBound...])
                lines.append(line)
                let chars = Array(line)
                if chars.count < 4 || chars[3] == " " {
                    return (Int(String(chars.prefix(3))) ?? 0, lines.joined(separator: " "))
                }
                continue
            }
            buffer.append(try await receive())
        }
    }

    private func write(_ d: Data) async throws {
        guard let c = conn else { throw SMTPError.closed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: d, completion: .contentProcessed { e in
                if let e { cont.resume(throwing: e) } else { cont.resume() }
            })
        }
    }

    private func expect(_ codes: Set<Int>) async throws -> String {
        let (code, text) = try await readResponse()
        guard codes.contains(code) else { throw SMTPError.server(code, text) }
        return text
    }

    @discardableResult
    private func command(_ line: String) async throws -> (Int, String) {
        try await write(Data((line + "\r\n").utf8))
        return try await readResponse()
    }

    @discardableResult
    private func command(_ line: String, expect codes: Set<Int>) async throws -> String {
        let (code, text) = try await command(line)
        guard codes.contains(code) else { throw SMTPError.server(code, text) }
        return text
    }

    public func login(user: String, password: String) async throws {
        guard !user.isEmpty else { return }
        let token = Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
        try await command("AUTH PLAIN \(token)", expect: [235])
    }

    public func send(from: String, to: [String], message: Data) async throws {
        try await command("MAIL FROM:<\(from)>", expect: [250])
        for r in to { try await command("RCPT TO:<\(r)>", expect: [250, 251]) }
        try await command("DATA", expect: [354])
        var body = message
        if body.first == UInt8(ascii: ".") { body.insert(UInt8(ascii: "."), at: 0) }
        body = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\r\n.", with: "\r\n..").utf8)
        try await write(body + Data("\r\n.\r\n".utf8))
        _ = try await expect([250])
    }

    public func close() async {
        if conn != nil { _ = try? await command("QUIT") }
        conn?.cancel()
        conn = nil
    }
}
