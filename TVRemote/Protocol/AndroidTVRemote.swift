import Foundation
import CryptoKit

/// Android TV Remote Service v2 message builders.
/// Pairing is the Polo protocol. Commands are `RemoteMessage` protobufs, each prefixed with a varint length.
enum AndroidTVRemote {
    static let pairingPort: UInt16 = 6467
    static let commandPort: UInt16 = 6466
    static let clientName = "No Ads Remote"
    static let serviceName = "atvremote"

    enum Feature: Int {
        static let ping = 1 << 0
        static let key = 1 << 1
        static let ime = 1 << 2
        static let power = 1 << 5
        static let volume = 1 << 6
        static let appLink = 1 << 9
        static let client = ping | key | ime | power | volume | appLink
    }

    static func keyCode(for key: RemoteKey) -> Int? {
        switch key {
        case .powerOn: return 224
        case .powerOff: return 223
        case .input: return 178
        case .home: return 3
        case .back: return 4
        case .up: return 19
        case .down: return 20
        case .left: return 21
        case .right: return 22
        case .ok, .enter: return 23
        case .volumeUp: return 24
        case .volumeDown: return 25
        case .mute: return 164
        case .channelUp: return 166
        case .channelDown: return 167
        case .playPause: return 85
        case .rewind: return 89
        case .fastForward: return 90
        case .skipPrevious: return 88
        case .skipNext: return 87
        case .menu: return 82
        case .backspace: return 67
        }
    }

    static func appLink(for shortcut: AppShortcut) -> String {
        switch shortcut.slug {
        case "netflix": return "https://www.netflix.com"
        case "prime": return "https://app.primevideo.com"
        case "disney": return "https://www.disneyplus.com"
        case "youtube": return "https://www.youtube.com"
        case "youtube-tv": return "https://tv.youtube.com"
        case "max": return "https://play.max.com"
        case "hulu": return "https://www.hulu.com"
        case "peacock": return "https://www.peacocktv.com"
        case "paramount": return "https://www.paramountplus.com"
        case "apple-tv": return "https://tv.apple.com"
        case "spotify": return "spotify://"
        default: return "https://\(shortcut.slug)"
        }
    }

    static func pairingRequest(clientName: String = AndroidTVRemote.clientName) -> Data {
        let body = Proto.string(1, serviceName) + Proto.string(2, clientName)
        return envelope(Proto.message(10, body))
    }

    static func options() -> Data {
        let encoding = Proto.uint(1, 3) + Proto.uint(2, 6)
        let body = Proto.message(1, encoding) + Proto.uint(3, 1)
        return envelope(Proto.message(20, body))
    }

    static func configuration() -> Data {
        let encoding = Proto.uint(1, 3) + Proto.uint(2, 6)
        let body = Proto.message(1, encoding) + Proto.uint(2, 1)
        return envelope(Proto.message(30, body))
    }

    static func secret(_ digest: Data) -> Data {
        envelope(Proto.message(40, Proto.bytes(1, digest)))
    }

    static func keyInject(code: Int, direction: Int = 3) -> Data {
        let body = Proto.uint(1, UInt64(code)) + Proto.uint(2, UInt64(direction))
        return Proto.message(10, body)
    }

    static func configure(features: Int) -> Data {
        var info = Proto.uint(3, 1)
        info += Proto.string(4, "1")
        info += Proto.string(5, serviceName)
        info += Proto.string(6, "1.0.0")
        let body = Proto.uint(1, UInt64(features)) + Proto.message(2, info)
        return Proto.message(1, body)
    }

    static func setActive(features: Int) -> Data {
        Proto.message(2, Proto.uint(1, UInt64(features)))
    }

    static func pingResponse(_ value: UInt64) -> Data {
        Proto.message(9, Proto.uint(1, value))
    }

    static func appLinkLaunch(_ link: String) -> Data {
        Proto.message(90, Proto.string(1, link))
    }

