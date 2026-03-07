// MsgPackEncoder.swift
// MsgPack
//
// Pure Swift MessagePack encoder with full Codable support.

import Foundation

// MARK: - Public API

/// Encodes `Encodable` values into MessagePack binary data.
public final class MsgPackEncoder: @unchecked Sendable {
    public init() {}

    /// Encode an `Encodable` value to MessagePack `Data`.
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        // Fast path: native MsgPackValue can be serialized directly.
        if let msgPackValue = value as? MsgPackValue {
            return MsgPackWriter.serialize(msgPackValue)
        }
        let encoder = _MsgPackEncoder()
        try value.encode(to: encoder)
        guard let topLevel = encoder.storage.topLevel else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Top-level encoding produced no data."
                )
            )
        }
        return topLevel
    }
}

// MARK: - Format Constants

enum MsgPackFormat {
    // Fixed values
    static let positiveFixIntRange: ClosedRange<UInt8> = 0x00...0x7f
    static let negativeFixIntRange: ClosedRange<UInt8> = 0xe0...0xff
    static let fixMapPrefix: UInt8 = 0x80
    static let fixArrayPrefix: UInt8 = 0x90
    static let fixStrPrefix: UInt8 = 0xa0

    // Nil
    static let `nil`: UInt8 = 0xc0

    // Bool
    static let `false`: UInt8 = 0xc2
    static let `true`: UInt8 = 0xc3

    // Binary
    static let bin8: UInt8 = 0xc4
    static let bin16: UInt8 = 0xc5
    static let bin32: UInt8 = 0xc6

    // Ext
    static let fixext1: UInt8 = 0xd4
    static let fixext2: UInt8 = 0xd5
    static let fixext4: UInt8 = 0xd6
    static let fixext8: UInt8 = 0xd7
    static let fixext16: UInt8 = 0xd8
    static let ext8: UInt8 = 0xd4  // unused for now
    static let ext16: UInt8 = 0xd5
    static let ext32: UInt8 = 0xd6

    // Float
    static let float32: UInt8 = 0xca
    static let float64: UInt8 = 0xcb

    // UInt
    static let uint8: UInt8 = 0xcc
    static let uint16: UInt8 = 0xcd
    static let uint32: UInt8 = 0xce
    static let uint64: UInt8 = 0xcf

    // Int
    static let int8: UInt8 = 0xd0
    static let int16: UInt8 = 0xd1
    static let int32: UInt8 = 0xd2
    static let int64: UInt8 = 0xd3

    // String
    static let str8: UInt8 = 0xd9
    static let str16: UInt8 = 0xda
    static let str32: UInt8 = 0xdb

    // Array
    static let array16: UInt8 = 0xdc
    static let array32: UInt8 = 0xdd

    // Map
    static let map16: UInt8 = 0xde
    static let map32: UInt8 = 0xdf
}

// MARK: - Storage

final class EncoderStorage {
    var containers: [Data] = []

    var topLevel: Data? {
        containers.last
    }

    func push(_ data: Data) {
        containers.append(data)
    }

    func popLast() -> Data? {
        containers.popLast()
    }
}

// MARK: - Reference-Type Container Backings

/// Reference-type backing for a keyed encoding container.
/// Accumulates key/value pairs and commits the msgpack map to the provided
/// `onCommit` closure when the last reference is released.
fileprivate final class _KeyedRef {
    var entries: [(key: Data, value: Data)] = []
    private let onCommit: (Data) -> Void

    init(onCommit: @escaping (Data) -> Void) {
        self.onCommit = onCommit
    }

    func appendEntry(keyData: Data, valueData: Data) {
        entries.append((key: keyData, value: valueData))
    }

    deinit {
        var data = MsgPackWriter.packMapHeader(count: entries.count)
        for entry in entries {
            data.append(entry.key)
            data.append(entry.value)
        }
        onCommit(data)
    }
}

