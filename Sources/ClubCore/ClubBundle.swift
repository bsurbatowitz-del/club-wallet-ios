import Foundation
import CryptoKit
import CommonCrypto

public enum BundleError: LocalizedError {
    case notBundle, needsPassword, wrongPassword
    public var errorDescription: String? {
        switch self {
        case .notBundle: return "This is not a Club Wallet transfer file (.clubwallet)."
        case .needsPassword: return "This transfer file is protected with a password."
        case .wrongPassword: return "Wrong password for the transfer file."
        }
    }
}

/// The ".clubwallet" transfer file made by the Ubuntu app (File → Export for iPhone app…):
/// settings + certificates/keys + logo/background + member list + member photos, optionally encrypted.
public struct ClubBundle {
    public struct File { public let name: String; public let data: Data }

    public let config: AppConfig
    public let files: [String: File]     // logo, background, apple_p12, apple_cert, apple_key, apple_wwdr, google_service_account, members
    public let photos: [String: File]    // member key (reg. number) -> photo

    public static func isEncrypted(_ data: Data) -> Bool {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (o["format"] as? String) == "club-wallet-bundle-encrypted"
    }

    public init(data: Data, password: String? = nil) throws {
        guard var top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = top["format"] as? String else { throw BundleError.notBundle }
        if format == "club-wallet-bundle-encrypted" {
            guard let pw = password, !pw.isEmpty else { throw BundleError.needsPassword }
            let plain = try ClubBundle.decrypt(top, password: pw)
            guard let inner = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw BundleError.notBundle }
            top = inner
        } else if format != "club-wallet-bundle" {
            throw BundleError.notBundle
        }
        let cfgDict = (top["config"] as? [String: Any]) ?? [:]
        config = try AppConfig.decode(JSONSerialization.data(withJSONObject: cfgDict))
        func files(_ key: String) -> [String: File] {
            var out: [String: File] = [:]
            for (k, v) in (top[key] as? [String: Any]) ?? [:] {
                guard let o = v as? [String: Any], let b64 = o["data"] as? String,
                      let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { continue }
                out[k] = File(name: (o["name"] as? String) ?? k, data: d)
            }
            return out
        }
        self.files = files("files")
        self.photos = files("photos")
    }

    static func decrypt(_ o: [String: Any], password: String) throws -> Data {
        guard let salt = (o["salt"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let nonce = (o["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let ct = (o["ciphertext"] as? String).flatMap({ Data(base64Encoded: $0) }), ct.count > 16 else {
            throw BundleError.notBundle
        }
        let iterations = (o["iterations"] as? Int) ?? 200_000
        let key = pbkdf2SHA256(password: password, salt: salt, iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                            ciphertext: ct.prefix(ct.count - 16), tag: ct.suffix(16))
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw BundleError.wrongPassword
        }
    }

    public static func pbkdf2SHA256(password: String, salt: Data, iterations: Int, length: Int = 32) -> Data {
        var out = [UInt8](repeating: 0, count: length)
        let pw = Array(password.utf8).map { CChar(bitPattern: $0) }
        let saltBytes = [UInt8](salt)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count, saltBytes, saltBytes.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, length)
        return Data(out)
    }
}
