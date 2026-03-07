// RPCChannel.swift
// NvimRPC
//
// MsgPack-RPC request/response/notification multiplexer.
// Implements the MessagePack-RPC protocol over an abstract byte transport.
//
// Protocol wire format (msgpack arrays):
//   Request:      [type: 0, msgid: uint32, method: string, params: array]
//   Response:     [type: 1, msgid: uint32, error: any, result: any]
//   Notification: [type: 2, method: string, params: array]

import Foundation
import MsgPack

// MARK: - RPCError

/// Errors produced by the RPC channel.
public enum RPCError: Error, Sendable, CustomStringConvertible {
    case encodingFailed(String)
    case decodingFailed(String)
    case invalidMessage(String)
    case responseError(MsgPackValue)
    case transportClosed
    case timeout
    case cancelled

    public var description: String {
        switch self {
        case .encodingFailed(let msg): return "RPCError.encodingFailed: \(msg)"
        case .decodingFailed(let msg): return "RPCError.decodingFailed: \(msg)"
        case .invalidMessage(let msg): return "RPCError.invalidMessage: \(msg)"
        case .responseError(let val):  return "RPCError.responseError: \(val)"
        case .transportClosed:         return "RPCError.transportClosed"
        case .timeout:                 return "RPCError.timeout"
        case .cancelled:               return "RPCError.cancelled"
        }
    }
}

// MARK: - RPCTransport protocol

/// Minimal byte-level transport abstraction for the RPC channel.
/// Implemented by LocalTransport (stdio) and SSHTransport.
public protocol RPCTransport: Sendable {
    /// Start the transport. Called once before any reads/writes.
    func start() async throws

    /// Send raw bytes to the remote end.
    func send(_ data: Data) async throws

    /// An async stream of chunks received from the remote end.
    var received: AsyncThrowingStream<Data, Error> { get }

    /// Gracefully shut down the transport.
    func stop() async
}

// MARK: - RPCChannel

