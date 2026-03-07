// RPCChannelTests.swift
// NvimRPCTests
//
// Tests for RPCChannel using a controllable in-memory mock transport.
// Covers: request/response pairing, notifications, chunked delivery,
// out-of-order responses, transport-closed failure, and encoding round-trips.

import XCTest
@testable import NvimRPC
import MsgPack
import Foundation

// MARK: - MockTransport

/// An in-process transport that lets tests inject inbound data and capture
/// outbound bytes. Implemented as an `actor` so concurrent `send()` calls
/// are serialised and the `sent` array is safe to read after `await`.
actor MockTransport: RPCTransport {

    private(set) var sent: [Data] = []
    private(set) var started = false
    private(set) var stopped = false

    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    /// The async stream the `RPCChannel` reads from.
    /// Declared `nonisolated let` so `RPCChannel.readLoop()` can access it
    /// without hopping to the actor on every iteration.
    nonisolated let received: AsyncThrowingStream<Data, Error>

    init() {
        var cap: AsyncThrowingStream<Data, Error>.Continuation?
        received = AsyncThrowingStream<Data, Error> { cont in cap = cont }
        continuation = cap
    }

    // MARK: RPCTransport

    func start() async throws { started = true }
    func send(_ data: Data) async throws { sent.append(data) }
    func stop() async { stopped = true; continuation?.finish() }

    // MARK: Test helpers

    func inject(_ data: Data) { continuation?.yield(data) }

    func inject(message: RPCMessage) throws {
        let data = try MsgPackEncoder().encode(message.toMsgPackValue())
        inject(data)
    }

    func close() { continuation?.finish() }
    func closeWithError(_ error: Error) { continuation?.finish(throwing: error) }

    func lastSentMessage() throws -> RPCMessage? {
        guard let data = sent.last else { return nil }
        let value = try MsgPackDecoder().decode(MsgPackValue.self, from: data)
        return try RPCMessage.parse(from: value)
    }
}

// MARK: - RPCChannelTests

final class RPCChannelTests: XCTestCase {

    // MARK: - RPCMessage Encoding / Decoding

    func testRequestEncoding() throws {
        let msg = RPCMessage.request(msgid: 1, method: "nvim_input", params: [.string("<CR>")])
        let data = try MsgPackEncoder().encode(msg.toMsgPackValue())
        XCTAssertFalse(data.isEmpty)
        let decoded = try RPCMessage.parse(
            from: try MsgPackDecoder().decode(MsgPackValue.self, from: data))
        XCTAssertEqual(decoded, msg)
    }

    func testResponseEncoding() throws {
        let msg = RPCMessage.response(msgid: 42, error: .nil, result: .uint(7))
        let data = try MsgPackEncoder().encode(msg.toMsgPackValue())
        let decoded = try RPCMessage.parse(
            from: try MsgPackDecoder().decode(MsgPackValue.self, from: data))
        XCTAssertEqual(decoded, msg)
    }

    func testNotificationEncoding() throws {
        let msg = RPCMessage.notification(method: "redraw", params: [.array([.string("flush")])])
        let data = try MsgPackEncoder().encode(msg.toMsgPackValue())
        let decoded = try RPCMessage.parse(
            from: try MsgPackDecoder().decode(MsgPackValue.self, from: data))
        XCTAssertEqual(decoded, msg)
    }

    // MARK: - RPCMessage.parse edge cases

    func testParseInvalidNotAnArray() {
        XCTAssertThrowsError(try RPCMessage.parse(from: .string("oops"))) { error in
            guard case RPCMessage.ParseError.notAnArray = error else {
                XCTFail("Expected notAnArray, got \(error)"); return
            }
        }
    }

    func testParseUnknownType() {
        XCTAssertThrowsError(
            try RPCMessage.parse(
                from: .array([.uint(99), .uint(1), .string("x"), .array([])]))) { error in
            guard case RPCMessage.ParseError.unknownType = error else {
                XCTFail("Expected unknownType, got \(error)"); return
            }
        }
    }

