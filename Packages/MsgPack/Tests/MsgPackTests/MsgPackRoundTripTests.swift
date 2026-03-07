// MsgPackRoundTripTests.swift
// MsgPackTests
//
// Round-trip encode/decode tests for every MsgPack value type.

import XCTest
@testable import MsgPack
import Foundation

final class MsgPackRoundTripTests: XCTestCase {

    private let encoder = MsgPackEncoder()
    private let decoder = MsgPackDecoder()

    // MARK: - Nil

    func testNilRoundTrip() throws {
        let value: MsgPackValue = .nil
        let data = try encoder.encode(value)
        XCTAssertEqual(data, Data([0xc0]))
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertTrue(decoded.isNil)
    }

    // MARK: - Bool

    func testBoolTrueRoundTrip() throws {
        let value: MsgPackValue = .bool(true)
        let data = try encoder.encode(value)
        XCTAssertEqual(data, Data([0xc3]))
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.boolValue, true)
    }

    func testBoolFalseRoundTrip() throws {
        let value: MsgPackValue = .bool(false)
        let data = try encoder.encode(value)
        XCTAssertEqual(data, Data([0xc2]))
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.boolValue, false)
    }

    // MARK: - Positive Integers

    func testPositiveFixInt() throws {
        // 0 – 127 should encode as a single byte (positive fixint)
        for v: UInt64 in [0, 1, 42, 127] {
            let value: MsgPackValue = .uint(v)
            let data = try encoder.encode(value)
            XCTAssertEqual(data.count, 1, "positive fixint \(v) should be 1 byte")
            XCTAssertEqual(data[0], UInt8(v))
            let decoded = try decoder.decode(MsgPackValue.self, from: data)
            XCTAssertEqual(decoded.uintValue, v)
        }
    }

    func testUInt8RoundTrip() throws {
        let value: MsgPackValue = .uint(200)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xcc) // uint8 format
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.uintValue, 200)
    }

    func testUInt16RoundTrip() throws {
        let value: MsgPackValue = .uint(0x1234)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xcd) // uint16 format
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.uintValue, 0x1234)
    }

    func testUInt32RoundTrip() throws {
        let value: MsgPackValue = .uint(0x12345678)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xce) // uint32 format
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.uintValue, 0x12345678)
    }

    func testUInt64RoundTrip() throws {
        let value: MsgPackValue = .uint(UInt64.max)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xcf) // uint64 format
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.uintValue, UInt64.max)
    }

    // MARK: - Negative Integers

    func testNegativeFixInt() throws {
        // -1 through -32 should encode as negative fixint (single byte 0xe0–0xff)
        for v: Int64 in [-1, -5, -16, -32] {
            let value: MsgPackValue = .int(v)
            let data = try encoder.encode(value)
            XCTAssertEqual(data.count, 1, "negative fixint \(v) should be 1 byte")
            let decoded = try decoder.decode(MsgPackValue.self, from: data)
            XCTAssertEqual(decoded.intValue, v)
        }
    }

    func testInt8RoundTrip() throws {
        let value: MsgPackValue = .int(-100)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xd0) // int8 format
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.intValue, -100)
    }

    func testInt16RoundTrip() throws {
        let value: MsgPackValue = .int(-1000)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xd1) // int16 format
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.intValue, -1000)
    }

    func testInt32RoundTrip() throws {
        let value: MsgPackValue = .int(-100_000)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xd2) // int32 format
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.intValue, -100_000)
    }

    func testInt64RoundTrip() throws {
        let value: MsgPackValue = .int(Int64.min)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xd3) // int64 format
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.intValue, Int64.min)
    }

    // MARK: - Floats

    func testFloat32RoundTrip() throws {
        let value: MsgPackValue = .float(3.14)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xca) // float32 format
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        // Decoded floats come back as .float via 0xca
        if case .float(let f) = decoded {
            XCTAssertEqual(f, 3.14, accuracy: 0.001)
        } else if case .double(let d) = decoded {
            XCTAssertEqual(Float(d), 3.14, accuracy: 0.001)
        } else {
            XCTFail("Expected float, got \(decoded)")
        }
    }

    func testFloat64RoundTrip() throws {
        let value: MsgPackValue = .double(2.718281828459045)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xcb) // float64 format
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.doubleValue, 2.718281828459045)
    }

    func testFloat64SpecialValues() throws {
        for special: Double in [0.0, -0.0, .infinity, -.infinity] {
            let value: MsgPackValue = .double(special)
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(MsgPackValue.self, from: data)
            XCTAssertEqual(decoded.doubleValue, special, "Round-trip failed for \(special)")
        }

        // NaN needs special handling
        let nanValue: MsgPackValue = .double(.nan)
        let nanData = try encoder.encode(nanValue)
        let nanDecoded = try decoder.decode(MsgPackValue.self, from: nanData)
        XCTAssertNotNil(nanDecoded.doubleValue)
        XCTAssertTrue(nanDecoded.doubleValue!.isNaN)
    }

    // MARK: - Strings

    func testEmptyString() throws {
        let value: MsgPackValue = .string("")
        let data = try encoder.encode(value)
        XCTAssertEqual(data, Data([0xa0])) // fixstr of length 0
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.stringValue, "")
    }

    func testFixStr() throws {
        let s = "hello"
        let value: MsgPackValue = .string(s)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xa0 | UInt8(s.utf8.count)) // fixstr
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.stringValue, s)
    }

    func testStr8() throws {
        // 32–255 byte string triggers str8
        let s = String(repeating: "A", count: 100)
        let value: MsgPackValue = .string(s)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xd9) // str8
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.stringValue, s)
    }

    func testStr16() throws {
        // > 255 byte string triggers str16
        let s = String(repeating: "B", count: 300)
        let value: MsgPackValue = .string(s)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xda) // str16
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.stringValue, s)
    }

    func testUnicodeString() throws {
        let s = "日本語テスト 🎉 Ñoño"
        let value: MsgPackValue = .string(s)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.stringValue, s)
    }

    // MARK: - Binary

    func testBinaryRoundTrip() throws {
        let bytes = Data([0x00, 0x01, 0x02, 0xff, 0xfe, 0xfd])
        let value: MsgPackValue = .binary(bytes)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xc4) // bin8
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.dataValue, bytes)
    }

    func testEmptyBinary() throws {
        let bytes = Data()
        let value: MsgPackValue = .binary(bytes)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.dataValue, bytes)
    }

    func testLargeBinary() throws {
        let bytes = Data(repeating: 0xAB, count: 300)
        let value: MsgPackValue = .binary(bytes)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xc5) // bin16
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.dataValue, bytes)
    }

    // MARK: - Array

    func testEmptyArray() throws {
        let value: MsgPackValue = .array([])
        let data = try encoder.encode(value)
        XCTAssertEqual(data, Data([0x90])) // fixarray of 0 elements
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.arrayValue, [])
    }

    func testFixArray() throws {
        let value: MsgPackValue = .array([.int(1), .string("two"), .bool(true)])
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0] & 0xf0, 0x90) // fixarray prefix
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.arrayValue?.count, 3)
        XCTAssertEqual(decoded[0]?.intValue, 1)
        XCTAssertEqual(decoded[1]?.stringValue, "two")
        XCTAssertEqual(decoded[2]?.boolValue, true)
    }

    func testNestedArray() throws {
        let inner: MsgPackValue = .array([.int(10), .int(20)])
        let outer: MsgPackValue = .array([.string("outer"), inner])
        let data = try encoder.encode(outer)
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded[0]?.stringValue, "outer")
        XCTAssertEqual(decoded[1]?[0]?.intValue, 10)
        XCTAssertEqual(decoded[1]?[1]?.intValue, 20)
    }

    func testArray16() throws {
        // 16 elements triggers array16 (fixarray only goes to 15)
        let elements = (0..<20).map { MsgPackValue.int(Int64($0)) }
        let value: MsgPackValue = .array(elements)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xdc) // array16
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.arrayValue?.count, 20)
        for i in 0..<20 {
            XCTAssertEqual(decoded[i]?.intValue, Int64(i))
        }
    }

    // MARK: - Map

    func testEmptyMap() throws {
        let value: MsgPackValue = .map([:])
        let data = try encoder.encode(value)
        XCTAssertEqual(data, Data([0x80])) // fixmap of 0 entries
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.mapValue?.count, 0)
    }

    func testFixMap() throws {
        let value: MsgPackValue = .map([
            .string("name"): .string("neovim"),
            .string("version"): .int(9),
        ])
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0] & 0xf0, 0x80) // fixmap prefix
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded["name"]?.stringValue, "neovim")
        XCTAssertEqual(decoded["version"]?.intValue, 9)
    }

    func testNestedMap() throws {
        let inner: MsgPackValue = .map([.string("nested_key"): .bool(true)])
        let outer: MsgPackValue = .map([
            .string("inner"): inner,
            .string("count"): .uint(42),
        ])
        let data = try encoder.encode(outer)
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded["count"]?.uintValue, 42)
        let decodedInner = decoded["inner"]
        XCTAssertNotNil(decodedInner)
        XCTAssertEqual(decodedInner?["nested_key"]?.boolValue, true)
    }

    func testMap16() throws {
        // 16 entries triggers map16
        var entries: [MsgPackValue: MsgPackValue] = [:]
        for i in 0..<20 {
            entries[.string("key_\(i)")] = .int(Int64(i))
        }
        let value: MsgPackValue = .map(entries)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xde) // map16
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.mapValue?.count, 20)
        for i in 0..<20 {
            XCTAssertEqual(decoded["key_\(i)"]?.intValue, Int64(i))
        }
    }

    // MARK: - Ext

    func testFixExt1() throws {
        let value: MsgPackValue = .ext(type: 1, data: Data([0xAB]))
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        if case .ext(let t, let d) = decoded {
            XCTAssertEqual(t, 1)
            XCTAssertEqual(d, Data([0xAB]))
        } else {
            XCTFail("Expected ext, got \(decoded)")
        }
    }

    func testFixExt4() throws {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let value: MsgPackValue = .ext(type: 7, data: payload)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        if case .ext(let t, let d) = decoded {
            XCTAssertEqual(t, 7)
            XCTAssertEqual(d, payload)
        } else {
            XCTFail("Expected ext, got \(decoded)")
        }
    }

    // MARK: - Mixed Types in Collections

    func testHeterogeneousArray() throws {
        let value: MsgPackValue = .array([
            .nil,
            .bool(false),
            .int(-42),
            .uint(999),
            .double(1.5),
            .string("mixed"),
            .binary(Data([0xff])),
            .array([.int(1)]),
            .map([.string("k"): .string("v")]),
        ])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        guard let arr = decoded.arrayValue else {
            XCTFail("Expected array")
            return
        }
        XCTAssertEqual(arr.count, 9)
        XCTAssertTrue(arr[0].isNil)
        XCTAssertEqual(arr[1].boolValue, false)
        XCTAssertEqual(arr[2].intValue, -42)
        XCTAssertEqual(arr[3].uintValue, 999)
        XCTAssertEqual(arr[4].doubleValue, 1.5)
        XCTAssertEqual(arr[5].stringValue, "mixed")
        XCTAssertEqual(arr[6].dataValue, Data([0xff]))
        XCTAssertEqual(arr[7].arrayValue?.count, 1)
        XCTAssertEqual(arr[8]["k"]?.stringValue, "v")
    }

    // MARK: - Codable Struct Round Trip

    struct SampleConfig: Codable, Equatable {
        let host: String
        let port: Int
        let useTLS: Bool
        let timeout: Double
    }

    func testCodableStructRoundTrip() throws {
        let config = SampleConfig(host: "example.com", port: 6379, useTLS: true, timeout: 30.5)
        let data = try encoder.encode(config)
        let decoded = try decoder.decode(SampleConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    struct NestedStruct: Codable, Equatable {
        struct Inner: Codable, Equatable {
            let value: Int
            let label: String
        }
        let name: String
        let items: [Inner]
    }

    func testCodableNestedStructRoundTrip() throws {
        let nested = NestedStruct(
            name: "test",
            items: [
                .init(value: 1, label: "first"),
                .init(value: 2, label: "second"),
            ]
        )
        let data = try encoder.encode(nested)
        let decoded = try decoder.decode(NestedStruct.self, from: data)
        XCTAssertEqual(decoded, nested)
    }

    // MARK: - Codable Optional Fields

    struct OptionalFields: Codable, Equatable {
        let required: String
        let optional: Int?
    }

    func testCodableOptionalPresent() throws {
        let value = OptionalFields(required: "yes", optional: 42)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(OptionalFields.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testCodableOptionalAbsent() throws {
        let value = OptionalFields(required: "yes", optional: nil)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(OptionalFields.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // MARK: - Codable Array of Primitives

    func testCodableIntArray() throws {
        let values = [1, 2, 3, 4, 5]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([Int].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testCodableStringArray() throws {
        let values = ["alpha", "beta", "gamma"]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([String].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    // MARK: - Codable Dictionary

    func testCodableStringIntDictionary() throws {
        let dict: [String: Int] = ["a": 1, "b": 2, "c": 3]
        let data = try encoder.encode(dict)
        let decoded = try decoder.decode([String: Int].self, from: data)
        XCTAssertEqual(decoded, dict)
    }

    // MARK: - Edge Cases

    func testZeroValues() throws {
        let value: MsgPackValue = .array([
            .int(0),
            .uint(0),
            .double(0.0),
            .string(""),
            .binary(Data()),
            .array([]),
            .map([:]),
        ])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        guard let arr = decoded.arrayValue else {
            XCTFail("Expected array")
            return
        }
        XCTAssertEqual(arr.count, 7)
    }

    func testMaxFixStrLength() throws {
        // fixstr supports up to 31 bytes
        let s = String(repeating: "x", count: 31)
        let value: MsgPackValue = .string(s)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xa0 | 31) // fixstr with length 31
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.stringValue, s)
    }

    func testMaxFixArrayLength() throws {
        // fixarray supports up to 15 elements
        let elements = (0..<15).map { MsgPackValue.int(Int64($0)) }
        let value: MsgPackValue = .array(elements)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0x90 | 15) // fixarray with count 15
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.arrayValue?.count, 15)
    }

    func testMaxFixMapLength() throws {
        // fixmap supports up to 15 entries
        var entries: [MsgPackValue: MsgPackValue] = [:]
        for i in 0..<15 {
            entries[.string("k\(i)")] = .int(Int64(i))
        }
        let value: MsgPackValue = .map(entries)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0x80 | 15) // fixmap with count 15
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.mapValue?.count, 15)
    }

    // MARK: - Boundary Values

    func testInt8Boundary() throws {
        // -33 should go to int8 (not negative fixint which covers -32 to -1)
        let value: MsgPackValue = .int(-33)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xd0) // int8
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.intValue, -33)
    }

    func testInt8MinBoundary() throws {
        let value: MsgPackValue = .int(Int64(Int8.min))
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xd0) // int8
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.intValue, Int64(Int8.min))
    }

    func testUInt8Boundary() throws {
        // 128 should go to uint8 (not positive fixint which covers 0–127)
        let value: MsgPackValue = .uint(128)
        let data = try encoder.encode(value)
        XCTAssertEqual(data[0], 0xcc) // uint8
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded.uintValue, 128)
    }

    // MARK: - MsgPackValue Subscript & Accessors

    func testArraySubscriptOutOfBounds() {
        let value: MsgPackValue = .array([.int(1)])
        XCTAssertNil(value[5])
        XCTAssertNil(value[-1])
    }

    func testMapSubscriptMissing() {
        let value: MsgPackValue = .map([.string("a"): .int(1)])
        XCTAssertNil(value["missing"])
    }

    func testSubscriptOnWrongType() {
        let intValue: MsgPackValue = .int(42)
        XCTAssertNil(intValue[0])
        XCTAssertNil(intValue["key"])
    }

    func testAccessorsReturnNilForWrongType() {
        let str: MsgPackValue = .string("hello")
        XCTAssertNil(str.boolValue)
        XCTAssertNil(str.intValue)
        XCTAssertNil(str.uintValue)
        XCTAssertNil(str.doubleValue)
        XCTAssertNil(str.dataValue)
        XCTAssertNil(str.arrayValue)
        XCTAssertNil(str.mapValue)
        XCTAssertFalse(str.isNil)
    }

    // MARK: - Error Handling

    func testDecodeEmptyDataThrows() {
        XCTAssertThrowsError(try decoder.decode(MsgPackValue.self, from: Data())) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testDecodeTruncatedDataThrows() {
        // str8 header saying 100 bytes but only 2 bytes of payload
        let truncated = Data([0xd9, 100, 0x41, 0x42])
        XCTAssertThrowsError(try decoder.decode(MsgPackValue.self, from: truncated)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testDecodeInvalidByte0xC1Throws() {
        XCTAssertThrowsError(try decoder.decode(MsgPackValue.self, from: Data([0xc1]))) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    // MARK: - Neovim-like RPC Message

    func testNeovimRPCRequestRoundTrip() throws {
        // Neovim RPC request: [type(0), msgid, method, params]
        let rpcRequest: MsgPackValue = .array([
            .uint(0),                          // type: request
            .uint(1),                          // msgid
            .string("nvim_input"),             // method
            .array([.string("<C-a>")]),         // params
        ])
        let data = try encoder.encode(rpcRequest)
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded[0]?.uintValue, 0)
        XCTAssertEqual(decoded[1]?.uintValue, 1)
        XCTAssertEqual(decoded[2]?.stringValue, "nvim_input")
        XCTAssertEqual(decoded[3]?[0]?.stringValue, "<C-a>")
    }

    func testNeovimRPCNotificationRoundTrip() throws {
        // Neovim RPC notification: [type(2), method, params]
        let hlAttr: MsgPackValue = .map([
            .string("foreground"): .uint(0xFFFFFF),
            .string("background"): .uint(0x000000),
            .string("bold"): .bool(true),
        ])
        let rpcNotification: MsgPackValue = .array([
            .uint(2),                          // type: notification
            .string("redraw"),                 // method
            .array([                           // params
                .array([
                    .string("hl_attr_define"),
                    .array([.uint(1), hlAttr, .map([:]), .array([])]),
                ]),
            ]),
        ])
        let data = try encoder.encode(rpcNotification)
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded[0]?.uintValue, 2)
        XCTAssertEqual(decoded[1]?.stringValue, "redraw")

        // Dig into the nested structure
        let redrawEvents = decoded[2]
        let firstEvent = redrawEvents?[0]
        XCTAssertEqual(firstEvent?[0]?.stringValue, "hl_attr_define")

        let eventArgs = firstEvent?[1]
        XCTAssertEqual(eventArgs?[0]?.uintValue, 1)
        let attrs = eventArgs?[1]
        XCTAssertEqual(attrs?["foreground"]?.uintValue, 0xFFFFFF)
        XCTAssertEqual(attrs?["background"]?.uintValue, 0x000000)
        XCTAssertEqual(attrs?["bold"]?.boolValue, true)
    }

    func testNeovimRPCResponseRoundTrip() throws {
        // Neovim RPC response: [type(1), msgid, error, result]
        let rpcResponse: MsgPackValue = .array([
            .uint(1),                          // type: response
            .uint(1),                          // msgid
            .nil,                              // error (none)
            .int(42),                          // result
        ])
        let data = try encoder.encode(rpcResponse)
        let decoded = try decoder.decode(MsgPackValue.self, from: data)
        XCTAssertEqual(decoded[0]?.uintValue, 1)
        XCTAssertEqual(decoded[1]?.uintValue, 1)
        XCTAssertTrue(decoded[2]?.isNil ?? false)
        XCTAssertEqual(decoded[3]?.intValue, 42)
    }

    // MARK: - MsgPackValue Description

    func testDescriptions() {
        XCTAssertEqual(MsgPackValue.nil.description, "nil")
        XCTAssertEqual(MsgPackValue.bool(true).description, "true")
        XCTAssertEqual(MsgPackValue.int(-1).description, "-1")
        XCTAssertEqual(MsgPackValue.uint(42).description, "42")
        XCTAssertEqual(MsgPackValue.string("hi").description, "\"hi\"")
        XCTAssertTrue(MsgPackValue.binary(Data([0x00])).description.contains("1 bytes"))
        XCTAssertTrue(MsgPackValue.array([]).description.contains("["))
        XCTAssertTrue(MsgPackValue.ext(type: 1, data: Data()).description.contains("ext"))
    }

    // MARK: - Literal Conformances

    func testExpressibleByLiterals() {
        let nilVal: MsgPackValue = nil
        XCTAssertTrue(nilVal.isNil)

        let boolVal: MsgPackValue = true
        XCTAssertEqual(boolVal.boolValue, true)

        let intVal: MsgPackValue = 42
        XCTAssertEqual(intVal.intValue, 42)

        let doubleVal: MsgPackValue = 3.14
        XCTAssertEqual(doubleVal.doubleValue, 3.14)

        let strVal: MsgPackValue = "hello"
        XCTAssertEqual(strVal.stringValue, "hello")

        let arrVal: MsgPackValue = [1, 2, 3]
        XCTAssertEqual(arrVal.arrayValue?.count, 3)

        let mapVal: MsgPackValue = ["key": "value"]
        XCTAssertEqual(mapVal["key"]?.stringValue, "value")
    }
}