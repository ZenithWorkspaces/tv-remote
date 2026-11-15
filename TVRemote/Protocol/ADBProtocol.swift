import Foundation

/// ADB host protocol used by Fire TV. Frames, the Android public-key blob, and shell commands.
enum ADBProtocol {
    static let port: UInt16 = 5555
    static let connect: UInt32 = 0x4E584E43
    static let auth: UInt32 = 0x48545541
    static let open: UInt32 = 0x4E45504F
    static let okay: UInt32 = 0x59414B4F
    static let close: UInt32 = 0x45534C43
    static let write: UInt32 = 0x45545257
    static let version: UInt32 = 0x01000000
    static let maxData: UInt32 = 4096
    static let authToken: UInt32 = 1
    static let authSignature: UInt32 = 2
    static let authPublicKey: UInt32 = 3

    struct Packet: Equatable {
        var command: UInt32
        var arg0: UInt32
        var arg1: UInt32
        var payload: Data

        var encoded: Data {
            var data = Data()
            data.appendUInt32LE(command)
            data.appendUInt32LE(arg0)
            data.appendUInt32LE(arg1)
            data.appendUInt32LE(UInt32(payload.count))
            data.appendUInt32LE(checksum(payload))
            data.appendUInt32LE(command ^ 0xFFFFFFFF)
            data.append(payload)
            return data
        }
    }

    static func connectPacket() -> Packet {
        Packet(command: connect, arg0: version, arg1: maxData, payload: Data("host::\0".utf8))
    }

    static func authSignature(_ signature: Data) -> Packet {
        Packet(command: auth, arg0: authSignature, arg1: 0, payload: signature)
    }

    static func authKey(_ androidKey: Data) -> Packet {
        Packet(command: auth, arg0: authPublicKey, arg1: 0, payload: androidKey)
    }

    static func openShell(localID: UInt32) -> Packet {
        Packet(command: open, arg0: localID, arg1: 0, payload: Data("shell:\0".utf8))
    }

    static func write(_ text: String, localID: UInt32, remoteID: UInt32) -> Packet {
        Packet(command: write, arg0: localID, arg1: remoteID, payload: Data(text.utf8))
    }

    static func okay(localID: UInt32, remoteID: UInt32) -> Packet {
        Packet(command: okay, arg0: localID, arg1: remoteID, payload: Data())
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { $0 &+ UInt32($1) }
    }

    enum Intake: Equatable {
        case needMore
        case bad
        case ready(Packet, Int)
    }

    static func intake(_ data: Data) -> Intake {
        guard data.count >= 24 else { return .needMore }
        let command = data.uint32LE(0)
        let magic = data.uint32LE(20)
        guard magic == command ^ 0xFFFFFFFF else { return .bad }
        let length = Int(data.uint32LE(12))
        guard length >= 0, length < 1_048_576 else { return .bad }
        guard data.count >= 24 + length else { return .needMore }
        let payload = data.subdata(in: 24..<(24 + length))
        guard checksum(payload) == data.uint32LE(16) else { return .bad }
        let packet = Packet(command: command, arg0: data.uint32LE(4), arg1: data.uint32LE(8), payload: payload)
        return .ready(packet, 24 + length)
    }

    static func decode(_ data: Data) -> (Packet, Int)? {
        if case let .ready(packet, count) = intake(data) { return (packet, count) }
        return nil
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

    static func shellCommand(for key: RemoteKey) -> String? {
        guard let code = keyCode(for: key) else { return nil }
        return "input keyevent \(code)\n"
    }

    static func launchCommand(package: String) -> String {
        "monkey -p \(package) 1\n"
    }

    static func textCommand(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: " ", with: "%s")
            .replacingOccurrences(of: "\n", with: "")
        return "input text \(escaped)\n"
    }

    static func package(for shortcut: AppShortcut) -> String? {
        switch shortcut.slug {
        case "netflix": return "com.netflix.ninja"
        case "prime": return "com.amazon.amazonvideo.livingroom"
        case "disney": return "com.disney.disneyplus"
        case "youtube": return "com.amazon.firetv.youtube"
        case "youtube-tv": return "com.google.android.youtube.tvunplugged"
        case "max": return "com.wbd.stream"
        case "hulu": return "com.hulu.plus"
        case "peacock": return "com.peacocktv.peacockandroid"
        case "paramount": return "com.cbs.ott"
        case "apple-tv": return "com.apple.atve.amazon.appletv"
        case "spotify": return "com.spotify.tv.android"
        default: return nil
        }
    }

    /// Android's `ADB_RSAPublicKey` blob, base64, then ` name\0`.
    static func androidPublicKey(modulus: Data, exponent: UInt32, name: String = "noads") -> Data? {
        guard modulus.count % 4 == 0, modulus.count >= 4 else { return nil }
        let words = littleEndianWords(modulus)
        guard let first = words.first else { return nil }
        let inverse = n0inv(first)
        guard let rr = montgomeryRR(modulus: modulus, wordCount: words.count) else { return nil }
        var body = Data()
        body.appendUInt32LE(UInt32(words.count))
        body.appendUInt32LE(inverse)
        words.forEach { body.appendUInt32LE($0) }
        littleEndianWords(rr).forEach { body.appendUInt32LE($0) }
        body.appendUInt32LE(exponent)
        let encoded = body.base64EncodedString() + " \(name)\0"
        return Data(encoded.utf8)
    }

    static func n0inv(_ n0: UInt32) -> UInt32 {
        var inverse: UInt32 = 1
        for _ in 0..<6 {
            inverse = inverse &* (2 &- n0 &* inverse)
        }
        return 0 &- inverse
    }

