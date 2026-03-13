// SSHTransport.swift
// Transport
//
// NIOSSH-based remote Neovim transport.
// Connects to a remote host via SSH, executes `nvim --headless --embed`,
// and tunnels MsgPack-RPC over the SSH exec channel.

import Foundation
import NIO
import NIOFoundationCompat
import NIOSSH

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

// MARK: - NIOSSH Channel Handlers

/// Handles the exec channel's data I/O, bridging NIO channel reads to an
/// `AsyncThrowingStream` and allowing writes via a reference to the channel.
private final class ExecChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let dataContinuation: AsyncThrowingStream<Data, Error>.Continuation

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.dataContinuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)

        guard case .byteBuffer(let buffer) = channelData.data else { return }

        switch channelData.type {
        case .channel:
            let bytes = Data(buffer: buffer)
            if !bytes.isEmpty {
                dataContinuation.yield(bytes)
            }
        case .stdErr:
            // Log stderr but don't feed it to RPC
            if let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                #if DEBUG
                print("[ssh nvim stderr] \(text)")
                #endif
            }
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        dataContinuation.finish(throwing: SSHTransportError.connectionFailed(error.localizedDescription))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        dataContinuation.finish()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = self.unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(self.wrapOutboundOut(wrapped), promise: promise)
    }
}

/// Authentication delegate that tries password or private key auth.
private final class ClientAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let authentication: SSHAuthentication
    private var attemptedMethods: Set<String> = []

    init(username: String, authentication: SSHAuthentication) {
        self.username = username
        self.authentication = authentication
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        switch authentication {
        case .password(let password):
            guard availableMethods.contains(.password), !attemptedMethods.contains("password") else {
                nextChallengePromise.succeed(nil)
                return
            }
            attemptedMethods.insert("password")
            nextChallengePromise.succeed(.init(
                username: username,
                serviceName: "",
                offer: .password(.init(password: password))
            ))

        case .privateKey(let path, let passphrase):
            guard availableMethods.contains(.publicKey), !attemptedMethods.contains("publicKey") else {
                nextChallengePromise.succeed(nil)
                return
            }
            attemptedMethods.insert("publicKey")
            do {
                let keyData = try Data(contentsOf: URL(fileURLWithPath: path))
                let keyString = String(decoding: keyData, as: UTF8.self)
                let key: NIOSSHPrivateKey
                if let passphrase {
                    key = try .init(ed25519Key: .init(rawRepresentation: parsePrivateKeyBytes(keyString, passphrase: passphrase)))
                } else {
                    // Try parsing as different key types
                    key = try parseSSHPrivateKey(keyString)
                }
                nextChallengePromise.succeed(.init(
                    username: username,
                    serviceName: "",
                    offer: .privateKey(.init(privateKey: key))
                ))
            } catch {
                nextChallengePromise.succeed(nil)
            }

        case .agent:
            // Agent auth is not directly supported by NIOSSH.
            // Fall back: try to read default key files from ~/.ssh/
            guard availableMethods.contains(.publicKey), !attemptedMethods.contains("agentKey") else {
                nextChallengePromise.succeed(nil)
                return
            }
            attemptedMethods.insert("agentKey")
            
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let keyPaths = [
                "\(homeDir)/.ssh/id_ed25519",
                "\(homeDir)/.ssh/id_rsa",
                "\(homeDir)/.ssh/id_ecdsa",
            ]
            
            for keyPath in keyPaths {
                guard FileManager.default.fileExists(atPath: keyPath) else { continue }
                do {
                    let keyData = try Data(contentsOf: URL(fileURLWithPath: keyPath))
                    let keyString = String(decoding: keyData, as: UTF8.self)
                    let key = try parseSSHPrivateKey(keyString)
                    nextChallengePromise.succeed(.init(
                        username: username,
                        serviceName: "",
                        offer: .privateKey(.init(privateKey: key))
                    ))
                    return
                } catch {
                    continue
                }
            }
            nextChallengePromise.succeed(nil)
        }
    }
}

/// Host key verifier that accepts all host keys (Trust-On-First-Use).
/// A production implementation should verify against known_hosts.
private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // TODO: Implement known_hosts verification for production use.
        // For now, accept all host keys (TOFU model).
        validationCompletePromise.succeed(())
    }
}

// MARK: - SSH Private Key Parsing