/// An actor that multiplexes MsgPack-RPC messages over an `RPCTransport`.
///
/// - Sends requests and awaits responses via `AsyncThrowingContinuation`.
/// - Delivers incoming requests and notifications through `AsyncStream`.
/// - Handles framing: the transport delivers arbitrary-length chunks;
///   this actor reassembles them into complete msgpack objects.
public actor RPCChannel {
    // MARK: - Properties

    private let transport: RPCTransport
    private let encoder = MsgPackEncoder()
    private let decoder = MsgPackDecoder()

    /// Monotonically increasing message ID for outgoing requests.
    private var nextMsgID: UInt32 = 0

    /// In-flight request continuations, keyed by msgid.
    private var pendingRequests: [UInt32: CheckedContinuation<MsgPackValue, Error>] = [:]

    /// Whether the channel is running.
    private var isRunning = false

    /// Background task that reads from the transport.
    private var readTask: Task<Void, Never>?

    // Notification / incoming request delivery
    private var notificationContinuation: AsyncStream<RPCMessage>.Continuation?
    private var _notifications: AsyncStream<RPCMessage>?

    /// A stream of incoming notifications and requests from the remote end.
    public var notifications: AsyncStream<RPCMessage> {
        if let existing = _notifications {
            return existing
        }
        let stream = AsyncStream<RPCMessage> { continuation in
            self.notificationContinuation = continuation
        }
        _notifications = stream
        return stream
    }

    // MARK: - Init

    public init(transport: RPCTransport) {
        self.transport = transport
    }

    deinit {
        readTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Start the transport and begin reading messages.
    public func start() async throws {
        guard !isRunning else { return }
        try await transport.start()
        isRunning = true

        // Ensure the notification stream is created before we start reading
        _ = notifications

        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    /// Stop the channel, cancel pending requests, and shut down the transport.
    public func stop() async {
        isRunning = false
        readTask?.cancel()
        readTask = nil

        // Fail all pending requests
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: RPCError.transportClosed)
        }

        notificationContinuation?.finish()
        await transport.stop()
    }

    // MARK: - Sending

    /// Send an RPC request and await the response.
    ///
    /// - Parameters:
    ///   - method: The RPC method name (e.g. `"nvim_input"`).
    ///   - params: The parameters as an array of `MsgPackValue`.
    /// - Returns: The result `MsgPackValue` from the response.
    /// - Throws: `RPCError.responseError` if the remote returned an error,
    ///           or transport/encoding errors.
    public func request(
        method: String,
        params: [MsgPackValue] = []
    ) async throws -> MsgPackValue {
        let msgid = nextMsgID
        nextMsgID &+= 1

        let message: MsgPackValue = .array([
            .int(0),                        // type: request
            .uint(UInt64(msgid)),            // msgid
            .string(method),                // method
            .array(params),                 // params
        ])

        let data = try encodeValue(message)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[msgid] = continuation

            Task {
                do {
                    try await transport.send(data)
                } catch {
                    // If send fails, immediately fail the pending request
                    await self.failRequest(msgid: msgid, error: error)
                }
            }
        }
    }

    /// Send an RPC notification (fire-and-forget, no response expected).
    ///
    /// - Parameters:
    ///   - method: The RPC method name.
    ///   - params: The parameters as an array of `MsgPackValue`.
    public func notify(
        method: String,
        params: [MsgPackValue] = []
    ) async throws {
        let message: MsgPackValue = .array([
            .int(2),                        // type: notification
            .string(method),                // method
            .array(params),                 // params
        ])

        let data = try encodeValue(message)
        try await transport.send(data)
    }

    /// Send a response to an incoming request.
    ///
    /// - Parameters:
    ///   - msgid: The msgid from the incoming request.
    ///   - error: The error value (`.nil` for success).
    ///   - result: The result value.
    public func respond(
        msgid: UInt32,
        error: MsgPackValue = .nil,
        result: MsgPackValue = .nil
    ) async throws {
        let message: MsgPackValue = .array([
            .int(1),                        // type: response
            .uint(UInt64(msgid)),            // msgid
            error,                          // error
            result,                         // result
        ])

        let data = try encodeValue(message)
        try await transport.send(data)
    }

    // MARK: - Read Loop

    private func readLoop() async {
        // Buffer for reassembling msgpack objects from transport chunks
        var buffer = Data()

        do {
            for try await chunk in transport.received {
                guard !Task.isCancelled else { break }

                buffer.append(chunk)

                // Try to consume as many complete messages as possible
                while !buffer.isEmpty {
                    do {
                        let (value, consumed) = try decodeFirstValue(from: buffer)
                        buffer.removeFirst(consumed)
                        await handleMessage(value)
                    } catch is IncompleteDataError {
                        // Not enough data yet — wait for more chunks
                        break
                    } catch {
                        // Decoding error on this message; skip a byte and retry
                        // This is a simple recovery strategy; in practice msgpack
                        // framing errors are rare over reliable transports.
                        buffer.removeFirst(1)
                    }
                }
            }
        } catch {
            // Transport stream ended or errored
        }

        // Transport is done — clean up
        if isRunning {
            isRunning = false
            let pending = pendingRequests
            pendingRequests.removeAll()
            for (_, continuation) in pending {
                continuation.resume(throwing: RPCError.transportClosed)
            }
            notificationContinuation?.finish()
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ value: MsgPackValue) async {
        guard case .array(let arr) = value, !arr.isEmpty else {
            return // Ignore malformed messages
        }

        guard let typeInt = arr[0].intValue else { return }

        switch typeInt {
        case 0:
            // Incoming request: [0, msgid, method, params]
            guard arr.count >= 4,
                  let msgid = arr[1].uintValue.flatMap({ UInt32(exactly: $0) }),
                  let method = arr[2].stringValue,
                  let params = arr[3].arrayValue
            else { return }

            let msg = RPCMessage.request(msgid: msgid, method: method, params: params)
            notificationContinuation?.yield(msg)

        case 1:
            // Response: [1, msgid, error, result]
            guard arr.count >= 4,
                  let msgid = arr[1].uintValue.flatMap({ UInt32(exactly: $0) })
            else { return }

            let error = arr[2]
            let result = arr[3]

            if let continuation = pendingRequests.removeValue(forKey: msgid) {
                if error.isNil {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: RPCError.responseError(error))
                }
            }

        case 2:
            // Notification: [2, method, params]
            guard arr.count >= 3,
                  let method = arr[1].stringValue,
                  let params = arr[2].arrayValue
            else { return }

            let msg = RPCMessage.notification(method: method, params: params)
            notificationContinuation?.yield(msg)

        default:
            break
        }
    }

    // MARK: - Helpers

    private func failRequest(msgid: UInt32, error: Error) {
        if let continuation = pendingRequests.removeValue(forKey: msgid) {
            continuation.resume(throwing: error)
        }
    }

    private func encodeValue(_ value: MsgPackValue) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw RPCError.encodingFailed("\(error)")
        }
    }

    /// Attempt to decode the first complete MsgPack value from the front of `data`.
    /// Returns the decoded value and the number of bytes consumed.
    /// Throws `IncompleteDataError` if there isn't enough data for a complete value.
    private func decodeFirstValue(from data: Data) throws -> (MsgPackValue, Int) {
        // We use a simple strategy: try to decode from the full buffer.
        // If decoding succeeds, we figure out how many bytes were consumed
        // by re-encoding (for simplicity) or by using a counting reader.
        //
        // For efficiency we use a MsgPackStreamReader that tracks position.
        let reader = MsgPackStreamReader(data: data)
        do {
            let value = try reader.readValue()
            return (value, reader.bytesConsumed)
        } catch {
            // If the reader ran out of data, it's incomplete
            if reader.hitEnd {
                throw IncompleteDataError()
            }
            throw error
        }
    }
}

