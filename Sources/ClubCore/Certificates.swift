import Foundation
import Security
import CryptoKit

public enum KeyError: LocalizedError {
    case encryptedKey, badKey(String), p12(String), mismatch, missing(String)
    public var errorDescription: String? {
        switch self {
        case .encryptedKey: return "The private key is password-protected. Use the .p12 file instead, or an unencrypted .pem key."
        case .badKey(let s): return "Could not use the private key: \(s)"
        case .p12(let s): return "Could not open the .p12 file: \(s)"
        case .mismatch: return "The private key does not belong to this pass certificate."
        case .missing(let s): return s
        }
    }
}

/// Fields we need from an X.509 certificate.
public struct CertificateInfo {
    public let der: [UInt8]
    public let issuerDER: [UInt8]
    public let serialDER: [UInt8]
    public let subject: [String: String]
    public let notAfter: Date?

    public var passTypeID: String? { subject["0.9.2342.19200300.100.1.1"] }  // UID
    public var teamID: String? { subject["2.5.4.11"] }                      // OU
    public var commonName: String? { subject["2.5.4.3"] }
    public var organization: String? { subject["2.5.4.10"] }

    public init(der: [UInt8]) throws {
        let (cert, _) = try DERNode.parse(der)
        guard cert.tag == 0x30, let tbs = try cert.children().first else { throw DERError.unexpected("not a certificate") }
        var f = try tbs.children()
        if f.first?.tag == 0xA0 { f.removeFirst() }   // explicit version
        guard f.count >= 6 else { throw DERError.unexpected("short certificate") }
        var subj: [String: String] = [:]
        for rdn in try f[4].children() {
            for atv in try rdn.children() {
                let kv = try atv.children()
                if kv.count == 2, let o = kv[0].oidString, let s = kv[1].stringValue { subj[o] = s }
            }
        }
        let validity = try f[3].children()
        self.der = der
        self.serialDER = f[0].bytes
        self.issuerDER = f[2].bytes
        self.subject = subj
        self.notAfter = validity.count > 1 ? validity[1].dateValue : nil
    }

    /// Accepts .cer/.der (binary) or .pem.
    public init(data: Data) throws {
        try self.init(der: PEM.der(data, types: ["CERTIFICATE", "TRUSTED CERTIFICATE"]))
    }

    public var publicKeyData: Data? {
        guard let c = SecCertificateCreateWithData(nil, Data(der) as CFData), let k = SecCertificateCopyKey(c) else { return nil }
        return SecKeyCopyExternalRepresentation(k, nil) as Data?
    }
}

public enum Keys {
    /// RSA private key from PEM (PKCS#1 "RSA PRIVATE KEY" or PKCS#8 "PRIVATE KEY") or DER.
    public static func rsaPrivateKey(_ data: Data) throws -> SecKey {
        var pkcs1: [UInt8]
        if PEM.isPEM(data), let s = String(data: data, encoding: .utf8) {
            if s.contains("ENCRYPTED") { throw KeyError.encryptedKey }
            let blocks = PEM.blocks(s)
            if let b = blocks.first(where: { $0.type == "RSA PRIVATE KEY" }) {
                pkcs1 = b.der
            } else if let b = blocks.first(where: { $0.type == "PRIVATE KEY" }) {
                pkcs1 = try pkcs8ToPKCS1(b.der)
            } else {
                throw KeyError.badKey("no PRIVATE KEY block found")
            }
        } else {
            let raw = [UInt8](data)
            pkcs1 = (try? pkcs8ToPKCS1(raw)) ?? raw
        }
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attrs as CFDictionary, &err) else {
            throw KeyError.badKey(err?.takeRetainedValue().localizedDescription ?? "unknown error")
        }
        return key
    }

    static func pkcs8ToPKCS1(_ der: [UInt8]) throws -> [UInt8] {
        let (top, _) = try DERNode.parse(der)
        let c = try top.children()
        guard c.count >= 3, c[0].tag == 0x02, c[1].tag == 0x30, c[2].tag == 0x04 else {
            throw KeyError.badKey("not a PKCS#8 key")
        }
        return c[2].content
    }

    public static func sign(_ data: Data, key: SecKey) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &err) as Data? else {
            throw KeyError.badKey(err?.takeRetainedValue().localizedDescription ?? "signing failed")
        }
        return sig
    }

    public static func publicKeyData(_ key: SecKey) -> Data? {
        guard let pub = SecKeyCopyPublicKey(key) else { return nil }
        return SecKeyCopyExternalRepresentation(pub, nil) as Data?
    }

    /// Private key + certificate (DER) from a .p12 file.
    public static func p12(_ data: Data, password: String) throws -> (SecKey, [UInt8]) {
        var items: CFArray?
        let opts = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, opts, &items)
        guard status == errSecSuccess else {
            throw KeyError.p12(status == errSecAuthFailed ? "wrong password" : "error \(status)")
        }
        guard let arr = items as? [[String: Any]], let first = arr.first,
              let idRef = first[kSecImportItemIdentity as String] else { throw KeyError.p12("no certificate inside") }
        let identity = idRef as! SecIdentity  // swiftlint:disable:this force_cast
        var key: SecKey?
        var cert: SecCertificate?
        SecIdentityCopyPrivateKey(identity, &key)
        SecIdentityCopyCertificate(identity, &cert)
        guard let k = key, let c = cert else { throw KeyError.p12("no private key inside") }
        return (k, [UInt8](SecCertificateCopyData(c) as Data))
    }
}

