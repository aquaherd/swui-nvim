// SSHRPCTransport.swift
// SWUINeovimMac
//
// Adapts the Transport package's SSHTransport to NvimRPC's RPCTransport protocol.

import Foundation
import NvimRPC
import Transport

/// An RPCTransport that connects to a remote Neovim over SSH.
actor SSHRPCTransport: RPCTransport {
    private let sshTransport: SSHTransport

    nonisolated let received: AsyncThrowingStream<Data, Error>

    init(config: SSHConnectionConfig) {
        let transport = SSHTransport(config: config)
        self.sshTransport = transport
        self.received = transport.received
    }

    func start() async throws {
        try await sshTransport.start()
    }

    func send(_ data: Data) async throws {
        try await sshTransport.send(data)
    }

    func stop() async {
        await sshTransport.stop()
    }

    /// The current SSH connection state, for UI observation.
    nonisolated var connectionState: SSHConnectionState {
        sshTransport.connectionState
    }
}
