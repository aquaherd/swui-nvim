// SSHTransport.swift
// Transport
//
// Placeholder for NIOSSH-based remote Neovim transport.
// Connects to a remote host via SSH, executes `nvim --headless`,
// and tunnels MsgPack-RPC over the SSH exec channel.
//
// Dependencies (to be added to Package.swift when implemented):
//   - swift-nio
//   - swift-nio-ssh

import Foundation

/// Configuration for establishing an SSH connection to a remote Neovim instance.
public struct SSHConnectionConfig: Sendable, Codable, Hashable {
    /// Remote hostname or IP address.
    public var host: String

    /// SSH port (default 22).
    public var port: UInt16

    /// Username for authentication.
    public var username: String

    /// Authentication method to use.
    public var authentication: SSHAuthentication

    /// Command to execute on the remote host.
    /// Defaults to `nvim --headless --embed`.
    public var remoteCommand: String

    /// Connection timeout in seconds.
    public var connectTimeout: TimeInterval

    /// Optional path to a known_hosts file for host key verification.
    public var knownHostsPath: String?

    public init(
        host: String,
        port: UInt16 = 22,
        username: String,
        authentication: SSHAuthentication = .agent,
        remoteCommand: String = "nvim --headless --embed",
        connectTimeout: TimeInterval = 30,
        knownHostsPath: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.remoteCommand = remoteCommand
        self.connectTimeout = connectTimeout
        self.knownHostsPath = knownHostsPath
    }
}

/// SSH authentication methods supported by the transport.
public enum SSHAuthentication: Sendable, Codable, Hashable {
    /// Use the system SSH agent for key-based auth.
    case agent

    /// Password authentication (stored in Keychain at runtime, never persisted to disk).
    case password(String)

    /// Path to a private key file, with an optional passphrase.
    case privateKey(path: String, passphrase: String?)
}

/// Connection state for the SSH transport.
public enum SSHConnectionState: Sendable, Hashable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case failed(String)
}

/// SSH transport that connects to a remote Neovim instance over SSH.
///
/// This is currently a **stub implementation**. The actual networking will be
/// provided by `NIOSSH` (Apple's Swift-native SSH library) which uses
/// `CryptoKit` under the hood — no custom crypto, no export compliance issues.
///
/// ## Architecture
///
/// ```
/// SSHTransport
///   ├─ NIOSSHClient (event loop, channel pipeline)
///   │    ├─ Host key verification (known_hosts or Trust-On-First-Use)
///   │    ├─ Authentication handler (agent / password / key file)
///   │    └─ Exec channel handler
///   │         ├─ stdin  → send(Data)
///   │         └─ stdout → received AsyncThrowingStream<Data, Error>
///   └─ Reconnection logic (exponential backoff)
/// ```
public final class SSHTransport: NvimTransport, @unchecked Sendable {

    /// The SSH connection configuration.
    public let config: SSHConnectionConfig

    /// Observable connection state.
    public private(set) var state: SSHConnectionState = .disconnected

    // MARK: - NvimTransport conformance

