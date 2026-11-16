import Foundation
import CommonCrypto

/// 2014–2015 Samsung H/J encrypted remote (port 8080 pairing, port 8000 socket.io).
/// The AES steps match samsungctl's encrypted method and SmartCrypto.
enum SamsungEncrypted {
    static let appID = "654321"
    static let userID = "654321"
    static let deviceID = "7e509404-9d7c-46b4-8f6a-e2a9668ad184"
    static let pairingPort = 8080
    static let socketPort = 8000

    static let publicKey = Data(hex: """
    2cb12bb2cbf7cec713c0fff7b59ae68a96784ae517f41d259a45d20556177c0ffe951ca60\
    ec03a990c9412619d1bee30adc7773088c5721664cffcedacf6d251cb4b76e2fd7aef09b3\
    ae9f9496ac8d94ed2b262eee37291c8b237e880cc7c021fb1be0881f3d0bffa4234d3b8e6\
    a61530c00473ce169c025f47fcc001d9b8051
    """)!
    static let privateKey = Data(hex: """
    2fd6334713816fae018cdee4656c5033a8d6b00e8eaea07b3624999242e96247112dcd019\
    c4191f4643c3ce1605002b2e506e7f1d1ef8d9b8044e46d37c0d5263216a87cd783aa1854\
    90436c4a0cb2c524e15bc1bfeae703bcbc4b74a0540202e8d79cadaae85c6f9c218bc1107\
    d1f5b4b9bd87160e782f4e436eeb17485ab4d
    """)!
    static let prime = Data(hex: """
    b361eb0ab01c3439f2c16ffda7b05e3e320701ebee3e249123c3586765fd5bf6c1dfa88bb\
    6bb5da3fde74737cd88b6a26c5ca31d81d18e3515533d08df619317063224cf0943a2f29a\
    5fe60c1c31ddf28334ed76a6478a1122fb24c4a94c8711617ddfe90cf02e643cd82d4748d\
    6d4a7ca2f47d88563aa2baf6482e124acd7dd
    """)!
    static let wbKey = Data(hex: "abbb120c09e7114243d1fa0102163b27")!
    static let transKey = Data(hex: "6c9474469ddf7578f3e5ad8a4c703d99")!

    struct Hello {
        var serverHello: Data
        var hash: Data
        var aesKey: Data
    }

    struct Session {
        var context: Data
        var skPrime: Data
    }

    static func serverHello(userID: String = SamsungEncrypted.userID, pin: String) -> Hello? {
        let pinHash = Data(SHA1(Data(pin.utf8)).prefix(16))
        guard let encrypted = AES128.cbc(publicKey, key: pinHash, iv: Data(repeating: 0, count: 16), encrypt: true),
              let swapped = AES128.ecb(encrypted, key: wbKey, encrypt: true) else { return nil }
        var body = Data()
        body.appendUInt32BE(UInt32(userID.utf8.count))
        body.append(Data(userID.utf8))
        body.append(swapped)
        let hash = Data(SHA1(body))
        var hello = Data([0x01, 0x02])
        hello.append(Data(repeating: 0, count: 5))
        hello.appendUInt32BE(UInt32(userID.utf8.count + 132))
        hello.append(body)
        hello.append(Data(repeating: 0, count: 5))
        return Hello(serverHello: hello, hash: hash, aesKey: pinHash)
    }

