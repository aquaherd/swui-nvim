import Foundation

// MARK: - Public API

/// A decoder that deserializes MessagePack binary data into `Decodable` Swift types.
public final class MsgPackDecoder: @unchecked Sendable {
    public init() {}

    /// Decode a `Decodable` type from MessagePack `Data`.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let reader = MsgPackReader(data: data)
        let value = try reader.readValue()
        // Fast path: MsgPackValue is the native representation — return it directly.
        if T.self == MsgPackValue.self {
            return value as! T
        }
        let decoder = _MsgPackDecoder(value: value, codingPath: [])
        return try T(from: decoder)
    }
}

// MARK: - MsgPackReader (streaming byte reader)

/// Reads raw MessagePack format bytes and produces `MsgPackValue`.
internal final class MsgPackReader {
    private let data: Data
    private var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset >= data.count }

    func readValue() throws -> MsgPackValue {
        guard offset < data.count else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unexpected end of MessagePack data")
            )
        }

        let byte = data[offset]
        offset += 1

        // --- positive fixint (0x00 – 0x7f)
        if byte & 0x80 == 0 {
            return .uint(UInt64(byte))
        }

        // --- negative fixint (0xe0 – 0xff)
        if byte & 0xe0 == 0xe0 {
            return .int(Int64(Int8(bitPattern: byte)))
        }

        // --- fixmap (0x80 – 0x8f)
        if byte & 0xf0 == 0x80 {
            let count = Int(byte & 0x0f)
            return try readMap(count: count)
        }

        // --- fixarray (0x90 – 0x9f)
        if byte & 0xf0 == 0x90 {
            let count = Int(byte & 0x0f)
            return try readArray(count: count)
        }

        // --- fixstr (0xa0 – 0xbf)
        if byte & 0xe0 == 0xa0 {
            let count = Int(byte & 0x1f)
            return try .string(readString(count: count))
        }

        switch byte {
        // nil
        case 0xc0:
            return .nil

        // (never used)
        case 0xc1:
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Invalid MessagePack byte 0xc1")
            )

        // bool
        case 0xc2:
            return .bool(false)
        case 0xc3:
            return .bool(true)

        // bin 8/16/32
        case 0xc4:
            let count = Int(try readUInt8())
            return try .binary(readBytes(count: count))
        case 0xc5:
            let count = Int(try readUInt16())
            return try .binary(readBytes(count: count))
        case 0xc6:
            let count = Int(try readUInt32())
            return try .binary(readBytes(count: count))

        // ext 8/16/32
        case 0xc7:
            let count = Int(try readUInt8())
            let type = Int8(bitPattern: try readUInt8())
            let payload = try readBytes(count: count)
            return .ext(type: type, data: payload)
        case 0xc8:
            let count = Int(try readUInt16())
            let type = Int8(bitPattern: try readUInt8())
            let payload = try readBytes(count: count)
            return .ext(type: type, data: payload)
        case 0xc9:
            let count = Int(try readUInt32())
            let type = Int8(bitPattern: try readUInt8())
            let payload = try readBytes(count: count)
            return .ext(type: type, data: payload)

        // float 32
        case 0xca:
            let bits = try readUInt32()
            return .float(Float(bitPattern: bits))

        // float 64
        case 0xcb:
            let bits = try readUInt64()
            return .double(Double(bitPattern: bits))

        // uint 8/16/32/64
        case 0xcc:
            return .uint(UInt64(try readUInt8()))
        case 0xcd:
            return .uint(UInt64(try readUInt16()))
        case 0xce:
            return .uint(UInt64(try readUInt32()))
        case 0xcf:
            return .uint(try readUInt64())

        // int 8/16/32/64
        case 0xd0:
            return .int(Int64(Int8(bitPattern: try readUInt8())))
        case 0xd1:
            return .int(Int64(Int16(bitPattern: try readUInt16())))
        case 0xd2:
            return .int(Int64(Int32(bitPattern: try readUInt32())))
        case 0xd3:
            return .int(Int64(Int64(bitPattern: try readUInt64())))

        // fixext 1/2/4/8/16
        case 0xd4:
            let type = Int8(bitPattern: try readUInt8())
            let payload = try readBytes(count: 1)
            return .ext(type: type, data: payload)
        case 0xd5:
            let type = Int8(bitPattern: try readUInt8())
            let payload = try readBytes(count: 2)
            return .ext(type: type, data: payload)
        case 0xd6:
            let type = Int8(bitPattern: try readUInt8())
            let payload = try readBytes(count: 4)
            return .ext(type: type, data: payload)
        case 0xd7:
            let type = Int8(bitPattern: try readUInt8())
            let payload = try readBytes(count: 8)
            return .ext(type: type, data: payload)
        case 0xd8:
            let type = Int8(bitPattern: try readUInt8())
            let payload = try readBytes(count: 16)
            return .ext(type: type, data: payload)

        // str 8/16/32
        case 0xd9:
            let count = Int(try readUInt8())
            return try .string(readString(count: count))
        case 0xda:
            let count = Int(try readUInt16())
            return try .string(readString(count: count))
        case 0xdb:
            let count = Int(try readUInt32())
            return try .string(readString(count: count))

        // array 16/32
        case 0xdc:
            let count = Int(try readUInt16())
            return try readArray(count: count)
        case 0xdd:
            let count = Int(try readUInt32())
            return try readArray(count: count)

        // map 16/32
        case 0xde:
            let count = Int(try readUInt16())
            return try readMap(count: count)
        case 0xdf:
            let count = Int(try readUInt32())
            return try readMap(count: count)

        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unknown MessagePack byte: \(String(format: "0x%02x", byte))")
            )
        }
    }

    // MARK: - Primitive Reads

    private func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unexpected end of data reading UInt8")
            )
        }
        let v = data[offset]
        offset += 1
        return v
    }

    private func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unexpected end of data reading UInt16")
            )
        }
        let v = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        offset += 2
        return v
    }

    private func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unexpected end of data reading UInt32")
            )
        }
        let v = UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
        offset += 4
        return v
    }

    private func readUInt64() throws -> UInt64 {
        guard offset + 8 <= data.count else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unexpected end of data reading UInt64")
            )
        }
        var v: UInt64 = 0
        for i in 0..<8 {
            v = v << 8 | UInt64(data[offset + i])
        }
        offset += 8
        return v
    }

    private func readBytes(count: Int) throws -> Data {
        guard offset + count <= data.count else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unexpected end of data reading \(count) bytes")
            )
        }
        let d = data[offset..<(offset + count)]
        offset += count
        return Data(d)
    }

    private func readString(count: Int) throws -> String {
        let bytes = try readBytes(count: count)
        guard let s = String(data: bytes, encoding: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Invalid UTF-8 in MessagePack string")
            )
        }
        return s
    }

    private func readArray(count: Int) throws -> MsgPackValue {
        var elements: [MsgPackValue] = []
        elements.reserveCapacity(count)
        for _ in 0..<count {
            elements.append(try readValue())
        }
        return .array(elements)
    }

    private func readMap(count: Int) throws -> MsgPackValue {
        var dict: [MsgPackValue: MsgPackValue] = [:]
        dict.reserveCapacity(count)
        for _ in 0..<count {
            let key = try readValue()
            let value = try readValue()
            dict[key] = value
        }
        return .map(dict)
    }
}

