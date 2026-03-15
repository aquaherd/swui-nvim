// SSHRPCTransport.swift
// SWUINeovimMac
//
// Adapts the Transport package's SSHTransport to NvimRPC's RPCTransport protocol.

import Foundation
import NvimRPC
import Transport

private final class SystemSSHProcessTransport: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var hasStarted = false

    let received: AsyncThrowingStream<Data, Error>

    init(config: SSHConnectionConfig) {
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.received = AsyncThrowingStream<Data, Error> { continuation in
            captured = continuation
        }
        self.continuation = captured

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.buildArguments(config: config)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var env = ProcessInfo.processInfo.environment
        if (env["TERM"] ?? "").isEmpty {
            env["TERM"] = "xterm-256color"
        }
        process.environment = env

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                self.finishStream()
            } else {
                self.continuation?.yield(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                NSLog("[ssh stderr] %@", text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.hasStarted = false

            if process.terminationStatus == 0 {
                self.finishStream()
            } else {
                self.continuation?.finish(
                    throwing: SSHTransportError.connectionFailed(
                        "ssh exited with status \(process.terminationStatus)"
                    )
                )
                self.continuation = nil
            }
        }
    }

    func start() async throws {
        guard !hasStarted else { return }
        try process.run()
        hasStarted = true
    }

    func send(_ data: Data) async throws {
        guard hasStarted, process.isRunning else {
            throw SSHTransportError.notConnected
        }

        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw SSHTransportError.connectionFailed(error.localizedDescription)
        }
    }

    func stop() async {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        if process.isRunning {
            try? stdinPipe.fileHandleForWriting.close()
            process.terminate()
        }

        hasStarted = false
        finishStream()
    }

    private func finishStream() {
        continuation?.finish()
        continuation = nil
    }

    private static func buildArguments(config: SSHConnectionConfig) -> [String] {
        var arguments: [String] = [
            "-T",
            "-p", String(config.port),
            "-o", "BatchMode=yes",
            "-o", "RequestTTY=no",
        ]

        switch config.authentication {
        case .privateKey(let path, _):
            arguments.append(contentsOf: ["-i", (path as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"])
        case .agent, .password:
            break
        }

        arguments.append("\(config.username)@\(config.host)")
        arguments.append(config.remoteCommand)
        return arguments
    }
}

/// An RPCTransport that connects to a remote Neovim over SSH.
actor SSHRPCTransport: RPCTransport {
    private let startImpl: @Sendable () async throws -> Void
    private let sendImpl: @Sendable (Data) async throws -> Void
    private let stopImpl: @Sendable () async -> Void

    nonisolated let received: AsyncThrowingStream<Data, Error>

    init(config: SSHConnectionConfig) {
        switch config.authentication {
        case .password:
            let transport = SSHTransport(config: config)
            self.received = transport.received
            self.startImpl = { try await transport.start() }
            self.sendImpl = { data in try await transport.send(data) }
            self.stopImpl = { await transport.stop() }
        case .agent, .privateKey:
            let transport = SystemSSHProcessTransport(config: config)
            self.received = transport.received
            self.startImpl = { try await transport.start() }
            self.sendImpl = { data in try await transport.send(data) }
            self.stopImpl = { await transport.stop() }
        }
    }

    func start() async throws {
        try await startImpl()
    }

    func send(_ data: Data) async throws {
        try await sendImpl(data)
    }

    func stop() async {
        await stopImpl()
    }

    /// The current SSH connection state, for UI observation.
    nonisolated var connectionState: SSHConnectionState {
        .disconnected
    }
}