/// Reference-type backing for an unkeyed encoding container.
/// Accumulates array elements and commits the msgpack array to the provided
/// `onCommit` closure when the last reference is released.
fileprivate final class _UnkeyedRef {
    var elements: [Data] = []
    private let onCommit: (Data) -> Void

    init(onCommit: @escaping (Data) -> Void) {
        self.onCommit = onCommit
    }

    func appendElement(_ data: Data) {
        elements.append(data)
    }

    deinit {
        var data = MsgPackWriter.packArrayHeader(count: elements.count)
        for element in elements { data.append(element) }
        onCommit(data)
    }
}

// MARK: - Internal Encoder

final class _MsgPackEncoder: Encoder {
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]
    let storage: EncoderStorage

    init(codingPath: [CodingKey] = [], storage: EncoderStorage? = nil) {
        self.codingPath = codingPath
        self.storage = storage ?? EncoderStorage()
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let ref = _KeyedRef { [storage] data in storage.push(data) }
        let container = MsgPackKeyedEncodingContainer<Key>(ref: ref, codingPath: codingPath)
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        let ref = _UnkeyedRef { [storage] data in storage.push(data) }
        return MsgPackUnkeyedEncodingContainer(ref: ref, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        MsgPackSingleValueEncodingContainer(encoder: self, codingPath: codingPath)
    }
}

// MARK: - Serialization Helpers

enum MsgPackWriter {
    static func packNil() -> Data {
        Data([MsgPackFormat.nil])
    }

    static func pack(bool value: Bool) -> Data {
        Data([value ? MsgPackFormat.true : MsgPackFormat.false])
    }

    static func pack(int value: Int64) -> Data {
        if value >= 0 {
            return pack(uint: UInt64(value))
        }
        if value >= -32 {
            // Negative fixint
            return Data([UInt8(bitPattern: Int8(value))])
        }
        if value >= Int64(Int8.min) {
            return Data([MsgPackFormat.int8, UInt8(bitPattern: Int8(value))])
        }
        if value >= Int64(Int16.min) {
            var bytes = Data(count: 3)
            bytes[0] = MsgPackFormat.int16
            let big = Int16(value).bigEndian
            withUnsafeBytes(of: big) { bytes.replaceSubrange(1..<3, with: $0) }
            return bytes
        }
        if value >= Int64(Int32.min) {
            var bytes = Data(count: 5)
            bytes[0] = MsgPackFormat.int32
            let big = Int32(value).bigEndian
            withUnsafeBytes(of: big) { bytes.replaceSubrange(1..<5, with: $0) }
            return bytes
        }
        var bytes = Data(count: 9)
        bytes[0] = MsgPackFormat.int64
        let big = value.bigEndian
        withUnsafeBytes(of: big) { bytes.replaceSubrange(1..<9, with: $0) }
        return bytes
    }

    static func pack(uint value: UInt64) -> Data {
        if value <= 0x7f {
            return Data([UInt8(value)])
        }
        if value <= UInt64(UInt8.max) {
            return Data([MsgPackFormat.uint8, UInt8(value)])
        }
        if value <= UInt64(UInt16.max) {
            var bytes = Data(count: 3)
            bytes[0] = MsgPackFormat.uint16
            let big = UInt16(value).bigEndian
            withUnsafeBytes(of: big) { bytes.replaceSubrange(1..<3, with: $0) }
            return bytes
        }
        if value <= UInt64(UInt32.max) {
            var bytes = Data(count: 5)
            bytes[0] = MsgPackFormat.uint32
            let big = UInt32(value).bigEndian
            withUnsafeBytes(of: big) { bytes.replaceSubrange(1..<5, with: $0) }
            return bytes
        }
        var bytes = Data(count: 9)
        bytes[0] = MsgPackFormat.uint64
        let big = value.bigEndian
        withUnsafeBytes(of: big) { bytes.replaceSubrange(1..<9, with: $0) }
        return bytes
    }

    static func pack(float value: Float) -> Data {
        var bytes = Data(count: 5)
        bytes[0] = MsgPackFormat.float32
        let big = value.bitPattern.bigEndian
        withUnsafeBytes(of: big) { bytes.replaceSubrange(1..<5, with: $0) }
        return bytes
    }

