// RPCMessage.swift
// NvimRPC
//
// MessagePack-RPC message types for Neovim communication.
// See: https://github.com/msgpack-rpc/msgpack-rpc/blob/master/spec.md

import Foundation
import MsgPack

/// The three message types in the MessagePack-RPC protocol.
///
/// Every message is a MessagePack array:
/// - Request:      `[type=0, msgid, method, params]`
/// - Response:     `[type=1, msgid, error, result]`
/// - Notification: `[type=2, method, params]`
public enum RPCMessage: Sendable, Equatable {
    /// A request from client to server (or vice versa).
    /// - Parameters:
    ///   - msgid: Unique 32-bit identifier for correlating request/response pairs.
    ///   - method: The RPC method name (e.g. `"nvim_input"`, `"nvim_buf_get_lines"`).
    ///   - params: Array of arguments to the method.
    case request(msgid: UInt32, method: String, params: [MsgPackValue])

    /// A response to a prior request.
    /// - Parameters:
    ///   - msgid: The `msgid` of the original request.
    ///   - error: Error value (`.nil` on success).
    ///   - result: Result value (`.nil` on error).
    case response(msgid: UInt32, error: MsgPackValue, result: MsgPackValue)

    /// A one-way notification (no response expected).
    /// - Parameters:
    ///   - method: The notification name (e.g. `"redraw"`).
    ///   - params: Array of arguments.
    case notification(method: String, params: [MsgPackValue])
}

// MARK: - RPC Type Constants

extension RPCMessage {
    /// Wire type identifier for request messages.
    public static let requestType: UInt64 = 0
    /// Wire type identifier for response messages.
    public static let responseType: UInt64 = 1
    /// Wire type identifier for notification messages.
    public static let notificationType: UInt64 = 2
}

// MARK: - Encoding to MsgPackValue

extension RPCMessage {
    /// Serialize this message into a `MsgPackValue` array suitable for
    /// encoding with `MsgPackEncoder`.
    public func toMsgPackValue() -> MsgPackValue {
        switch self {
        case .request(let msgid, let method, let params):
            return .array([
                .uint(RPCMessage.requestType),
                .uint(UInt64(msgid)),
                .string(method),
                .array(params),
            ])

        case .response(let msgid, let error, let result):
            return .array([
                .uint(RPCMessage.responseType),
                .uint(UInt64(msgid)),
                error,
                result,
            ])

        case .notification(let method, let params):
            return .array([
                .uint(RPCMessage.notificationType),
                .string(method),
                .array(params),
            ])
        }
    }
}

// MARK: - Decoding from MsgPackValue

extension RPCMessage {
    /// Errors encountered when parsing an `RPCMessage` from a `MsgPackValue`.
    public enum ParseError: Error, CustomStringConvertible, Sendable {
        case notAnArray
        case emptyArray
        case invalidTypeField(MsgPackValue)
        case unknownType(UInt64)
        case invalidRequestFormat(String)
        case invalidResponseFormat(String)
        case invalidNotificationFormat(String)

        public var description: String {
            switch self {
            case .notAnArray:
                return "RPCMessage: top-level value is not an array"
            case .emptyArray:
                return "RPCMessage: top-level array is empty"
            case .invalidTypeField(let v):
                return "RPCMessage: type field is not a valid integer: \(v)"
            case .unknownType(let t):
                return "RPCMessage: unknown message type \(t)"
            case .invalidRequestFormat(let detail):
                return "RPCMessage: invalid request format — \(detail)"
            case .invalidResponseFormat(let detail):
                return "RPCMessage: invalid response format — \(detail)"
            case .invalidNotificationFormat(let detail):
                return "RPCMessage: invalid notification format — \(detail)"
            }
        }
    }

    /// Parse an `RPCMessage` from a decoded `MsgPackValue`.
    ///
    /// The value must be an array in one of the three canonical forms.
    public static func parse(from value: MsgPackValue) throws -> RPCMessage {
        guard case .array(let elements) = value else {
            throw ParseError.notAnArray
        }
        guard !elements.isEmpty else {
            throw ParseError.emptyArray
        }

        let typeValue: UInt64
        switch elements[0] {
        case .uint(let u):
            typeValue = u
        case .int(let i) where i >= 0:
            typeValue = UInt64(i)
        default:
            throw ParseError.invalidTypeField(elements[0])
        }

        switch typeValue {
        case RPCMessage.requestType:
            return try parseRequest(elements)
        case RPCMessage.responseType:
            return try parseResponse(elements)
        case RPCMessage.notificationType:
            return try parseNotification(elements)
        default:
            throw ParseError.unknownType(typeValue)
        }
    }

