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

/// Authentication method for SSH connections.
public enum SSHAuthMethod: Sendable {
    /// Password authentication.
    case password(String)

    /// Public key authentication with an identity file.
    /// The passphrase is optional (for encrypted keys).
    case publicKey(privateKeyPath: String, passphrase: String?)

    /// SSH agent-based authentication (forward to system SSH agent).
    case agent
}

/// Configuration for connecting to a remote Neovim process over SSH.
public struct SSHTransportConfig: Sendable {
    /// Remote hostname or IP address.
    public var host: String

    /// SSH port (default 22).
    public var port: UInt16

    /// Username for SSH authentication.
    public var username: String

    /// Authentication method(s) to try, in order.
    public var authMethods: [SSHAuthMethod]

    /// The command to execute on the remote host.
    /// Defaults to `nvim --headless --embed`.
    public var remoteCommand: String

    /// Known hosts file path. If `nil`, uses the default `~/.ssh/known_hosts`.
    public var knownHostsPath: String?

    /// Connection timeout in seconds.
    public var connectTimeout: TimeInterval

    public init(
        host: String,
        port: UInt16 = 22,
        username: String,
        authMethods: [SSHAuthMethod] = [.agent],
        remoteCommand: String = "nvim --headless --embed",
        knownHostsPath: String? = nil,
        connectTimeout: TimeInterval = 30
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethods = authMethods
        self.remoteCommand = remoteCommand
        self.knownHostsPath = knownHostsPath
        self.connectTimeout = connectTimeout
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
    public static func ssh(config: SSHTransportConfig) -> any NvimTransport {
        SSHTransport(config: config)
    }
}

// MARK: - Placeholder Implementations

// These are scaffolds; full implementations will follow in subsequent files.

#if os(macOS)
/// Transport that spawns a local `nvim --embed` process and communicates via stdio.
public final class LocalTransport: NvimTransport, @unchecked Sendable {
    private let config: LocalTransportConfig
    private var _state: TransportState = .idle
    private let stateContinuation: AsyncStream<TransportState>.Continuation
    private let _stateStream: AsyncStream<TransportState>
    private let dataContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let _dataStream: AsyncThrowingStream<Data, Error>

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?

    public init(config: LocalTransportConfig) {
        self.config = config
        var sc: AsyncStream<TransportState>.Continuation!
        self._stateStream = AsyncStream { sc = $0 }
        self.stateContinuation = sc

        var dc: AsyncThrowingStream<Data, Error>.Continuation!
        self._dataStream = AsyncThrowingStream { dc = $0 }
        self.dataContinuation = dc
    }

    public var state: TransportState {
        get async { _state }
    }

    public var stateStream: AsyncStream<TransportState> { _stateStream }
    public var dataStream: AsyncThrowingStream<Data, Error> { _dataStream }

    public func start() async throws {
        guard _state == .idle else {
            throw TransportError.invalidState(_state)
        }

        _state = .connecting
        stateContinuation.yield(.connecting)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.nvimPath)
        proc.arguments = ["--embed"] + config.extraArguments

        if let env = config.environment {
            proc.environment = env
        }
        if let cwd = config.workingDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout

        // Read stdout in a background task
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                self.dataContinuation.finish()
            } else {
                self.dataContinuation.yield(data)
            }
        }

        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self._state = .disconnected(nil)
            self.stateContinuation.yield(.disconnected(nil))
            self.stateContinuation.finish()
            self.dataContinuation.finish()
        }

        do {
            try proc.run()
            _state = .connected
            stateContinuation.yield(.connected)
        } catch {
            _state = .disconnected(error)
            stateContinuation.yield(.disconnected(error))
            stateContinuation.finish()
            dataContinuation.finish(throwing: error)
            throw TransportError.startFailed(error.localizedDescription)
        }
    }

    public func send(_ data: Data) async throws {
        guard _state == .connected, let pipe = stdinPipe else {
            throw TransportError.invalidState(_state)
        }
        pipe.fileHandleForWriting.write(data)
    }

    public func stop() async {
        guard _state == .connected || _state == .connecting else { return }

        _state = .disconnecting
        stateContinuation.yield(.disconnecting)

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdinPipe?.fileHandleForWriting.closeFile()

        if let proc = process, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }

        _state = .disconnected(nil)
        stateContinuation.yield(.disconnected(nil))
        stateContinuation.finish()
        dataContinuation.finish()
    }
}
#endif

/// Transport that connects to a remote Neovim process over SSH.
///
/// This is a scaffold — the full implementation will use NIOSSH or Citadel
/// for in-process SSH without shelling out.
public final class SSHTransport: NvimTransport, @unchecked Sendable {
    private let config: SSHTransportConfig
    private var _state: TransportState = .idle
    private let stateContinuation: AsyncStream<TransportState>.Continuation
    private let _stateStream: AsyncStream<TransportState>
    private let dataContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let _dataStream: AsyncThrowingStream<Data, Error>

    public init(config: SSHTransportConfig) {
        self.config = config

        var sc: AsyncStream<TransportState>.Continuation!
        self._stateStream = AsyncStream { sc = $0 }
        self.stateContinuation = sc

        var dc: AsyncThrowingStream<Data, Error>.Continuation!
        self._dataStream = AsyncThrowingStream { dc = $0 }
        self.dataContinuation = dc
    }

    public var state: TransportState {
        get async { _state }
    }

    public var stateStream: AsyncStream<TransportState> { _stateStream }
    public var dataStream: AsyncThrowingStream<Data, Error> { _dataStream }

    public func start() async throws {
        guard _state == .idle else {
            throw TransportError.invalidState(_state)
        }

        _state = .connecting
        stateContinuation.yield(.connecting)

        // TODO: Implement NIOSSH connection
        // 1. Resolve host
        // 2. Create NIOSSHClient bootstrap
        // 3. Authenticate using config.authMethods
        // 4. Open exec channel with config.remoteCommand
        // 5. Bridge channel I/O to dataStream / send()

        throw TransportError.startFailed(
            "SSH transport not yet implemented. Host: \(config.host):\(config.port)"
        )
    }

    public func send(_ data: Data) async throws {
        guard _state == .connected else {
            throw TransportError.invalidState(_state)
        }

        // TODO: Write data to SSH channel
        throw TransportError.ioError("SSH send not yet implemented")
    }

    public func stop() async {
        guard _state == .connected || _state == .connecting else { return }

        _state = .disconnecting
        stateContinuation.yield(.disconnecting)

        // TODO: Close SSH channel and session

        _state = .disconnected(nil)
        stateContinuation.yield(.disconnected(nil))
        stateContinuation.finish()
        dataContinuation.finish()
    }
}