    func testParseRequestMissingParams() {
        XCTAssertThrowsError(
            try RPCMessage.parse(from: .array([.uint(0), .uint(1), .string("method")])))
    }

    func testParseNotificationMissingParams() {
        XCTAssertThrowsError(
            try RPCMessage.parse(from: .array([.uint(2), .string("method")])))
    }

    // MARK: - Channel lifecycle

    func testChannelStartsTransport() async throws {
        let transport = MockTransport()
        let channel = RPCChannel(transport: transport)
        try await channel.start()
        let started = await transport.started
        XCTAssertTrue(started)
        await channel.stop()
        let stopped = await transport.stopped
        XCTAssertTrue(stopped)
    }

    // MARK: - Request / Response pairing

    func testRequestReceivesMatchingResponse() async throws {
        let transport = MockTransport()
        let channel = RPCChannel(transport: transport)
        try await channel.start()

        let requestTask = Task<MsgPackValue, Error> {
            try await channel.request(method: "echo", params: [.string("hello")])
        }

        try await Task.sleep(nanoseconds: 10_000_000)

        try await transport.inject(
            message: .response(msgid: 0, error: .nil, result: .string("hello")))

        let result = try await requestTask.value
        XCTAssertEqual(result, .string("hello"))

        await channel.stop()
    }

    func testRequestWithErrorResponse() async throws {
        let transport = MockTransport()
        let channel = RPCChannel(transport: transport)
        try await channel.start()

        let requestTask = Task<MsgPackValue, Error> {
            try await channel.request(method: "bad_method", params: [])
        }

        try await Task.sleep(nanoseconds: 10_000_000)

        try await transport.inject(
            message: .response(msgid: 0, error: .string("E123: unknown command"), result: .nil))

        do {
            _ = try await requestTask.value
            XCTFail("Expected responseError to be thrown")
        } catch RPCError.responseError(let errVal) {
            XCTAssertEqual(errVal, .string("E123: unknown command"))
        }

        await channel.stop()
    }

    // MARK: - Out-of-order responses (tests msgid correlation)