    // MARK: Private Parsers

    private static func parseRequest(_ elements: [MsgPackValue]) throws -> RPCMessage {
        guard elements.count == 4 else {
            throw ParseError.invalidRequestFormat("expected 4 elements, got \(elements.count)")
        }

        let msgid: UInt32
        switch elements[1] {
        case .uint(let u):
            guard let id = UInt32(exactly: u) else {
                throw ParseError.invalidRequestFormat("msgid \(u) overflows UInt32")
            }
            msgid = id
        case .int(let i) where i >= 0:
            guard let id = UInt32(exactly: i) else {
                throw ParseError.invalidRequestFormat("msgid \(i) overflows UInt32")
            }
            msgid = id
        default:
            throw ParseError.invalidRequestFormat("msgid is not a valid integer: \(elements[1])")
        }

        guard case .string(let method) = elements[2] else {
            throw ParseError.invalidRequestFormat("method is not a string: \(elements[2])")
        }

        guard case .array(let params) = elements[3] else {
            throw ParseError.invalidRequestFormat("params is not an array: \(elements[3])")
        }

        return .request(msgid: msgid, method: method, params: params)
    }

    private static func parseResponse(_ elements: [MsgPackValue]) throws -> RPCMessage {
        guard elements.count == 4 else {
            throw ParseError.invalidResponseFormat("expected 4 elements, got \(elements.count)")
        }

        let msgid: UInt32
        switch elements[1] {
        case .uint(let u):
            guard let id = UInt32(exactly: u) else {
                throw ParseError.invalidResponseFormat("msgid \(u) overflows UInt32")
            }
            msgid = id
        case .int(let i) where i >= 0:
            guard let id = UInt32(exactly: i) else {
                throw ParseError.invalidResponseFormat("msgid \(i) overflows UInt32")
            }
            msgid = id
        default:
            throw ParseError.invalidResponseFormat("msgid is not a valid integer: \(elements[1])")
        }

        let error = elements[2]
        let result = elements[3]

        return .response(msgid: msgid, error: error, result: result)
    }

    private static func parseNotification(_ elements: [MsgPackValue]) throws -> RPCMessage {
        guard elements.count == 3 else {
            throw ParseError.invalidNotificationFormat("expected 3 elements, got \(elements.count)")
        }

        guard case .string(let method) = elements[1] else {
            throw ParseError.invalidNotificationFormat("method is not a string: \(elements[1])")
        }

        guard case .array(let params) = elements[2] else {
            throw ParseError.invalidNotificationFormat("params is not an array: \(elements[2])")
        }

        return .notification(method: method, params: params)
    }
}

// MARK: - Convenience Properties

extension RPCMessage {
    /// The method name for requests and notifications, `nil` for responses.
    public var method: String? {
        switch self {
        case .request(_, let method, _): return method
        case .notification(let method, _): return method
        case .response: return nil
        }
    }

    /// The message ID for requests and responses, `nil` for notifications.
    public var msgid: UInt32? {
        switch self {
        case .request(let id, _, _): return id
        case .response(let id, _, _): return id
        case .notification: return nil
        }
    }

    /// The parameters for requests and notifications, `nil` for responses.
    public var params: [MsgPackValue]? {
        switch self {
        case .request(_, _, let params): return params
        case .notification(_, let params): return params
        case .response: return nil
        }
    }

    /// Whether this is a request message.
    public var isRequest: Bool {
        if case .request = self { return true }
        return false
    }

    /// Whether this is a response message.
    public var isResponse: Bool {
        if case .response = self { return true }
        return false
    }

    /// Whether this is a notification message.
    public var isNotification: Bool {
        if case .notification = self { return true }
        return false
    }
}

// MARK: - CustomStringConvertible

extension RPCMessage: CustomStringConvertible {
    public var description: String {
        switch self {
        case .request(let msgid, let method, let params):
            return "Request(id=\(msgid), method=\"\(method)\", params=\(params))"
        case .response(let msgid, let error, let result):
            return "Response(id=\(msgid), error=\(error), result=\(result))"
        case .notification(let method, let params):
            return "Notification(method=\"\(method)\", params=\(params))"
        }
    }
}