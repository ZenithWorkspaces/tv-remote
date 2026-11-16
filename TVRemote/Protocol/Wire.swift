import Foundation

/// Just enough protobuf to build and read the Android TV remote messages.
enum Proto {
    static func frame(_ message: Data) -> Data {
        varint(UInt64(message.count)) + message
    }

    static func uint(_ field: Int, _ value: UInt64) -> Data {
        key(field, 0) + varint(value)
    }

    static func bool(_ field: Int, _ value: Bool) -> Data {
        uint(field, value ? 1 : 0)
    }

    static func bytes(_ field: Int, _ value: Data) -> Data {
        key(field, 2) + varint(UInt64(value.count)) + value
    }

    static func string(_ field: Int, _ value: String) -> Data {
        bytes(field, Data(value.utf8))
    }

    static func message(_ field: Int, _ body: Data) -> Data {
        bytes(field, body)
    }

    static func key(_ field: Int, _ wire: Int) -> Data {
        varint(UInt64((field << 3) | wire))
    }

    static func varint(_ value: UInt64) -> Data {
        var rest = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(rest & 0x7F)
            rest >>= 7
            if rest != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while rest != 0
        return Data(bytes)
    }

    struct Field: Equatable {
        var number: Int
        var wire: Int
        var varint: UInt64?
        var data: Data
    }

    /// Top-level fields. Embedded messages stay as raw bytes.
    static func fields(_ data: Data) -> [Field] {
        var fields: [Field] = []
        var index = 0
        let bytes = [UInt8](data)
        while index < bytes.count {
            guard let (tag, next) = readVarint(bytes, index) else { return fields }
            index = next
            let number = Int(tag >> 3)
            let wire = Int(tag & 0x07)
            switch wire {
            case 0:
                guard let (value, after) = readVarint(bytes, index) else { return fields }
                index = after
                fields.append(Field(number: number, wire: wire, varint: value, data: Data()))
            case 2:
                guard let (length, after) = readVarint(bytes, index) else { return fields }
                index = after
                let end = index + Int(length)
                guard end <= bytes.count else { return fields }
                fields.append(Field(number: number, wire: wire, varint: nil, data: Data(bytes[index..<end])))
                index = end
            default:
                return fields
            }
        }
        return fields
    }

    static func popFrame(_ buffer: inout Data) -> Data? {
        let bytes = [UInt8](buffer)
        guard let (length, offset) = readVarint(bytes, 0) else { return nil }
        let total = offset + Int(length)
        guard length < 1_048_576, total <= bytes.count else { return nil }
        let body = Data(bytes[offset..<total])
        buffer.removeFirst(total)
        return body
    }

    private static func readVarint(_ bytes: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < bytes.count, shift <= 63 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (value, index) }
            shift += 7
        }
        return nil
    }
}

enum ASN1 {
    struct Node: Equatable {
        var tag: UInt8
        var value: Data
        var children: [Node]
    }

    static func parse(_ data: Data) -> Node? {
        parse(bytes: [UInt8](data), index: 0).map(\.0)
    }

    static func sequence(_ body: Data) -> Data { raw(0x30, body) }
    static func raw(_ tag: UInt8, _ body: Data) -> Data { tlv(tag, body) }
    static func integer(_ value: Int) -> Data { integer(Data([UInt8(value)])) }

    static func integer(_ magnitude: Data) -> Data {
        var body = [UInt8](magnitude)
        while body.first == 0, body.count > 1 { body.removeFirst() }
        if body.first ?? 0 >= 0x80 { body.insert(0, at: 0) }
        return tlv(0x02, Data(body))
    }

    static func bitString(_ payload: Data) -> Data {
        tlv(0x03, Data([0x00]) + payload)
    }

    static func utf8(_ text: String) -> Data { tlv(0x0C, Data(text.utf8)) }
    static func oid(_ encoded: [UInt8]) -> Data { tlv(0x06, Data(encoded)) }
    static func null() -> Data { Data([0x05, 0x00]) }

    static func rsaNumbers(in data: Data) -> (modulus: Data, exponent: Data)? {
        guard let root = parse(data) else { return nil }
        return findRSA(root)
    }

    private static func findRSA(_ node: Node) -> (modulus: Data, exponent: Data)? {
        if node.tag == 0x03, node.value.count > 1, let inner = parse(Data(node.value.dropFirst())),
           let numbers = rsaSequence(inner) {
            return numbers
        }
        if let numbers = rsaSequence(node) { return numbers }
        for child in node.children {
            if let numbers = findRSA(child) { return numbers }
        }
        return nil
    }

    private static func rsaSequence(_ node: Node) -> (modulus: Data, exponent: Data)? {
        guard node.tag == 0x30, node.children.count >= 2,
              node.children[0].tag == 0x02, node.children[1].tag == 0x02 else { return nil }
        let modulus = magnitude(node.children[0].value)
        let exponent = magnitude(node.children[1].value)
        guard modulus.count >= 64 || exponent.count <= 4 else { return nil }
        return (modulus, exponent)
    }

    static func magnitude(_ integer: Data) -> Data {
        var bytes = [UInt8](integer)
        if bytes.first == 0 { bytes.removeFirst() }
        return Data(bytes)
    }

    private static func tlv(_ tag: UInt8, _ body: Data) -> Data {
        Data([tag]) + length(body.count) + body
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var rest = count
        var bytes: [UInt8] = []
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }

    private static func parse(bytes: [UInt8], index: Int) -> (Node, Int)? {
        guard index < bytes.count else { return nil }
        let tag = bytes[index]
        var cursor = index + 1
        guard let (length, next) = readLength(bytes, cursor) else { return nil }
        cursor = next
        let end = cursor + length
        guard end <= bytes.count else { return nil }
        let value = Data(bytes[cursor..<end])
        var children: [Node] = []
        if tag & 0x20 != 0 {
            var child = cursor
            while child < end {
                guard let (node, after) = parse(bytes: bytes, index: child) else { break }
                children.append(node)
                child = after
            }
        }
        return (Node(tag: tag, value: value, children: children), end)
    }

    private static func readLength(_ bytes: [UInt8], _ index: Int) -> (Int, Int)? {
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        if first < 0x80 { return (Int(first), index + 1) }
        let count = Int(first & 0x7F)
        guard count > 0, index + 1 + count <= bytes.count else { return nil }
        var length = 0
        for offset in 0..<count {
            length = (length << 8) | Int(bytes[index + 1 + offset])
        }
        return (length, index + 1 + count)
    }
}

enum HexBytes {
    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ text: String) -> Data? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count % 2 == 0, cleaned.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