// MARK: - Internal Decoder

private struct _MsgPackDecoder: Decoder {
    let value: MsgPackValue
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .map(let dict) = value else {
            throw DecodingError.typeMismatch(
                [String: Any].self,
                .init(codingPath: codingPath, debugDescription: "Expected map, got \(value)")
            )
        }
        let pairs = dict.map { ($0.key, $0.value) }
        return KeyedDecodingContainer(_MsgPackKeyedContainer<Key>(pairs: pairs, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let elements) = value else {
            throw DecodingError.typeMismatch(
                [Any].self,
                .init(codingPath: codingPath, debugDescription: "Expected array, got \(value)")
            )
        }
        return _MsgPackUnkeyedContainer(elements: elements, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        return _MsgPackSingleValueContainer(value: value, codingPath: codingPath)
    }
}

// MARK: - Keyed Container

private struct _MsgPackKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let pairs: [(MsgPackValue, MsgPackValue)]
    let codingPath: [CodingKey]

    var allKeys: [Key] {
        pairs.compactMap { pair in
            switch pair.0 {
            case .string(let s):
                return Key(stringValue: s)
            case .int(let i):
                return Key(intValue: Int(i))
            case .uint(let u):
                return Key(intValue: Int(u))
            default:
                return nil
            }
        }
    }