    static func littleEndianWords(_ bigEndian: Data) -> [UInt32] {
        let bytes = [UInt8](bigEndian)
        var words: [UInt32] = []
        var index = bytes.count
        while index >= 4 {
            index -= 4
            let word = (UInt32(bytes[index]) << 24)
                | (UInt32(bytes[index + 1]) << 16)
                | (UInt32(bytes[index + 2]) << 8)
                | UInt32(bytes[index + 3])
            words.append(word)
        }
        return words
    }

    static func montgomeryRR(modulus: Data, wordCount: Int) -> Data? {
        guard let value = BigUInt(bigEndian: modulus), !value.isZero else { return nil }
        let exponent = 2 * 32 * wordCount
        let rr = BigUInt.pow2(exponent, modulo: value)
        var bytes = rr.bigEndian(paddedTo: modulus.count)
        if bytes.count < modulus.count {
            bytes = Data(repeating: 0, count: modulus.count - bytes.count) + bytes
        }
        return bytes
    }
}

struct BigUInt: Equatable {
    private var words: [UInt32]

    init(bigEndian data: Data) {
        var copy = data
        while copy.first == 0, copy.count > 1 { copy.removeFirst() }
        var parsed: [UInt32] = []
        let bytes = [UInt8](copy)
        var index = bytes.count
        while index > 0 {
            let start = max(0, index - 4)
            var word: UInt32 = 0
            for byte in bytes[start..<index] {
                word = (word << 8) | UInt32(byte)
            }
            parsed.append(word)
            index = start
        }
        words = parsed
        trim()
    }

    private init(words: [UInt32]) {
        self.words = words
        trim()
    }

    var isZero: Bool { words.allSatisfy { $0 == 0 } }

    func bigEndian(paddedTo count: Int) -> Data {
        var bytes: [UInt8] = []
        for word in words.reversed() {
            bytes.append(UInt8((word >> 24) & 0xFF))
            bytes.append(UInt8((word >> 16) & 0xFF))
            bytes.append(UInt8((word >> 8) & 0xFF))
            bytes.append(UInt8(word & 0xFF))
        }
        while bytes.first == 0, bytes.count > 1 { bytes.removeFirst() }
        if bytes.count < count {
            bytes.insert(contentsOf: repeatElement(0, count: count - bytes.count), at: 0)
        }
        return Data(bytes)
    }

    static func pow2(_ exponent: Int, modulo: BigUInt) -> BigUInt {
        var result = BigUInt(words: [1])
        var base = BigUInt(words: [2])
        var exp = exponent
        while exp > 0 {
            if exp & 1 == 1 { result = result.multiplied(by: base).remainder(dividingBy: modulo) }
            exp >>= 1
            if exp > 0 { base = base.multiplied(by: base).remainder(dividingBy: modulo) }
        }
        return result
    }

    private func multiplied(by other: BigUInt) -> BigUInt {
        if isZero || other.isZero { return BigUInt(words: [0]) }
        var result = [UInt32](repeating: 0, count: words.count + other.words.count)
        for (i, left) in words.enumerated() {
            var carry: UInt64 = 0
            for (j, right) in other.words.enumerated() {
                let sum = UInt64(result[i + j]) + UInt64(left) * UInt64(right) + carry
                result[i + j] = UInt32(sum & 0xFFFFFFFF)
                carry = sum >> 32
            }
            var index = i + other.words.count
            while carry > 0 {
                let sum = UInt64(result[index]) + carry
                result[index] = UInt32(sum & 0xFFFFFFFF)
                carry = sum >> 32
                index += 1
            }
        }
        return BigUInt(words: result)
    }

    private func remainder(dividingBy modulus: BigUInt) -> BigUInt {
        guard !modulus.isZero else { return self }
        var value = self
        let shift = value.bitWidth - modulus.bitWidth
        if shift < 0 { return value }
        for offset in stride(from: shift, through: 0, by: -1) {
            let candidate = modulus.shiftedLeft(offset)
            if value >= candidate {
                value = value.subtracting(candidate)
            }
        }
        return value
    }

    private var bitWidth: Int {
        guard let last = words.last else { return 0 }
        return (words.count - 1) * 32 + (32 - last.leadingZeroBitCount)
    }

    private func shiftedLeft(_ bits: Int) -> BigUInt {
        let wordShift = bits / 32
        let bitShift = bits % 32
        var result = [UInt32](repeating: 0, count: wordShift)
        var carry: UInt32 = 0
        for word in words {
            let wide = (UInt64(word) << bitShift) | UInt64(carry)
            result.append(UInt32(wide & 0xFFFFFFFF))
            carry = UInt32(wide >> 32)
        }
        if carry > 0 { result.append(carry) }
        return BigUInt(words: result)
    }

    private func subtracting(_ other: BigUInt) -> BigUInt {
        var result: [UInt32] = []
        var borrow: UInt64 = 0
        for index in 0..<max(words.count, other.words.count) {
            let left = UInt64(index < words.count ? words[index] : 0)
            let right = UInt64(index < other.words.count ? other.words[index] : 0) + borrow
            if left >= right {
                result.append(UInt32(left - right))
                borrow = 0
            } else {
                result.append(UInt32((1 << 32) + left - right))
                borrow = 1
            }
        }
        return BigUInt(words: result)
    }

    private static func >= (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.words.count != rhs.words.count { return lhs.words.count > rhs.words.count }
        for index in stride(from: lhs.words.count - 1, through: 0, by: -1) {
            if lhs.words[index] != rhs.words[index] { return lhs.words[index] > rhs.words[index] }
        }
        return true
    }

    private mutating func trim() {
        while words.count > 1, words.last == 0 { words.removeLast() }
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    func uint32LE(_ offset: Int) -> UInt32 {
        let bytes = [UInt8](self)
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
