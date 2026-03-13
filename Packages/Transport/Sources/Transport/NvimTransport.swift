// NvimTransport.swift
// Transport
//
// Protocol abstraction for Neovim RPC byte-stream transports.

import Foundation

/// The state of a transport connection.
public enum TransportState: Sendable, Equatable {
    /// The transport has not been started yet.
    case idle
    /// The transport is in the process of connecting.
    case connecting
    /// The transport is connected and ready for I/O.
    case connected
    /// The transport is disconnecting.
    case disconnecting
    /// The transport has been disconnected (possibly with an error).
    case disconnected(Error?)

    public static func == (lhs: TransportState, rhs: TransportState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.connecting, .connecting),
             (.connected, .connected),
             (.disconnecting, .disconnecting):
            return true
        case (.disconnected(let lErr), .disconnected(let rErr)):
            return lErr?.localizedDescription == rErr?.localizedDescription
        default:
            return false
        }
    }
}

/// Errors specific to transport operations.
public enum TransportError: Error, Sendable {
    /// The transport is not in a valid state for the requested operation.
    case invalidState(TransportState)
    /// The remote end closed the connection.
    case connectionClosed
    /// An I/O error occurred during read or write.
    case ioError(String)
    /// The transport failed to start with the given reason.
    case startFailed(String)
    /// A timeout occurred waiting for a connection or I/O.
    case timeout
}

/// A transport carries raw bytes between the Neovim RPC client and a Neovim
/// process — either local (stdio pipes) or remote (SSH channel).
///
/// Implementations must be safe to use from any actor/task context.
///
/// ## Lifecycle
///
/// 1. Create the transport (configuration only, no I/O).
/// 2. Call ``start()`` to initiate the connection. This may involve spawning a
///    local process or establishing an SSH session.
/// 3. Use ``send(_:)`` to write outbound data and iterate ``dataStream`` to
///    read inbound data.
/// 4. Call ``stop()`` to tear down the connection gracefully.
///
public protocol NvimTransport: AnyObject, Sendable {

    /// The current state of the transport.
    var state: TransportState { get async }

    /// An `AsyncStream` that emits transport state changes.
    ///
    /// Consumers can observe this to react to disconnections and reconnections.
    var stateStream: AsyncStream<TransportState> { get }

    /// Start the transport (connect, spawn process, etc.).
    ///
    /// This method should be called exactly once. Calling it on a transport
    /// that is already started or stopped throws ``TransportError/invalidState(_:)``.
    ///
    /// - Throws: ``TransportError`` if the connection cannot be established.
    func start() async throws

    /// Send raw data to the Neovim process.
    ///
    /// The data is expected to be a complete or partial MessagePack-RPC frame.
    /// The transport does not perform framing — it writes bytes verbatim.
    ///
    /// - Parameter data: The bytes to send.
    /// - Throws: ``TransportError`` if the transport is not connected or the
    ///   write fails.
    func send(_ data: Data) async throws

    /// An `AsyncThrowingStream` that yields chunks of data received from the
    /// Neovim process.
    ///
    /// The stream completes (finishes) when the transport is stopped or the
    /// remote end closes the connection. It throws on I/O errors.
    ///
    /// Each yielded `Data` chunk is an arbitrary slice of the byte stream —
    /// it may contain partial MessagePack messages. The RPC layer above is
    /// responsible for buffering and framing.
    var dataStream: AsyncThrowingStream<Data, Error> { get }

    /// Gracefully stop the transport.
    ///
    /// After this call returns, no more data will be yielded from
    /// ``dataStream`` and calls to ``send(_:)`` will throw.
    ///
    /// This method is idempotent — calling it on an already-stopped transport
    /// is a no-op.
    func stop() async
}

// MARK: - Transport Configuration Types

/// Configuration for connecting to a local Neovim process.
public struct LocalTransportConfig: Sendable {
    /// Path to the `nvim` executable.
    public var nvimPath: String

    /// Additional command-line arguments passed to `nvim`.
    /// The `--embed` flag is always added automatically.
    public var extraArguments: [String]

    /// Environment variables to set for the spawned process.
    /// If `nil`, inherits the current process environment.
    public var environment: [String: String]?

    /// Working directory for the nvim process.
    /// If `nil`, inherits the current working directory.
    public var workingDirectory: String?

    public init(
        nvimPath: String = "/opt/homebrew/bin/nvim",
        extraArguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil
    ) {
        self.nvimPath = nvimPath
        self.extraArguments = extraArguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

// MARK: - Transport Factory

/// Creates transport instances from configuration.
public enum TransportFactory {
    /// Create a transport for a local Neovim process.
    ///
    /// - Note: Only available on macOS. On iPadOS, local transport is not
    ///   supported because there is no local `nvim` binary.
    #if os(macOS)
    public static func local(config: LocalTransportConfig = .init()) -> any NvimTransport {
        LocalTransport(config: config)
    }
    #endif

    /// Create a transport for a remote Neovim process over SSH.
    public static func ssh(config: SSHConnectionConfig) -> SSHTransport {
        SSHTransport(config: config)
    }
}