    static func textEdit(_ text: String, imeCounter: Int, fieldCounter: Int) -> Data {
        let position = max(0, text.utf8.count - 1)
        let ime = Proto.uint(1, UInt64(position)) + Proto.uint(2, UInt64(position)) + Proto.string(3, text)
        let edit = Proto.uint(1, 1) + Proto.message(2, ime)
        let batch = Proto.uint(1, UInt64(imeCounter)) + Proto.uint(2, UInt64(fieldCounter)) + Proto.message(3, edit)
        return Proto.message(21, batch)
    }

    enum PairingField: Int {
        case requestAck = 11
        case options = 20
        case configurationAck = 31
        case secretAck = 41
    }

    static func pairingField(_ message: Data) -> PairingField? {
        let numbers = Set(Proto.fields(message).map(\.number))
        if numbers.contains(PairingField.secretAck.rawValue) { return .secretAck }
        if numbers.contains(PairingField.configurationAck.rawValue) { return .configurationAck }
        if numbers.contains(PairingField.options.rawValue) { return .options }
        if numbers.contains(PairingField.requestAck.rawValue) { return .requestAck }
        return nil
    }

    static func pairingStatus(_ message: Data) -> UInt64? {
        Proto.fields(message).first { $0.number == 2 }?.varint
    }

    enum CommandField: Int {
        case configure = 1
        case setActive = 2
        case ping = 8
        case start = 40
        case imeBatch = 21
    }

    static func commandField(_ message: Data) -> CommandField? {
        let numbers = Set(Proto.fields(message).map(\.number))
        for field in [CommandField.configure, .setActive, .ping, .imeBatch, .start] where numbers.contains(field.rawValue) {
            return field
        }
        return nil
    }

    static func pingValue(_ message: Data) -> UInt64 {
        guard let ping = Proto.fields(message).first(where: { $0.number == 8 })?.data else { return 0 }
        return Proto.fields(ping).first { $0.number == 1 }?.varint ?? 0
    }

    static func configureCode(_ message: Data) -> Int {
        guard let configure = Proto.fields(message).first(where: { $0.number == 1 })?.data else { return Feature.client }
        return Int(Proto.fields(configure).first { $0.number == 1 }?.varint ?? UInt64(Feature.client))
    }

    static func imeCounters(_ message: Data) -> (Int, Int) {
        guard let batch = Proto.fields(message).first(where: { $0.number == 21 })?.data else { return (0, 0) }
        let fields = Proto.fields(batch)
        let ime = Int(fields.first { $0.number == 1 }?.varint ?? 0)
        let field = Int(fields.first { $0.number == 2 }?.varint ?? 0)
        return (ime, field)
    }

    /// Polo pairing digest. The code on the TV is the first byte of this hash, shown as two hex digits, plus four more.
    static func pairingDigest(
        clientModulus: Data,
        clientExponent: Int,
        serverModulus: Data,
        serverExponent: Int,
        code: String
    ) -> Data? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 6, let tail = HexBytes.decode(String(trimmed.dropFirst(2))),
              let client = poloMagnitude(clientModulus),
              let server = poloMagnitude(serverModulus),
              let clientExp = poloExponent(clientExponent),
              let serverExp = poloExponent(serverExponent) else { return nil }
        var hasher = SHA256()
        hasher.update(data: client)
        hasher.update(data: clientExp)
        hasher.update(data: server)
        hasher.update(data: serverExp)
        hasher.update(data: tail)
        return Data(hasher.finalize())
    }

    static func codeMatches(digest: Data, code: String) -> Bool {
        let prefix = code.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)
        guard let expected = UInt8(prefix, radix: 16), let first = digest.first else { return false }
        return first == expected
    }

    static func poloMagnitude(_ magnitude: Data) -> Data? {
        var bytes = [UInt8](magnitude)
        while bytes.first == 0 { bytes.removeFirst() }
        // The pairing hash uses unpadded uppercase hex. A leading nibble of 0
        // makes that hex odd-length, which the TV-side encoder rejects.
        guard let first = bytes.first, first >= 0x10 else { return nil }
        return Data(bytes)
    }

    static func poloExponent(_ value: Int) -> Data? {
        let hex = "0" + String(value, radix: 16).uppercased()
        return HexBytes.decode(hex)
    }

    private static func envelope(_ body: Data) -> Data {
        Proto.uint(1, 2) + Proto.uint(2, 200) + body
    }
}