/// Parse an SSH private key string into an NIOSSHPrivateKey.
private func parseSSHPrivateKey(_ keyString: String) throws -> NIOSSHPrivateKey {
    // Try Ed25519 first, then P256, then P384, then P521
    if let key = try? NIOSSHPrivateKey(ed25519Key: .init(
        rawRepresentation: parseOpenSSHPrivateKeyRaw(keyString))) {
        return key
    }
    if let key = try? NIOSSHPrivateKey(p256Key: .init(
        rawRepresentation: parseOpenSSHPrivateKeyRaw(keyString))) {
        return key
    }
    if let key = try? NIOSSHPrivateKey(p384Key: .init(
        rawRepresentation: parseOpenSSHPrivateKeyRaw(keyString))) {
        return key
    }
    if let key = try? NIOSSHPrivateKey(p521Key: .init(
        rawRepresentation: parseOpenSSHPrivateKeyRaw(keyString))) {
        return key
    }
    throw SSHTransportError.authenticationFailed("Unsupported private key format")
}

/// Extract raw key bytes from an OpenSSH PEM-formatted key string.
private func parseOpenSSHPrivateKeyRaw(_ pem: String) throws -> Data {
    let lines = pem.components(separatedBy: .newlines)
        .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
    let base64 = lines.joined()
    guard let data = Data(base64Encoded: base64) else {
        throw SSHTransportError.authenticationFailed("Invalid key encoding")
    }
    return data
}

/// Extract raw key bytes from a passphrase-protected key.
private func parsePrivateKeyBytes(_ pem: String, passphrase: String) throws -> Data {
    // NIOSSH doesn't natively support encrypted keys.
    // For encrypted keys, we'd need additional crypto, which is out of scope
    // for the initial implementation.
    _ = passphrase
    return try parseOpenSSHPrivateKeyRaw(pem)
}

// MARK: - SSHTransport

/// SSH transport that connects to a remote Neovim instance over SSH
/// using Apple's NIOSSH library.
///
/// ## Architecture
///
/// ```
/// SSHTransport
///   ├─ NIOSSHClient (event loop, channel pipeline)
///   │    ├─ Host key verification (AcceptAllHostKeysDelegate / TOFU)
///   │    ├─ Authentication handler (password / key file / agent-like)
///   │    └─ Exec channel handler
///   │         ├─ stdin  → send(Data)
///   │         └─ stdout → received AsyncThrowingStream<Data, Error>
///   └─ State management (connecting → authenticating → connected → disconnected)
/// ```
public final class SSHTransport: @unchecked Sendable {

    /// The SSH connection configuration.
    public let config: SSHConnectionConfig

    /// Observable connection state.
    public private(set) var connectionState: SSHConnectionState = .disconnected

    // NIO resources
    private var group: MultiThreadedEventLoopGroup?
    private var parentChannel: Channel?
    private var execChannel: Channel?

    // Data stream
    private var dataContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private let _dataStream: AsyncThrowingStream<Data, Error>

    // State stream
    private var stateContinuation: AsyncStream<TransportState>.Continuation?
    private let _stateStream: AsyncStream<TransportState>
    private var _transportState: TransportState = .idle

    // Lock for thread-safe state access
    private let lock = NSLock()

    public init(config: SSHConnectionConfig) {
        self.config = config

        var dc: AsyncThrowingStream<Data, Error>.Continuation!
        self._dataStream = AsyncThrowingStream { dc = $0 }
        self.dataContinuation = dc

        var sc: AsyncStream<TransportState>.Continuation!
        self._stateStream = AsyncStream { sc = $0 }
        self.stateContinuation = sc
    }