    static func pack(double value: Double) -> Data {
        var bytes = Data(count: 9)
        bytes[0] = MsgPackFormat.float64
        let big = value.bitPattern.bigEndian
        withUnsafeBytes(of: big) { bytes.replaceSubrange(1..<9, with: $0) }
        return bytes
    }

    static func pack(string value: String) -> Data {
        let utf8 = Data(value.utf8)
        let count = utf8.count
        var header: Data
        if count <= 31 {
            header = Data([MsgPackFormat.fixStrPrefix | UInt8(count)])
        } else if count <= Int(UInt8.max) {
            header = Data([MsgPackFormat.str8, UInt8(count)])
        } else if count <= Int(UInt16.max) {
            header = Data(count: 3)
            header[0] = MsgPackFormat.str16
            let big = UInt16(count).bigEndian
            withUnsafeBytes(of: big) { header.replaceSubrange(1..<3, with: $0) }
        } else {
            header = Data(count: 5)
            header[0] = MsgPackFormat.str32
            let big = UInt32(count).bigEndian
            withUnsafeBytes(of: big) { header.replaceSubrange(1..<5, with: $0) }
        }
        return header + utf8
    }

    static func pack(binary value: Data) -> Data {
        let count = value.count
        var header: Data
        if count <= Int(UInt8.max) {
            header = Data([MsgPackFormat.bin8, UInt8(count)])
        } else if count <= Int(UInt16.max) {
            header = Data(count: 3)
            header[0] = MsgPackFormat.bin16
            let big = UInt16(count).bigEndian
            withUnsafeBytes(of: big) { header.replaceSubrange(1..<3, with: $0) }
        } else {
            header = Data(count: 5)
            header[0] = MsgPackFormat.bin32
            let big = UInt32(count).bigEndian
            withUnsafeBytes(of: big) { header.replaceSubrange(1..<5, with: $0) }
        }
        return header + value
    }

    static func packArrayHeader(count: Int) -> Data {
        if count <= 15 {
            return Data([MsgPackFormat.fixArrayPrefix | UInt8(count)])
        } else if count <= Int(UInt16.max) {
            var header = Data(count: 3)
            header[0] = MsgPackFormat.array16
            let big = UInt16(count).bigEndian
            withUnsafeBytes(of: big) { header.replaceSubrange(1..<3, with: $0) }
            return header
        } else {
            var header = Data(count: 5)
            header[0] = MsgPackFormat.array32
            let big = UInt32(count).bigEndian
            withUnsafeBytes(of: big) { header.replaceSubrange(1..<5, with: $0) }
            return header
        }
    }

    static func packMapHeader(count: Int) -> Data {
        if count <= 15 {
            return Data([MsgPackFormat.fixMapPrefix | UInt8(count)])
        } else if count <= Int(UInt16.max) {
            var header = Data(count: 3)
            header[0] = MsgPackFormat.map16
            let big = UInt16(count).bigEndian
            withUnsafeBytes(of: big) { header.replaceSubrange(1..<3, with: $0) }
            return header
        } else {
            var header = Data(count: 5)
            header[0] = MsgPackFormat.map32
            let big = UInt32(count).bigEndian
            withUnsafeBytes(of: big) { header.replaceSubrange(1..<5, with: $0) }
            return header
        }
    }

    static func pack(ext type: Int8, data payload: Data) -> Data {
        let count = payload.count
        var header: Data
        switch count {
        case 1:  header = Data([0xd4, UInt8(bitPattern: type)])
        case 2:  header = Data([0xd5, UInt8(bitPattern: type)])
        case 4:  header = Data([0xd6, UInt8(bitPattern: type)])
        case 8:  header = Data([0xd7, UInt8(bitPattern: type)])
        case 16: header = Data([0xd8, UInt8(bitPattern: type)])
        default:
            if count <= Int(UInt8.max) {
                header = Data([0xc7, UInt8(count), UInt8(bitPattern: type)])
            } else if count <= Int(UInt16.max) {
                header = Data(count: 4)
                header[0] = 0xc8
                let big = UInt16(count).bigEndian
                withUnsafeBytes(of: big) { header.replaceSubrange(1..<3, with: $0) }
                header[3] = UInt8(bitPattern: type)
            } else {
                header = Data(count: 6)
                header[0] = 0xc9
                let big = UInt32(count).bigEndian
                withUnsafeBytes(of: big) { header.replaceSubrange(1..<5, with: $0) }
                header[5] = UInt8(bitPattern: type)
            }
        }
        return header + payload
    }