// MARK: - IncompleteDataError

/// Sentinel error indicating the buffer doesn't contain a complete msgpack value yet.
private struct IncompleteDataError: Error {}

// MARK: - MsgPackStreamReader

/// A minimal streaming msgpack reader that tracks byte position and detects
/// incomplete data (sets `hitEnd` when it runs out of bytes mid-value).
internal final class MsgPackStreamReader {
    private let data: Data
    private var offset: Int = 0
    private(set) var hitEnd: Bool = false

    var bytesConsumed: Int { offset }

    init(data: Data) {
        // Data slices can have startIndex != 0 (e.g., after removeFirst).
        // Normalise to a zero-based contiguous buffer so subscript[offset] is safe.
        self.data = data.startIndex == 0 ? data : Data(data)
    }

    func readValue() throws -> MsgPackValue {
        guard offset < data.count else {
            hitEnd = true
            throw IncompleteDataError()
        }

        let byte = data[offset]
        offset += 1

        // Positive fixint
        if byte & 0x80 == 0 {
            return .uint(UInt64(byte))
        }

        // Negative fixint
        if byte & 0xe0 == 0xe0 {
            return .int(Int64(Int8(bitPattern: byte)))
        }

        // Fixmap
        if byte & 0xf0 == 0x80 {
            let count = Int(byte & 0x0f)
            return try readMap(count: count)
        }

        // Fixarray
        if byte & 0xf0 == 0x90 {
            let count = Int(byte & 0x0f)
            return try readArray(count: count)
        }

        // Fixstr
        if byte & 0xe0 == 0xa0 {
            let count = Int(byte & 0x1f)
            return try .string(readString(count: count))
        }

        switch byte {
        case 0xc0: return .nil
        case 0xc1: throw RPCError.decodingFailed("Invalid msgpack byte 0xc1")
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)

        // bin 8/16/32
        case 0xc4:
            let n = Int(try readByte())
            return try .binary(readBytes(count: n))
        case 0xc5:
            let n = Int(try readUInt16())
            return try .binary(readBytes(count: n))
        case 0xc6:
            let n = Int(try readUInt32())
            return try .binary(readBytes(count: n))

        // ext 8/16/32
        case 0xc7:
            let n = Int(try readByte())
            let t = Int8(bitPattern: try readByte())
            return try .ext(type: t, data: readBytes(count: n))
        case 0xc8:
            let n = Int(try readUInt16())
            let t = Int8(bitPattern: try readByte())
            return try .ext(type: t, data: readBytes(count: n))
        case 0xc9:
            let n = Int(try readUInt32())
            let t = Int8(bitPattern: try readByte())
            return try .ext(type: t, data: readBytes(count: n))

        // float32 / float64
        case 0xca:
            let bits = try readUInt32()
            return .float(Float(bitPattern: bits))
        case 0xcb:
            let bits = try readUInt64()
            return .double(Double(bitPattern: bits))

        // uint 8/16/32/64
        case 0xcc: return .uint(UInt64(try readByte()))
        case 0xcd: return .uint(UInt64(try readUInt16()))
        case 0xce: return .uint(UInt64(try readUInt32()))
        case 0xcf: return .uint(try readUInt64())

        // int 8/16/32/64
        case 0xd0: return .int(Int64(Int8(bitPattern: try readByte())))
        case 0xd1: return .int(Int64(Int16(bitPattern: try readUInt16())))
        case 0xd2: return .int(Int64(Int32(bitPattern: try readUInt32())))
        case 0xd3: return .int(Int64(Int64(bitPattern: try readUInt64())))

        // fixext 1/2/4/8/16
        case 0xd4:
            let t = Int8(bitPattern: try readByte())
            return try .ext(type: t, data: readBytes(count: 1))
        case 0xd5:
            let t = Int8(bitPattern: try readByte())
            return try .ext(type: t, data: readBytes(count: 2))
        case 0xd6:
            let t = Int8(bitPattern: try readByte())
            return try .ext(type: t, data: readBytes(count: 4))
        case 0xd7:
            let t = Int8(bitPattern: try readByte())
            return try .ext(type: t, data: readBytes(count: 8))
        case 0xd8:
            let t = Int8(bitPattern: try readByte())
            return try .ext(type: t, data: readBytes(count: 16))

        // str 8/16/32
        case 0xd9:
            let n = Int(try readByte())
            return try .string(readString(count: n))
        case 0xda:
            let n = Int(try readUInt16())
            return try .string(readString(count: n))
        case 0xdb:
            let n = Int(try readUInt32())
            return try .string(readString(count: n))

        // array 16/32
        case 0xdc:
            let n = Int(try readUInt16())
            return try readArray(count: n)
        case 0xdd:
            let n = Int(try readUInt32())
            return try readArray(count: n)

        // map 16/32
        case 0xde:
            let n = Int(try readUInt16())
            return try readMap(count: n)
        case 0xdf:
            let n = Int(try readUInt32())
            return try readMap(count: n)

        default:
            throw RPCError.decodingFailed("Unknown msgpack byte: \(String(format: "0x%02x", byte))")
        }
    }

    // MARK: - Primitive readers

    private func readByte() throws -> UInt8 {
        guard offset < data.count else {
            hitEnd = true
            throw IncompleteDataError()
        }
        let b = data[offset]
        offset += 1
        return b
    }

    private func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else {
            hitEnd = true
            throw IncompleteDataError()
        }
        let v = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        offset += 2
        return v
    }

    private func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            hitEnd = true
            throw IncompleteDataError()
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
            hitEnd = true
            throw IncompleteDataError()
        }
        var v: UInt64 = 0
        for i in 0..<8 {
            v = (v << 8) | UInt64(data[offset + i])
        }
        offset += 8
        return v
    }

    private func readBytes(count: Int) throws -> Data {
        guard offset + count <= data.count else {
            hitEnd = true
            throw IncompleteDataError()
        }
        let d = data[offset..<(offset + count)]
        offset += count
        return Data(d)
    }

    private func readString(count: Int) throws -> String {
        let bytes = try readBytes(count: count)
        guard let s = String(data: bytes, encoding: .utf8) else {
            throw RPCError.decodingFailed("Invalid UTF-8 in msgpack string")
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
        var pairs: [MsgPackValue: MsgPackValue] = [:]
        pairs.reserveCapacity(count)
        for _ in 0..<count {
            let key = try readValue()
            let value = try readValue()
            pairs[key] = value
        }
        return .map(pairs)
    }
}