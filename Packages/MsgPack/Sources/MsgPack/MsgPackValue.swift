// MsgPackValue.swift
// MsgPack
//
// Pure Swift MessagePack dynamic value type.

import Foundation

/// A dynamically-typed MessagePack value.
///
/// This enum mirrors the MessagePack type system and supports `Codable`
/// round-tripping as well as direct construction for RPC use.
public enum MsgPackValue: Sendable, Hashable {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Float)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MsgPackValue])
    case map([MsgPackValue: MsgPackValue])
    case ext(type: Int8, data: Data)
}

// MARK: - ExpressibleBy Literals

extension MsgPackValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .nil
    }
}

extension MsgPackValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension MsgPackValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) {
        self = .int(value)
    }
}

extension MsgPackValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension MsgPackValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension MsgPackValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: MsgPackValue...) {
        self = .array(elements)
    }
}

extension MsgPackValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (MsgPackValue, MsgPackValue)...) {
        var dict: [MsgPackValue: MsgPackValue] = [:]
        dict.reserveCapacity(elements.count)
        for (key, value) in elements {
            dict[key] = value
        }
        self = .map(dict)
    }
}

// MARK: - Convenience Accessors

extension MsgPackValue {
    /// Returns the boolean value if this is `.bool`, otherwise `nil`.
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// Returns the integer value if this is `.int` or `.uint`, otherwise `nil`.
    public var intValue: Int64? {
        switch self {
        case .int(let v): return v
        case .uint(let v): return Int64(exactly: v)
        default: return nil
        }
    }

    /// Returns the unsigned integer value if this is `.uint` or a non-negative `.int`, otherwise `nil`.
    public var uintValue: UInt64? {
        switch self {
        case .uint(let v): return v
        case .int(let v): return UInt64(exactly: v)
        default: return nil
        }
    }

    /// Returns the double value if this is `.double` or `.float`, otherwise `nil`.
    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .float(let v): return Double(v)
        default: return nil
        }
    }

    /// Returns the string value if this is `.string`, otherwise `nil`.
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// Returns the binary data if this is `.binary`, otherwise `nil`.
    public var dataValue: Data? {
        if case .binary(let v) = self { return v }
        return nil
    }

    /// Returns the array if this is `.array`, otherwise `nil`.
    public var arrayValue: [MsgPackValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    /// Returns the map if this is `.map`, otherwise `nil`.
    public var mapValue: [MsgPackValue: MsgPackValue]? {
        if case .map(let v) = self { return v }
        return nil
    }

    /// Returns `true` if this value is `.nil`.
    public var isNil: Bool {
        if case .nil = self { return true }
        return false
    }

    /// Subscript access for `.array` values.
    public subscript(index: Int) -> MsgPackValue? {
        guard case .array(let arr) = self, arr.indices.contains(index) else {
            return nil
        }
        return arr[index]
    }

    /// Subscript access for `.map` values with string keys.
    public subscript(key: String) -> MsgPackValue? {
        guard case .map(let dict) = self else { return nil }
        return dict[.string(key)]
    }

    /// Subscript access for `.map` values with arbitrary keys.
    public subscript(key key: MsgPackValue) -> MsgPackValue? {
        guard case .map(let dict) = self else { return nil }
        return dict[key]
    }
}

// MARK: - CustomStringConvertible

extension MsgPackValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .nil:
            return "nil"
        case .bool(let v):
            return v.description
        case .int(let v):
            return v.description
        case .uint(let v):
            return v.description
        case .float(let v):
            return v.description
        case .double(let v):
            return v.description
        case .string(let v):
            return "\"\(v)\""
        case .binary(let v):
            return "binary(\(v.count) bytes)"
        case .array(let v):
            let items = v.map(\.description).joined(separator: ", ")
            return "[\(items)]"
        case .map(let v):
            let pairs = v.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            return "{\(pairs)}"
        case .ext(let type, let data):
            return "ext(\(type), \(data.count) bytes)"
        }
    }
}

// MARK: - Codable

extension MsgPackValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case extType
        case extData
    }

    private enum ValueType: String, Codable {
        case `nil`
        case bool
        case int
        case uint
        case float
        case double
        case string
        case binary
        case array
        case map
        case ext
    }

    public func encode(to encoder: Encoder) throws {
        // When encoding through our own MsgPackEncoder, the encoder
        // will handle this type natively. For other encoders (e.g. JSON),
        // we fall back to a tagged representation.
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .nil:
            try container.encode(ValueType.nil, forKey: .type)
        case .bool(let v):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(v, forKey: .value)
        case .int(let v):
            try container.encode(ValueType.int, forKey: .type)
            try container.encode(v, forKey: .value)
        case .uint(let v):
            try container.encode(ValueType.uint, forKey: .type)
            try container.encode(v, forKey: .value)
        case .float(let v):
            try container.encode(ValueType.float, forKey: .type)
            try container.encode(v, forKey: .value)
        case .double(let v):
            try container.encode(ValueType.double, forKey: .type)
            try container.encode(v, forKey: .value)
        case .string(let v):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(v, forKey: .value)
        case .binary(let v):
            try container.encode(ValueType.binary, forKey: .type)
            try container.encode(v, forKey: .value)
        case .array(let v):
            try container.encode(ValueType.array, forKey: .type)
            try container.encode(v, forKey: .value)
        case .map(let v):
            try container.encode(ValueType.map, forKey: .type)
            // Encode map as array of pairs for round-tripping non-string keys
            let pairs = v.map { [$0.key, $0.value] }
            try container.encode(pairs, forKey: .value)
        case .ext(let type, let data):
            try container.encode(ValueType.ext, forKey: .type)
            try container.encode(type, forKey: .extType)
            try container.encode(data, forKey: .extData)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ValueType.self, forKey: .type)
        switch type {
        case .nil:
            self = .nil
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .int:
            self = .int(try container.decode(Int64.self, forKey: .value))
        case .uint:
            self = .uint(try container.decode(UInt64.self, forKey: .value))
        case .float:
            self = .float(try container.decode(Float.self, forKey: .value))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .value))
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .binary:
            self = .binary(try container.decode(Data.self, forKey: .value))
        case .array:
            self = .array(try container.decode([MsgPackValue].self, forKey: .value))
        case .map:
            let pairs = try container.decode([[MsgPackValue]].self, forKey: .value)
            var dict: [MsgPackValue: MsgPackValue] = [:]
            dict.reserveCapacity(pairs.count)
            for pair in pairs {
                guard pair.count == 2 else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: container.codingPath,
                            debugDescription: "Map pair must have exactly 2 elements"
                        )
                    )
                }
                dict[pair[0]] = pair[1]
            }
            self = .map(dict)
        case .ext:
            let extType = try container.decode(Int8.self, forKey: .extType)
            let extData = try container.decode(Data.self, forKey: .extData)
            self = .ext(type: extType, data: extData)
        }
    }
}