    /// Serialize a `MsgPackValue` directly to its native msgpack wire bytes.
    static func serialize(_ value: MsgPackValue) -> Data {
        switch value {
        case .nil:             return packNil()
        case .bool(let v):     return pack(bool: v)
        case .int(let v):      return pack(int: v)
        case .uint(let v):     return pack(uint: v)
        case .float(let v):    return pack(float: v)
        case .double(let v):   return pack(double: v)
        case .string(let v):   return pack(string: v)
        case .binary(let v):   return pack(binary: v)
        case .ext(let t, let d): return pack(ext: t, data: d)
        case .array(let elements):
            var data = packArrayHeader(count: elements.count)
            for element in elements { data.append(serialize(element)) }
            return data
        case .map(let dict):
            var data = packMapHeader(count: dict.count)
            for (k, v) in dict {
                data.append(serialize(k))
                data.append(serialize(v))
            }
            return data
        }
    }
}

// MARK: - Keyed Encoding Container

struct MsgPackKeyedEncodingContainer<K: CodingKey>: KeyedEncodingContainerProtocol {
    typealias Key = K

    private let _ref: _KeyedRef
    var codingPath: [CodingKey]

    fileprivate init(ref: _KeyedRef, codingPath: [CodingKey]) {
        self._ref = ref
        self.codingPath = codingPath
    }

    private func append(key: K, value: Data) {
        _ref.appendEntry(keyData: MsgPackWriter.pack(string: key.stringValue), valueData: value)
    }

