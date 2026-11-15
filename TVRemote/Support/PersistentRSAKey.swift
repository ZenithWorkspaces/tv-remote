import Foundation
import Security

enum PersistentRSAKey {
    static func loadOrCreate(tag: String) -> SecKey? {
        if let existing = load(tag: tag) { return existing }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data(tag.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        return SecKeyCreateRandomKey(attributes as CFDictionary, nil)
    }

    static func load(tag: String) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecKey)
    }

    static func delete(tag: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8)
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func pkcs1PublicKey(_ privateKey: SecKey) -> Data? {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { return nil }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else { return nil }
        return data
    }

    static func modulusAndExponent(_ privateKey: SecKey) -> (Data, Int)? {
        guard let pkcs1 = pkcs1PublicKey(privateKey),
              let numbers = ASN1.rsaNumbers(in: pkcs1),
              let exponent = integerValue(numbers.exponent) else { return nil }
        return (numbers.modulus, exponent)
    }

    static func signRaw(_ data: Data, key: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureRaw, data as CFData, &error) as Data? else { return nil }
        return signature
    }

    private static func integerValue(_ magnitude: Data) -> Int? {
        guard magnitude.count <= 4 else { return nil }
        var value = 0
        for byte in magnitude {
            value = (value << 8) | Int(byte)
        }
        return value
    }
}

enum ClientCertificate {
    static let commonName = "No Ads Remote"

    static func certificateDER(key: SecKey, name: String = commonName) -> Data? {
        guard let pkcs1 = PersistentRSAKey.pkcs1PublicKey(key) else { return nil }
        let algorithm = sha256WithRSA()
        let spki = subjectPublicKeyInfo(pkcs1)
        let now = utc("260101000000Z")
        let later = utc("450101000000Z")
        let validity = ASN1.sequence(now + later)
        let subject = distinguishedName(name)
        var body = Data()
        body.append(ASN1.raw(0xA0, ASN1.integer(2)))
        body.append(ASN1.integer(1))
        body.append(algorithm)
        body.append(subject)
        body.append(validity)
        body.append(subject)
        body.append(spki)
        let tbs = ASN1.sequence(body)
        guard let signature = sign(tbs, key: key) else { return nil }
        let certificate = ASN1.sequence(tbs + algorithm + ASN1.bitString(signature))
        guard SecCertificateCreateWithData(nil, certificate as CFData) != nil else { return nil }
        return certificate
    }

    static func identity(certificateDER: Data, key: SecKey) -> sec_identity_t? {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else { return nil }
        return sec_identity_create(certificate, key)
    }

    private static func subjectPublicKeyInfo(_ pkcs1: Data) -> Data {
        let algorithm = ASN1.sequence(ASN1.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]) + ASN1.null())
        return ASN1.sequence(algorithm + ASN1.bitString(pkcs1))
    }

    private static func distinguishedName(_ name: String) -> Data {
        let attribute = ASN1.sequence(ASN1.oid([0x55, 0x04, 0x03]) + ASN1.utf8(name))
        return ASN1.sequence(ASN1.raw(0x31, attribute))
    }

    private static func sha256WithRSA() -> Data {
        ASN1.sequence(ASN1.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]) + ASN1.null())
    }

    private static func utc(_ text: String) -> Data {
        ASN1.raw(0x17, Data(text.utf8))
    }

    private static func sign(_ tbs: Data, key: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) as Data? else {
            return nil
        }
        return signature
    }
}