    static func parseClientHello(_ hex: String, hash: Data, aesKey: Data, userID: String = SamsungEncrypted.userID) -> Session? {
        guard let data = Data(hex: hex), data.count > 20 else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count >= 15 else { return nil }
        let userLen = Int(UInt32(bytes[11]) << 24 | UInt32(bytes[12]) << 16 | UInt32(bytes[13]) << 8 | UInt32(bytes[14]))
        let gxStart = 15 + userLen
        let gxEnd = gxStart + 128
        let hashEnd = gxEnd + 20
        guard userLen > 0, hashEnd <= bytes.count else { return nil }
        let tvUser = Data(bytes[15..<gxStart])
        let wrapped = Data(bytes[gxStart..<gxEnd])
        guard let encoded = AES128.ecb(wrapped, key: wbKey, encrypt: false),
              let gx = AES128.cbc(encoded, key: aesKey, iv: Data(repeating: 0, count: 16), encrypt: false) else { return nil }
        let secret = sharedSecret(gx)
        let expected = Data(SHA1(tvUser + secret))
        guard Data(bytes[gxEnd..<hashEnd]) == expected else { return nil }
        let flag = hashEnd
        guard flag < bytes.count, bytes[flag] == 0 else { return nil }
        guard flag + 5 <= bytes.count else { return nil }
        let second = bytes[(flag + 1)..<(flag + 5)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard second == 0 else { return nil }
        let final = tvUser + Data(userID.utf8) + gx + publicKey + secret
        let skPrime = Data(SHA1(final))
        let ctxSource = Data(SHA1(skPrime + Data([0x00])).prefix(16))
        guard let ctx = AES128.ecb(ctxSource, key: transKey, encrypt: true) else { return nil }
        return Session(context: ctx, skPrime: skPrime)
    }

    static func serverAcknowledge(skPrime: Data) -> String {
        let hash = Data(SHA1(skPrime + Data([0x01]))).hex.uppercased()
        return "0103000000000000000014" + hash + "0000000000"
    }

    static func clientAcknowledgeMatches(_ ack: String, skPrime: Data) -> Bool {
        let hash = Data(SHA1(skPrime + Data([0x02]))).hex.uppercased()
        return ack.uppercased() == "0104000000000000000014" + hash + "0000000000"
    }

    static func stepURL(host: String, step: Int, type: Int? = nil) -> URL? {
        var parts = "http://\(host):\(pairingPort)/ws/pairing?step=\(step)&app_id=\(appID)&device_id=\(deviceID)"
        if let type { parts += "&type=\(type)" }
        return URL(string: parts)
    }

    static func pinPageURL(host: String) -> URL? {
        URL(string: "http://\(host):\(pairingPort)/ws/apps/CloudPINPage")
    }

    static func commandPlaintext(key: String) -> String {
        "{\"method\": \"POST\", \"body\": {\"plugin\": \"RemoteControl\", \"param1\": \"uuid:12345\", \"param2\": \"Click\", \"param3\": \"\(key)\", \"param4\": false, \"api\": \"SendRemoteKey\", \"version\": \"1.000\"}}"
    }

    static func socketMessage(key: String, context: Data, sessionID: String) -> String? {
        guard let cipher = AES128.ecb(pkcs7(Data(commandPlaintext(key: key).utf8)), key: context, encrypt: true) else { return nil }
        let ints = cipher.map { Int($0) }
        let body = ints.map(String.init).joined(separator: ", ")
        return "5::/com.samsung.companion:{\"name\": \"callCommon\", \"args\": [{\"Session_Id\": \"\(sessionID)\", \"body\": [\(body)]}]}"
    }

    static func keyName(for key: RemoteKey) -> String? {
        switch key {
        case .up: return "KEY_UP"
        case .down: return "KEY_DOWN"
        case .left: return "KEY_LEFT"
        case .right: return "KEY_RIGHT"
        case .ok, .enter: return "KEY_ENTER"
        case .back: return "KEY_RETURN"
        case .home: return "KEY_CONTENTS"
        case .menu: return "KEY_MENU"
        case .input: return "KEY_SOURCE"
        case .volumeUp: return "KEY_VOLUP"
        case .volumeDown: return "KEY_VOLDOWN"
        case .mute: return "KEY_MUTE"
        case .channelUp: return "KEY_CHUP"
        case .channelDown: return "KEY_CHDOWN"
        case .powerOff: return "KEY_POWEROFF"
        case .powerOn: return nil
        case .playPause: return "KEY_PLAY"
        case .rewind: return "KEY_REWIND"
        case .fastForward: return "KEY_FF"
        case .skipPrevious, .skipNext, .backspace: return nil
        }
    }

    static let appsUnavailable = "This Samsung can't open apps from the remote."

    private static func sharedSecret(_ gx: Data) -> Data {
        let secret = BigUInt.modPow(
            base: BigUInt(bigEndian: gx),
            exponent: BigUInt(bigEndian: privateKey),
            modulus: BigUInt(bigEndian: prime)
        )
        return secret.bigEndian(paddedTo: 1)
    }

    private static func pkcs7(_ data: Data) -> Data {
        let pad = 16 - (data.count % 16)
        return data + Data(repeating: UInt8(pad), count: pad)
    }
}

enum SamsungLegacy {
    static let port: UInt16 = 55000

    static func handshake(description: String, id: String, name: String) -> Data {
        let payload = Data([0x64, 0x00]) + field(description) + field(id) + field(name)
        return Data([0x00, 0x00, 0x00]) + rawField(payload)
    }

    static func keyPacket(_ key: String) -> Data {
        let payload = Data([0x00, 0x00, 0x00]) + field(key)
        return Data([0x00, 0x00, 0x00]) + rawField(payload)
    }

    static func field(_ text: String) -> Data {
        rawField(Data(text.utf8).base64EncodedData())
    }

    static func rawField(_ data: Data) -> Data {
        Data([UInt8(data.count), 0x00]) + data
    }
}

enum AES128 {
    static func ecb(_ data: Data, key: Data, encrypt: Bool) -> Data? {
        crypt(data, key: key, iv: nil, encrypt: encrypt, ecb: true)
    }

    static func cbc(_ data: Data, key: Data, iv: Data, encrypt: Bool) -> Data? {
        crypt(data, key: key, iv: iv, encrypt: encrypt, ecb: false)
    }

    private static func crypt(_ data: Data, key: Data, iv: Data?, encrypt: Bool, ecb: Bool) -> Data? {
        guard key.count == kCCKeySizeAES128, !data.isEmpty, data.count % kCCBlockSizeAES128 == 0 else { return nil }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        var options: CCOptions = 0
        if ecb { options |= CCOptions(kCCOptionECBMode) }
        let operation = encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    if let iv {
                        return iv.withUnsafeBytes { ivBytes in
                            CCCrypt(
                                operation, CCAlgorithm(kCCAlgorithmAES), options,
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, data.count,
                                out.baseAddress, capacity, &written
                            )
                        }
                    }
                    return CCCrypt(
                        operation, CCAlgorithm(kCCAlgorithmAES), options,
                        keyBytes.baseAddress, key.count, nil,
                        input.baseAddress, data.count,
                        out.baseAddress, capacity, &written
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written)
    }
}

private func SHA1(_ data: Data) -> Data {
    var digest = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
    _ = digest.withUnsafeMutableBytes { out in
        data.withUnsafeBytes { input in
            CC_SHA1(input.baseAddress, CC_LONG(data.count), out.bindMemory(to: UInt8.self).baseAddress)
        }
    }
    return digest
}

private extension Data {
    init?(hex: String) {
        let cleaned = hex.replacingOccurrences(of: "\\", with: "").filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