/// Everything needed to sign Apple Wallet passes.
public struct PassSigner {
    public let certificate: CertificateInfo
    public let key: SecKey
    public let wwdr: CertificateInfo

    public init(certificate: CertificateInfo, key: SecKey, wwdr: CertificateInfo) throws {
        if let a = certificate.publicKeyData, let b = Keys.publicKeyData(key), a != b { throw KeyError.mismatch }
        self.certificate = certificate; self.key = key; self.wwdr = wwdr
    }

    public static func fromP12(_ p12: Data, password: String, wwdr: Data) throws -> PassSigner {
        let (key, der) = try Keys.p12(p12, password: password)
        return try PassSigner(certificate: CertificateInfo(der: der), key: key, wwdr: CertificateInfo(data: wwdr))
    }

    public static func fromPEM(certificate: Data, key: Data, wwdr: Data) throws -> PassSigner {
        try PassSigner(certificate: CertificateInfo(data: certificate), key: Keys.rsaPrivateKey(key),
                       wwdr: CertificateInfo(data: wwdr))
    }
}

/// CMS (PKCS#7) detached signature, as Apple Wallet expects for manifest.json.
public enum CMS {
    static let oidData = "1.2.840.113549.1.7.1"
    static let oidSignedData = "1.2.840.113549.1.7.2"
    static let oidSHA256 = "2.16.840.1.101.3.4.2.1"
    static let oidRSA = "1.2.840.113549.1.1.1"
    static let oidContentType = "1.2.840.113549.1.9.3"
    static let oidMessageDigest = "1.2.840.113549.1.9.4"
    static let oidSigningTime = "1.2.840.113549.1.9.5"

    public static func detachedSignature(content: Data, signer: PassSigner, date: Date = Date()) throws -> Data {
        let digest = [UInt8](SHA256.hash(data: content))
        let sha256 = DER.seq(DER.oid(oidSHA256), DER.null)
        var attrs = [
            DER.seq(DER.oid(oidContentType), DER.set(DER.oid(oidData))),
            DER.seq(DER.oid(oidSigningTime), DER.set(DER.utcTime(date))),
            DER.seq(DER.oid(oidMessageDigest), DER.set(DER.octets(digest))),
        ]
        attrs.sort { $0.lexicographicallyPrecedes($1) }   // DER "SET OF" order
        let attrBytes = attrs.flatMap { $0 }
        let signature = try Keys.sign(Data(DER.tlv(0x31, attrBytes)), key: signer.key)

        let signerInfo = DER.seq(
            DER.int(1),
            DER.seq(signer.certificate.issuerDER, signer.certificate.serialDER),
            sha256,
            DER.tlv(0xA0, attrBytes),
            DER.seq(DER.oid(oidRSA), DER.null),
            DER.octets([UInt8](signature))
        )
        let signedData = DER.seq(
            DER.int(1),
            DER.set(sha256),
            DER.seq(DER.oid(oidData)),
            DER.tlv(0xA0, signer.certificate.der + signer.wwdr.der),
            DER.set(signerInfo)
        )
        return Data(DER.seq(DER.oid(oidSignedData), DER.tlv(0xA0, signedData)))
    }
}
