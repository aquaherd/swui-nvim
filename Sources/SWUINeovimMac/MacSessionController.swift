// MacSessionController.swift
// SWUINeovimMac
//
// Thin @Observable wrapper around NvimSession from the SWUINeovim library.
// Manages transport lifecycle and provides convenience methods for the
// SPM executable UI.

import Foundation
import Observation
import SWUINeovim
import Transport

@MainActor
@Observable
final class MacSessionController {
    // MARK: - Public State

    /// The underlying NvimSession from the library.
    let session = NvimSession()

    /// Incremented on each Neovim "flush" event. Observing this property
    /// in SwiftUI views triggers re-renders at the right time.
    private(set) var flushRevision: Int = 0

    var nvimPath: String = "/opt/local/bin/nvim"
    var preferredBackground: String = "dark"
    var onRemoteExit: (() -> Void)?

    /// Current SSH connection state, if connected via SSH.
    private(set) var sshConnectionState: SSHConnectionState?

    /// Whether we're currently connected via SSH.
    var isSSH: Bool { sshConnectionState != nil }

    // MARK: - Private State

    private var connectTask: Task<Void, Never>?
    private var userInitiatedDisconnect = false
    private var lastAppliedResize: (cols: Int, rows: Int)?
    private var desiredResize: (cols: Int, rows: Int)?
    private var lastSSHConfig: SSHConnectionConfig?
    private var reconnectAttempts: Int = 0
    private static let maxReconnectAttempts = 5

    // MARK: - Init

    init() {
        session.onFlush = { [weak self] in
            self?.flushRevision &+= 1
        }
    }

    // MARK: - Computed Convenience

    /// The primary grid (grid ID 1).
    var grid: Grid? { session.grids[1] }

    var isInsertMode: Bool {
        let shape = session.currentMode.cursorShape
        return shape == .vertical
    }

    // MARK: - Grid Snapshot

    /// A lightweight snapshot of the current grid state for the NSView renderer.
    struct GridSnapshot: Sendable {
        var rows: Int
        var cols: Int
        var cells: [[GridCell]]
        var cursorRow: Int
        var cursorCol: Int
        var useIBeamCursor: Bool
        var defaultForeground: UInt32
        var defaultBackground: UInt32
        var highlights: [Int: RawHighlightAttrs]
    }

    var gridSnapshot: GridSnapshot {
        let g = grid
        let r = g?.rows ?? 24
        let c = g?.cols ?? 80
        let cells = g?.cells ?? Array(
            repeating: Array(repeating: GridCell(), count: c),
            count: r
        )

        return GridSnapshot(
            rows: r,
            cols: c,
            cells: cells,
            cursorRow: session.cursor.row,
            cursorCol: session.cursor.col,
            useIBeamCursor: isInsertMode,
            defaultForeground: session.defaultColors.foreground,
            defaultBackground: session.defaultColors.background,
            highlights: session.highlightTable
        )
    }

    // MARK: - Connection Lifecycle

    func connectLocal() {
        guard session.state == .disconnected else { return }
        userInitiatedDisconnect = false
        sshConnectionState = nil

        let path = nvimPath
        connectTask = Task {
            let transport = LocalProcessRPCTransport(nvimPath: path)
            do {
                try await transport.start()

                try await session.start(
                    send: { data in try await transport.send(data) },
                    receive: transport.received,
                    stop: { await transport.stop() }
                )

                // Apply initial preferences
                try? await session.command("set background=\(preferredBackground)")
                if let resize = desiredResize {
                    try? await session.tryResize(width: resize.cols, height: resize.rows)
                    lastAppliedResize = resize
                }

            } catch {
                // Session handles its own state transitions
            }
        }
    }

    /// Connect to a remote Neovim instance over SSH.
    func connectSSH(config: SSHConnectionConfig) {
        guard session.state == .disconnected else { return }
        userInitiatedDisconnect = false
        sshConnectionState = .connecting

        connectTask = Task {
            let transport = SSHRPCTransport(config: config)
            do {
                sshConnectionState = .connecting
                try await transport.start()
                sshConnectionState = .connected

                try await session.start(
                    send: { data in try await transport.send(data) },
                    receive: transport.received,
                    stop: {
                        await transport.stop()
                    }
                )

                // Apply initial preferences
                try? await session.command("set background=\(preferredBackground)")
                if let resize = desiredResize {
                    try? await session.tryResize(width: resize.cols, height: resize.rows)
                    lastAppliedResize = resize
                }

            } catch {
                sshConnectionState = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        connectTask?.cancel()
        connectTask = nil
        lastAppliedResize = nil
        sshConnectionState = nil

        Task {
            await session.stop()
        }
    }

    // MARK: - Input

    func sendInput(_ keys: String) {
        Task {
            try? await session.input(keys)
        }
    }

    func sendMouse(
        button: String,
        action: String,
        modifiers: String,
        row: Int,
        col: Int
    ) {
        Task {
            try? await session.inputMouse(
                button: button,
                action: action,
                row: max(0, row),
                col: max(0, col),
                modifier: modifiers
            )
        }
    }

    // MARK: - Resize

    func requestResize(cols: Int, rows: Int) {
        let c = max(1, cols)
        let r = max(1, rows)
        desiredResize = (c, r)

        guard session.state == .attached else { return }

        if let applied = lastAppliedResize,
           applied.cols == c,
           applied.rows == r {
            return
        }

        Task {
            try? await session.tryResize(width: c, height: r)
            lastAppliedResize = (c, r)
        }
    }

    // MARK: - Appearance

    func updateAppearance(isDark: Bool) {
        preferredBackground = isDark ? "dark" : "light"
        guard session.state == .attached else { return }

        Task {
            try? await session.command("set background=\(preferredBackground)")
        }
    }

    // MARK: - Commands

    func save() {
        Task {
            try? await session.command("write")
        }
    }

    func save(as path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\")
        Task {
            try? await session.command("write \(escaped)")
        }
    }
}