    mutating func encodeNil(forKey key: K) throws { append(key: key, value: MsgPackWriter.packNil()) }
    mutating func encode(_ value: Bool,   forKey key: K) throws { append(key: key, value: MsgPackWriter.pack(bool: value)) }
    mutating func encode(_ value: String, forKey key: K) throws { append(key: key, value: MsgPackWriter.pack(string: value)) }
    mutating func encode(_ value: Double, forKey key: K) throws { append(key: key, value: MsgPackWriter.pack(double: value)) }
    mutating func encode(_ value: Float,  forKey key: K) throws { append(key: key, value: MsgPackWriter.pack(float: value)) }
    mutating func encode(_ value: Int,    forKey key: K) throws { append(key: key, value: MsgPackWriter.pack(int: Int64(value))) }
    mutating func encode(_ value: Int8,   forKey key: K) throws { append(key: key, value: MsgPackWriter.pack(int: Int64(value))) }
    mutating func encode(_ value: Int16,  forKey key: K) throws { append(key: key, value: MsgPackWriter.pack(int: Int64(value))) }
    mutating func encode(_ value: Int32,  forKey key: K) throws { append(key: key, value: MsgPackWriter.pack(int: Int64(value))) }
    mutating func encode(_ value: Int64,  forKey key: K) throws { append(key: key, value: MsgPackWriter.pack(int: value)) }
    mutating func encode(_ value: UInt,   forKey key: K) throws { append(key: key, value: MsgPackWriter.pack(uint: UInt64(value))) }
    mutating func encode(_ value: UInt8,  forKey key: K) throws { append(key: key, value: MsgPackWriter.pack(uint: UInt64(value))) }
    mutating func encode(_ value: UInt16, forKey key: K) throws { append(key: key, value: MsgPackWriter.pack(uint: UInt64(value))) }
    mutating func encode(_ value: UInt32, forKey key: K) throws { append(key: key, value: MsgPackWriter.pack(uint: UInt64(value))) }
    mutating func encode(_ value: UInt64, forKey key: K) throws { append(key: key, value: MsgPackWriter.pack(uint: value)) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: K) throws {
        if let msgPackValue = value as? MsgPackValue {
            append(key: key, value: MsgPackWriter.serialize(msgPackValue))
            return
        }
        if let data = value as? Data {
            append(key: key, value: MsgPackWriter.pack(binary: data))
            return
        }
        let tempStorage = EncoderStorage()
        let nested = _MsgPackEncoder(codingPath: codingPath + [key], storage: tempStorage)
        try value.encode(to: nested)
        // Containers inside encode(to:) auto-committed to tempStorage via _ref deinit.
        if let data = tempStorage.topLevel {
            append(key: key, value: data)
        } else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: codingPath + [key],
                    debugDescription: "Failed to encode nested value for key \(key.stringValue)."
                )
            )
        }
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: K
    ) -> KeyedEncodingContainer<NestedKey> {
        let keyData = MsgPackWriter.pack(string: key.stringValue)
        let nestedRef = _KeyedRef { [_ref = self._ref, keyData] data in
            _ref.appendEntry(keyData: keyData, valueData: data)
        }
        let container = MsgPackKeyedEncodingContainer<NestedKey>(
            ref: nestedRef, codingPath: codingPath + [key])
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer(forKey key: K) -> UnkeyedEncodingContainer {
        let keyData = MsgPackWriter.pack(string: key.stringValue)
        let nestedRef = _UnkeyedRef { [_ref = self._ref, keyData] data in
            _ref.appendEntry(keyData: keyData, valueData: data)
        }
        return MsgPackUnkeyedEncodingContainer(ref: nestedRef, codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> Encoder { _MsgPackEncoder(codingPath: codingPath) }
    mutating func superEncoder(forKey key: K) -> Encoder { _MsgPackEncoder(codingPath: codingPath + [key]) }
}

// MARK: - Unkeyed Encoding Container

struct MsgPackUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    private let _ref: _UnkeyedRef
    var codingPath: [CodingKey]
    var count: Int { _ref.elements.count }

    fileprivate init(ref: _UnkeyedRef, codingPath: [CodingKey]) {
        self._ref = ref
        self.codingPath = codingPath
    }

    mutating func encodeNil() throws { _ref.appendElement(MsgPackWriter.packNil()) }
    mutating func encode(_ value: Bool)   throws { _ref.appendElement(MsgPackWriter.pack(bool: value)) }
    mutating func encode(_ value: String) throws { _ref.appendElement(MsgPackWriter.pack(string: value)) }
    mutating func encode(_ value: Double) throws { _ref.appendElement(MsgPackWriter.pack(double: value)) }
    mutating func encode(_ value: Float)  throws { _ref.appendElement(MsgPackWriter.pack(float: value)) }
    mutating func encode(_ value: Int)    throws { _ref.appendElement(MsgPackWriter.pack(int: Int64(value))) }
    mutating func encode(_ value: Int8)   throws { _ref.appendElement(MsgPackWriter.pack(int: Int64(value))) }
    mutating func encode(_ value: Int16)  throws { _ref.appendElement(MsgPackWriter.pack(int: Int64(value))) }
    mutating func encode(_ value: Int32)  throws { _ref.appendElement(MsgPackWriter.pack(int: Int64(value))) }
    mutating func encode(_ value: Int64)  throws { _ref.appendElement(MsgPackWriter.pack(int: value)) }
    mutating func encode(_ value: UInt)   throws { _ref.appendElement(MsgPackWriter.pack(uint: UInt64(value))) }
    mutating func encode(_ value: UInt8)  throws { _ref.appendElement(MsgPackWriter.pack(uint: UInt64(value))) }
    mutating func encode(_ value: UInt16) throws { _ref.appendElement(MsgPackWriter.pack(uint: UInt64(value))) }
    mutating func encode(_ value: UInt32) throws { _ref.appendElement(MsgPackWriter.pack(uint: UInt64(value))) }
    mutating func encode(_ value: UInt64) throws { _ref.appendElement(MsgPackWriter.pack(uint: value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        if let msgPackValue = value as? MsgPackValue {
            _ref.appendElement(MsgPackWriter.serialize(msgPackValue))
            return
        }
        if let data = value as? Data {
            _ref.appendElement(MsgPackWriter.pack(binary: data))
            return
        }
        let index = count
        let tempStorage = EncoderStorage()
        let nested = _MsgPackEncoder(
            codingPath: codingPath + [MsgPackCodingKey(index: index)],
            storage: tempStorage)
        try value.encode(to: nested)
        if let data = tempStorage.topLevel {
            _ref.appendElement(data)
        } else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Failed to encode nested value at index \(index)."
                )
            )
        }
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let nestedRef = _KeyedRef { [_ref = self._ref] data in _ref.appendElement(data) }
        let container = MsgPackKeyedEncodingContainer<NestedKey>(
            ref: nestedRef, codingPath: codingPath + [MsgPackCodingKey(index: count)])
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let nestedRef = _UnkeyedRef { [_ref = self._ref] data in _ref.appendElement(data) }
        return MsgPackUnkeyedEncodingContainer(
            ref: nestedRef,
            codingPath: codingPath + [MsgPackCodingKey(index: count)])
    }

    mutating func superEncoder() -> Encoder { _MsgPackEncoder(codingPath: codingPath) }
}