    /// The stream of data received from the remote Neovim process's stdout.
    public var received: AsyncThrowingStream<Data, Error> {
        // TODO: Return the real channel output stream once NIOSSH is integrated.
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: SSHTransportError.notImplemented)
        }
    }

    public init(config: SSHConnectionConfig) {
        self.config = config
    }

    /// Establish the SSH connection, authenticate, and exec the remote nvim process.
    ///
    /// Once implemented, this will:
    /// 1. Resolve the hostname and connect a TCP socket via `NIOClientTCPBootstrap`.
    /// 2. Add the `NIOSSHHandler` to the channel pipeline.
    /// 3. Perform host key verification against `config.knownHostsPath`.
    /// 4. Authenticate using the configured `SSHAuthentication` method.
    /// 5. Open an exec channel running `config.remoteCommand`.
    /// 6. Bridge the channel's inbound/outbound to `received` / `send(_:)`.
    public func start() async throws {
        state = .connecting
        // TODO: Implement NIOSSH connection setup.
        //
        // Rough implementation outline:
        //
        // let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        // let bootstrap = ClientBootstrap(group: group)
        //     .channelInitializer { channel in
        //         channel.pipeline.addHandlers([
        //             NIOSSHHandler(
        //                 role: .client(.init(
        //                     userAuthDelegate: authDelegate,
        //                     serverAuthDelegate: hostKeyVerifier
        //                 )),
        //                 allocator: channel.allocator,
        //                 inboundChildChannelInitializer: nil
        //             )
        //         ])
        //     }
        //
        // let channel = try await bootstrap.connect(
        //     host: config.host,
        //     port: Int(config.port)
        // ).get()
        //
        // let execChannel = try await channel.pipeline
        //     .handler(type: NIOSSHHandler.self)
        //     .flatMap { handler in
        //         handler.createChannel(nil) { childChannel, channelType in
        //             guard channelType == .session else { return childChannel.close() }
        //             return childChannel.pipeline.addHandlers([
        //                 ExecRequestHandler(command: config.remoteCommand),
        //                 DataBridgeHandler(continuation: streamContinuation)
        //             ])
        //         }
        //     }.get()

        state = .failed("SSH transport not yet implemented")
        throw SSHTransportError.notImplemented
    }

    /// Send data to the remote Neovim process's stdin.
    public func send(_ data: Data) async throws {
        guard state == .connected else {
            throw SSHTransportError.notConnected
        }
        // TODO: Write `data` into the SSH exec channel's outbound buffer.
    }

    /// Gracefully close the SSH connection.
    public func stop() async {
        // TODO: Close the exec channel, then the SSH connection, then the event loop group.
        state = .disconnected
    }
}

// MARK: - Errors

/// Errors specific to the SSH transport layer.
public enum SSHTransportError: Error, LocalizedError, Sendable {
    case notImplemented
    case notConnected
    case connectionFailed(String)
    case authenticationFailed(String)
    case hostKeyVerificationFailed(String)
    case channelOpenFailed(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "SSH transport is not yet implemented."
        case .notConnected:
            return "Not connected to the remote host."
        case .connectionFailed(let reason):
            return "SSH connection failed: \(reason)"
        case .authenticationFailed(let reason):
            return "SSH authentication failed: \(reason)"
        case .hostKeyVerificationFailed(let reason):
            return "Host key verification failed: \(reason)"
        case .channelOpenFailed(let reason):
            return "Failed to open SSH exec channel: \(reason)"
        case .timeout:
            return "SSH connection timed out."
        }
    }
}

// MARK: - Bookmark Persistence (for saved servers)

/// A saved SSH server bookmark, suitable for persistence via Codable.
///
/// Passwords and key passphrases should be stored in the Keychain
/// separately, referenced by `id`. This struct only holds non-sensitive
/// connection metadata.
public struct SSHBookmark: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var remoteCommand: String
    public var useAgent: Bool
    public var privateKeyPath: String?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16 = 22,
        username: String,
        remoteCommand: String = "nvim --headless --embed",
        useAgent: Bool = true,
        privateKeyPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.remoteCommand = remoteCommand
        self.useAgent = useAgent
        self.privateKeyPath = privateKeyPath
    }

    /// Convert this bookmark into a connection config.
    ///
    /// - Parameter password: Optional password retrieved from Keychain.
    /// - Parameter passphrase: Optional key passphrase retrieved from Keychain.
    /// - Returns: A fully populated `SSHConnectionConfig`.
    public func toConnectionConfig(
        password: String? = nil,
        passphrase: String? = nil
    ) -> SSHConnectionConfig {
        let auth: SSHAuthentication
        if useAgent {
            auth = .agent
        } else if let keyPath = privateKeyPath {
            auth = .privateKey(path: keyPath, passphrase: passphrase)
        } else if let password = password {
            auth = .password(password)
        } else {
            auth = .agent // fallback
        }

        return SSHConnectionConfig(
            host: host,
            port: port,
            username: username,
            authentication: auth,
            remoteCommand: remoteCommand
        )
    }
}