    func testOutOfOrderResponsesMatchedByMsgid() async throws {
        let transport = MockTransport()
        let channel = RPCChannel(transport: transport)
        try await channel.start()

        // Sequential start ensures deterministic msgid assignment: task0=0, task1=1.
        let task0 = Task<MsgPackValue, Error> { try await channel.request(method: "a", params: []) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let task1 = Task<MsgPackValue, Error> { try await channel.request(method: "b", params: []) }
        try await Task.sleep(nanoseconds: 10_000_000)

        // Reply to the SECOND request first (out of order).
        try await transport.inject(message: .response(msgid: 1, error: .nil, result: .string("second")))
        try await transport.inject(message: .response(msgid: 0, error: .nil, result: .string("first")))

        let v0 = try await task0.value
        let v1 = try await task1.value
        XCTAssertEqual(v0, .string("first"))
        XCTAssertEqual(v1, .string("second"))

        await channel.stop()
    }

    // MARK: - Notifications

    func testIncomingNotificationDelivered() async throws {
        let transport = MockTransport()
        let channel = RPCChannel(transport: transport)
        try await channel.start()

        try await transport.inject(
            message: .notification(method: "redraw", params: []))

        try await Task.sleep(nanoseconds: 20_000_000)

        let stream = await channel.notifications
        var received: RPCMessage?
        for await msg in stream {
            received = msg
            break
        }

        guard let msg = received else { XCTFail("Expected a notification"); return }
        XCTAssertEqual(msg.method, "redraw")
        XCTAssertTrue(msg.isNotification)

        await channel.stop()
    }

    func testIncomingRequestDeliveredAsNotification() async throws {
        let transport = MockTransport()
        let channel = RPCChannel(transport: transport)
        try await channel.start()

        try await transport.inject(
            message: .request(msgid: 99, method: "nvim_get_api_info", params: []))

        try await Task.sleep(nanoseconds: 20_000_000)

        let stream = await channel.notifications
        var received: RPCMessage?
        for await msg in stream {
            received = msg
            break
        }

        guard let msg = received else { XCTFail("Expected a request in notification stream"); return }
        XCTAssertEqual(msg.msgid, 99)
        XCTAssertTrue(msg.isRequest)

        await channel.stop()
    }

    // MARK: - Transport closed

    func testPendingRequestsFailWhenTransportCloses() async throws {
        let transport = MockTransport()
        let channel = RPCChannel(transport: transport)
        try await channel.start()

        let requestTask = Task<MsgPackValue, Error> {
            try await channel.request(method: "slow", params: [])
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        await transport.close()

        do {
            _ = try await requestTask.value
            XCTFail("Expected transportClosed error")
        } catch RPCError.transportClosed {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Fire-and-forget notification

    func testNotifyWritesToTransport() async throws {
        let transport = MockTransport()
        let channel = RPCChannel(transport: transport)
        try await channel.start()

        try await channel.notify(method: "redraw_ready", params: [.bool(true)])
        try await Task.sleep(nanoseconds: 10_000_000)

        let sentCount = await transport.sent.count
        XCTAssertGreaterThan(sentCount, 0)
        let msg = try await transport.lastSentMessage()
        XCTAssertEqual(msg?.method, "redraw_ready")
        XCTAssertTrue(msg?.isNotification ?? false)

        await channel.stop()
    }

    // MARK: - Chunked data reassembly

    func testChunkedMessageReassembly() async throws {
        let transport = MockTransport()
        let channel = RPCChannel(transport: transport)
        try await channel.start()

        let requestTask = Task<MsgPackValue, Error> {
            try await channel.request(method: "chunked", params: [])
        }

        try await Task.sleep(nanoseconds: 10_000_000)

        let response = RPCMessage.response(msgid: 0, error: .nil, result: .string("chunked_ok"))
        let fullData = try MsgPackEncoder().encode(response.toMsgPackValue())

        // Split at arbitrary byte boundaries and inject in pieces.
        await transport.inject(Data(fullData.prefix(3)))
        await transport.inject(Data(fullData.dropFirst(3).prefix(3)))
        await transport.inject(Data(fullData.dropFirst(6)))

        let result = try await requestTask.value
        XCTAssertEqual(result, .string("chunked_ok"))

        await channel.stop()
    }

    // MARK: - Two messages in one chunk

    func testTwoMessagesInOneChunk() async throws {
        let transport = MockTransport()
        let channel = RPCChannel(transport: transport)
        try await channel.start()

        let task1 = Task<MsgPackValue, Error> { try await channel.request(method: "a", params: []) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let task2 = Task<MsgPackValue, Error> { try await channel.request(method: "b", params: []) }
        try await Task.sleep(nanoseconds: 10_000_000)

        let encoder = MsgPackEncoder()
        var combined = try encoder.encode(
            RPCMessage.response(msgid: 0, error: .nil, result: .uint(1)).toMsgPackValue())
        combined.append(try encoder.encode(
            RPCMessage.response(msgid: 1, error: .nil, result: .uint(2)).toMsgPackValue()))

        // Deliver both responses in one chunk.
        await transport.inject(combined)

        let v1 = try await task1.value
        let v2 = try await task2.value
        XCTAssertEqual(v1, .uint(1))
        XCTAssertEqual(v2, .uint(2))

        await channel.stop()
    }

    // MARK: - Respond to incoming requests

    func testRespondWritesResponseToTransport() async throws {
        let transport = MockTransport()
        let channel = RPCChannel(transport: transport)
        try await channel.start()

        try await channel.respond(msgid: 7, error: .nil, result: .string("ok"))
        try await Task.sleep(nanoseconds: 10_000_000)

        let msg = try await transport.lastSentMessage()
        guard case .response(let msgid, let error, let result) = msg else {
            XCTFail("Expected response message"); return
        }
        XCTAssertEqual(msgid, 7)
        XCTAssertTrue(error.isNil)
        XCTAssertEqual(result, .string("ok"))

        await channel.stop()
    }
}