    func contains(_ key: Key) -> Bool {
        return lookup(key) != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let val = lookup(key) else { return true }
        if case .nil = val { return true }
        return false
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try singleValue(forKey: key).decode(type)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let val = try requireValue(forKey: key)
        let decoder = _MsgPackDecoder(value: val, codingPath: codingPath + [key])
        return try T(from: decoder)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let val = try requireValue(forKey: key)
        let decoder = _MsgPackDecoder(value: val, codingPath: codingPath + [key])
        return try decoder.container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let val = try requireValue(forKey: key)
        let decoder = _MsgPackDecoder(value: val, codingPath: codingPath + [key])
        return try decoder.unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        let key = Key(stringValue: "super")!
        let val = lookup(key) ?? .nil
        return _MsgPackDecoder(value: val, codingPath: codingPath + [key])
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        let val = try requireValue(forKey: key)
        return _MsgPackDecoder(value: val, codingPath: codingPath + [key])
    }

    // MARK: Private helpers

    private func lookup(_ key: Key) -> MsgPackValue? {
        for (k, v) in pairs {
            switch k {
            case .string(let s) where s == key.stringValue:
                return v
            case .int(let i) where key.intValue != nil && Int(i) == key.intValue:
                return v
            case .uint(let u) where key.intValue != nil && Int(u) == key.intValue:
                return v
            default:
                continue
            }
        }
        return nil
    }

    private func requireValue(forKey key: Key) throws -> MsgPackValue {
        guard let val = lookup(key) else {
            throw DecodingError.keyNotFound(
                key,
                .init(codingPath: codingPath, debugDescription: "Key \(key.stringValue) not found")
            )
        }
        return val
    }

    private func singleValue(forKey key: Key) throws -> _MsgPackSingleValueContainer {
        let val = try requireValue(forKey: key)
        return _MsgPackSingleValueContainer(value: val, codingPath: codingPath + [key])
    }
}

// MARK: - Unkeyed Container

private struct _MsgPackUnkeyedContainer: UnkeyedDecodingContainer {
    let elements: [MsgPackValue]
    let codingPath: [CodingKey]

    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex >= elements.count }
    private(set) var currentIndex: Int = 0

    private mutating func nextValue() throws -> MsgPackValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(
                MsgPackValue.self,
                .init(codingPath: codingPath, debugDescription: "Unkeyed container is at end")
            )
        }
        let val = elements[currentIndex]
        currentIndex += 1
        return val
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { return false }
        if case .nil = elements[currentIndex] {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        let val = try nextValue()
        guard case .bool(let b) = val else {
            throw DecodingError.typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Expected bool"))
        }
        return b
    }

    mutating func decode(_ type: String.Type) throws -> String {
        let val = try nextValue()
        guard case .string(let s) = val else {
            throw DecodingError.typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Expected string"))
        }
        return s
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        let val = try nextValue()
        return try _coerceToDouble(val, codingPath: codingPath)
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        let val = try nextValue()
        return Float(try _coerceToDouble(val, codingPath: codingPath))
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        let val = try nextValue()
        return Int(try _coerceToInt64(val, codingPath: codingPath))
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        let val = try nextValue()
        return Int8(try _coerceToInt64(val, codingPath: codingPath))
    }

    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        let val = try nextValue()
        return Int16(try _coerceToInt64(val, codingPath: codingPath))
    }

    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        let val = try nextValue()
        return Int32(try _coerceToInt64(val, codingPath: codingPath))
    }

    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        let val = try nextValue()
        return try _coerceToInt64(val, codingPath: codingPath)
    }

    mutating func decode(_ type: UInt.Type) throws -> UInt {
        let val = try nextValue()
        return UInt(try _coerceToUInt64(val, codingPath: codingPath))
    }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        let val = try nextValue()
        return UInt8(try _coerceToUInt64(val, codingPath: codingPath))
    }

    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        let val = try nextValue()
        return UInt16(try _coerceToUInt64(val, codingPath: codingPath))
    }

    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        let val = try nextValue()
        return UInt32(try _coerceToUInt64(val, codingPath: codingPath))
    }

    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        let val = try nextValue()
        return try _coerceToUInt64(val, codingPath: codingPath)
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let val = try nextValue()
        let decoder = _MsgPackDecoder(value: val, codingPath: codingPath + [_MsgPackIndexKey(intValue: currentIndex - 1)])
        return try T(from: decoder)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let val = try nextValue()
        let decoder = _MsgPackDecoder(value: val, codingPath: codingPath + [_MsgPackIndexKey(intValue: currentIndex - 1)])
        return try decoder.container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let val = try nextValue()
        let decoder = _MsgPackDecoder(value: val, codingPath: codingPath + [_MsgPackIndexKey(intValue: currentIndex - 1)])
        return try decoder.unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        let val = try nextValue()
        return _MsgPackDecoder(value: val, codingPath: codingPath + [_MsgPackIndexKey(intValue: currentIndex - 1)])
    }
}