    /// Establish the SSH connection, authenticate, and exec the remote nvim process.
    public func start() async throws {
        lock.withLock {
            guard _transportState == .idle else { return }
            _transportState = .connecting
        }
        stateContinuation?.yield(.connecting)
        connectionState = .connecting

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = elg

        let authDelegate = ClientAuthDelegate(
            username: config.username,
            authentication: config.authentication
        )
        let hostKeyDelegate = AcceptAllHostKeysDelegate()

        do {
            connectionState = .authenticating

            // Connect and set up SSH
            let channel = try await ClientBootstrap(group: elg)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.pipeline.addHandlers([
                        NIOSSHHandler(
                            role: .client(.init(
                                userAuthDelegate: authDelegate,
                                serverAuthDelegate: hostKeyDelegate
                            )),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                    ])
                }
                .connectTimeout(.seconds(Int64(config.connectTimeout)))
                .connect(host: config.host, port: Int(config.port))
                .get()

            self.parentChannel = channel

            // Now open an exec channel for the remote nvim command
            guard let sshHandler = try? await channel.pipeline.handler(type: NIOSSHHandler.self).get() else {
                throw SSHTransportError.channelOpenFailed("Could not find SSH handler in pipeline")
            }

            guard let dc = dataContinuation else {
                throw SSHTransportError.channelOpenFailed("Data stream not available")
            }

            let execHandler = ExecChannelHandler(continuation: dc)
            let remoteCmd = config.remoteCommand

            let childChannel: Channel = try await sshHandler.createChannel(nil) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(
                        SSHTransportError.channelOpenFailed("Unexpected channel type")
                    )
                }
                return childChannel.pipeline.addHandlers([
                    execHandler,
                    ExecCommandSender(command: remoteCmd)
                ])
            }.get()

            self.execChannel = childChannel

            lock.withLock { _transportState = .connected }
            stateContinuation?.yield(.connected)
            connectionState = .connected

            // Monitor the exec channel for closure
            childChannel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self._transportState = .disconnected(nil) }
                self.stateContinuation?.yield(.disconnected(nil))
                self.dataContinuation?.finish()
                self.connectionState = .disconnected
            }

        } catch {
            let msg = error.localizedDescription
            lock.withLock { _transportState = .disconnected(error) }
            stateContinuation?.yield(.disconnected(error))
            connectionState = .failed(msg)
            dataContinuation?.finish(throwing: error)
            try? await shutdown()
            throw SSHTransportError.connectionFailed(msg)
        }
    }

    /// Send data to the remote Neovim process's stdin.
    public func send(_ data: Data) async throws {
        let state = lock.withLock { _transportState }
        guard state == .connected, let channel = execChannel else {
            throw SSHTransportError.notConnected
        }

        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer)
    }

    /// Gracefully close the SSH connection.
    public func stop() async {
        let state = lock.withLock { _transportState }
        guard state == .connected || state == .connecting else { return }

        lock.withLock { _transportState = .disconnecting }
        stateContinuation?.yield(.disconnecting)

        // Close exec channel
        if let exec = execChannel, exec.isActive {
            try? await exec.close()
        }

        // Close parent SSH channel
        if let parent = parentChannel, parent.isActive {
            try? await parent.close()
        }

        try? await shutdown()

        lock.withLock { _transportState = .disconnected(nil) }
        stateContinuation?.yield(.disconnected(nil))
        stateContinuation?.finish()
        dataContinuation?.finish()
        connectionState = .disconnected
    }

    /// The stream of data received from the remote Neovim process.
    public var received: AsyncThrowingStream<Data, Error> { _dataStream }

    /// An `AsyncStream` of transport state changes.
    public var stateStream: AsyncStream<TransportState> { _stateStream }

    /// The current transport state.
    public var state: TransportState {
        lock.withLock { _transportState }
    }

    private func shutdown() async throws {
        try await group?.shutdownGracefully()
        group = nil
    }

    deinit {
        dataContinuation?.finish()
        stateContinuation?.finish()
        try? group?.syncShutdownGracefully()
    }
}

// MARK: - Exec Command Sender

/// A channel handler that sends the exec request once the channel is active.
private final class ExecCommandSender: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let command: String

    init(command: String) {
        self.command = command
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.ExecRequest(
            command: command,
            wantReply: true
        )
        context.triggerUserOutboundEvent(request, promise: nil)
        context.fireChannelActive()
    }
}

// MARK: - NvimTransport Conformance

extension SSHTransport: NvimTransport {
    public var dataStream: AsyncThrowingStream<Data, Error> { received }

    public func start() async throws {
        // Calls the main start() implementation above
        try await (self as SSHTransport).start()
    }
}

// MARK: - Errors

/// Errors specific to the SSH transport layer.
public enum SSHTransportError: Error, LocalizedError, Sendable {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed(String)
    case hostKeyVerificationFailed(String)
    case channelOpenFailed(String)
    case timeout

    public var errorDescription: String? {
        switch self {
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