// MARK: - Single Value Encoding Container

struct MsgPackSingleValueEncodingContainer: SingleValueEncodingContainer {
    let encoder: _MsgPackEncoder
    var codingPath: [CodingKey]

    init(encoder: _MsgPackEncoder, codingPath: [CodingKey]) {
        self.encoder = encoder
        self.codingPath = codingPath
    }

    mutating func encodeNil() throws { encoder.storage.push(MsgPackWriter.packNil()) }
    mutating func encode(_ value: Bool)   throws { encoder.storage.push(MsgPackWriter.pack(bool: value)) }
    mutating func encode(_ value: String) throws { encoder.storage.push(MsgPackWriter.pack(string: value)) }
    mutating func encode(_ value: Double) throws { encoder.storage.push(MsgPackWriter.pack(double: value)) }
    mutating func encode(_ value: Float)  throws { encoder.storage.push(MsgPackWriter.pack(float: value)) }
    mutating func encode(_ value: Int)    throws { encoder.storage.push(MsgPackWriter.pack(int: Int64(value))) }
    mutating func encode(_ value: Int8)   throws { encoder.storage.push(MsgPackWriter.pack(int: Int64(value))) }
    mutating func encode(_ value: Int16)  throws { encoder.storage.push(MsgPackWriter.pack(int: Int64(value))) }
    mutating func encode(_ value: Int32)  throws { encoder.storage.push(MsgPackWriter.pack(int: Int64(value))) }
    mutating func encode(_ value: Int64)  throws { encoder.storage.push(MsgPackWriter.pack(int: value)) }
    mutating func encode(_ value: UInt)   throws { encoder.storage.push(MsgPackWriter.pack(uint: UInt64(value))) }
    mutating func encode(_ value: UInt8)  throws { encoder.storage.push(MsgPackWriter.pack(uint: UInt64(value))) }
    mutating func encode(_ value: UInt16) throws { encoder.storage.push(MsgPackWriter.pack(uint: UInt64(value))) }
    mutating func encode(_ value: UInt32) throws { encoder.storage.push(MsgPackWriter.pack(uint: UInt64(value))) }
    mutating func encode(_ value: UInt64) throws { encoder.storage.push(MsgPackWriter.pack(uint: value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        if let msgPackValue = value as? MsgPackValue {
            encoder.storage.push(MsgPackWriter.serialize(msgPackValue))
            return
        }
        if let data = value as? Data {
            encoder.storage.push(MsgPackWriter.pack(binary: data))
            return
        }
        let tempStorage = EncoderStorage()
        let nested = _MsgPackEncoder(codingPath: codingPath, storage: tempStorage)
        try value.encode(to: nested)
        if let data = tempStorage.topLevel {
            encoder.storage.push(data)
        } else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(codingPath: codingPath, debugDescription: "Unable to encode value.")
            )
        }
    }
}

// MARK: - Coding Key

struct MsgPackCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
    init(index: Int) { self.stringValue = "Index \(index)"; self.intValue = index }
}