// MARK: - Single Value Container

private struct _MsgPackSingleValueContainer: SingleValueDecodingContainer {
    let value: MsgPackValue
    let codingPath: [CodingKey]

    func decodeNil() -> Bool {
        if case .nil = value { return true }
        return false
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .bool(let b) = value else {
            throw DecodingError.typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Expected bool, got \(value)"))
        }
        return b
    }

    func decode(_ type: String.Type) throws -> String {
        switch value {
        case .string(let s):
            return s
        case .binary(let d):
            guard let s = String(data: d, encoding: .utf8) else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Binary not valid UTF-8"))
            }
            return s
        default:
            throw DecodingError.typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Expected string, got \(value)"))
        }
    }

    func decode(_ type: Double.Type) throws -> Double {
        try _coerceToDouble(value, codingPath: codingPath)
    }

    func decode(_ type: Float.Type) throws -> Float {
        Float(try _coerceToDouble(value, codingPath: codingPath))
    }

    func decode(_ type: Int.Type) throws -> Int {
        Int(try _coerceToInt64(value, codingPath: codingPath))
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        let v = try _coerceToInt64(value, codingPath: codingPath)
        guard let result = Int8(exactly: v) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "\(v) does not fit in Int8"))
        }
        return result
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        let v = try _coerceToInt64(value, codingPath: codingPath)
        guard let result = Int16(exactly: v) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "\(v) does not fit in Int16"))
        }
        return result
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        let v = try _coerceToInt64(value, codingPath: codingPath)
        guard let result = Int32(exactly: v) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "\(v) does not fit in Int32"))
        }
        return result
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        try _coerceToInt64(value, codingPath: codingPath)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        UInt(try _coerceToUInt64(value, codingPath: codingPath))
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        let v = try _coerceToUInt64(value, codingPath: codingPath)
        guard let result = UInt8(exactly: v) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "\(v) does not fit in UInt8"))
        }
        return result
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        let v = try _coerceToUInt64(value, codingPath: codingPath)
        guard let result = UInt16(exactly: v) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "\(v) does not fit in UInt16"))
        }
        return result
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        let v = try _coerceToUInt64(value, codingPath: codingPath)
        guard let result = UInt32(exactly: v) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "\(v) does not fit in UInt32"))
        }
        return result
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try _coerceToUInt64(value, codingPath: codingPath)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        // Special-case Data so binary payloads round-trip.
        if type == Data.self {
            switch value {
            case .binary(let d):
                return d as! T
            case .string(let s):
                return s.data(using: .utf8)! as! T
            default:
                throw DecodingError.typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Expected binary"))
            }
        }
        let decoder = _MsgPackDecoder(value: value, codingPath: codingPath)
        return try T(from: decoder)
    }
}

// MARK: - Index CodingKey

private struct _MsgPackIndexKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = Int(stringValue)
    }
}

// MARK: - Numeric Coercion Helpers

private func _coerceToInt64(_ value: MsgPackValue, codingPath: [CodingKey]) throws -> Int64 {
    switch value {
    case .int(let i):
        return i
    case .uint(let u):
        guard let result = Int64(exactly: u) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: codingPath, debugDescription: "\(u) overflows Int64")
            )
        }
        return result
    case .float(let f):
        return Int64(f)
    case .double(let d):
        return Int64(d)
    default:
        throw DecodingError.typeMismatch(
            Int64.self,
            .init(codingPath: codingPath, debugDescription: "Expected numeric, got \(value)")
        )
    }
}

private func _coerceToUInt64(_ value: MsgPackValue, codingPath: [CodingKey]) throws -> UInt64 {
    switch value {
    case .uint(let u):
        return u
    case .int(let i):
        guard i >= 0 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: codingPath, debugDescription: "Negative value \(i) cannot be UInt64")
            )
        }
        return UInt64(i)
    case .float(let f):
        return UInt64(f)
    case .double(let d):
        return UInt64(d)
    default:
        throw DecodingError.typeMismatch(
            UInt64.self,
            .init(codingPath: codingPath, debugDescription: "Expected numeric, got \(value)")
        )
    }
}

private func _coerceToDouble(_ value: MsgPackValue, codingPath: [CodingKey]) throws -> Double {
    switch value {
    case .double(let d):
        return d
    case .float(let f):
        return Double(f)
    case .int(let i):
        return Double(i)
    case .uint(let u):
        return Double(u)
    default:
        throw DecodingError.typeMismatch(
            Double.self,
            .init(codingPath: codingPath, debugDescription: "Expected numeric, got \(value)")
        )
    }
}