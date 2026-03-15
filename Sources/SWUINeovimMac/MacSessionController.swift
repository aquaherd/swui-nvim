// MacSessionController.swift
// SWUINeovimMac
//
// Thin @Observable wrapper around NvimSession from the SWUINeovim library.
// Manages transport lifecycle and provides convenience methods for the
// SPM executable UI.

import Foundation
import Observation
import Combine
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

    /// Active SSH configuration for the current remote session, if any.
    private(set) var currentSSHConfig: SSHConnectionConfig?

    /// Whether we're currently connected via SSH.
    var isSSH: Bool { sshConnectionState != nil }

    // MARK: - Private State

    private var connectTask: Task<Void, Never>?
    private var userInitiatedDisconnect = false
    private var lastAppliedResize: (cols: Int, rows: Int)?
    private var desiredResize: (cols: Int, rows: Int)?
    private var resizeTask: Task<Void, Never>?
    private var lastSSHConfig: SSHConnectionConfig?
    private var reconnectAttempts: Int = 0
    private static let maxReconnectAttempts = 5
#if DEBUG
    private static let resizeDebugEnabled = ProcessInfo.processInfo.environment["SWUINVIM_DEBUG_RESIZE"] == "1"
    private static let mouseDebugEnabled = ProcessInfo.processInfo.environment["SWUINVIM_DEBUG_MOUSE"] == "1"
#else
    private static let resizeDebugEnabled = false
    private static let mouseDebugEnabled = false
#endif
    private var sessionStateCancellable: AnyCancellable?
    private var hadLiveSession = false

    private static func resizeDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        guard resizeDebugEnabled else { return }
        print("[ResizeDebug][Controller] \(message())")
#endif
    }

    private static func mouseDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        guard mouseDebugEnabled else { return }
        print("[MouseDebug][Controller] \(message())")
#endif
    }

    // MARK: - Init

    init() {
        session.usesMultigrid = true
        sessionStateCancellable = session.$state.sink { [weak self] newState in
            guard let self else { return }

            switch newState {
            case .connecting, .attached, .detaching:
                self.hadLiveSession = true
            case .disconnected:
                if self.hadLiveSession && !self.userInitiatedDisconnect {
                    self.onRemoteExit?()
                }
                self.hadLiveSession = false
            case .error:
                break
            }
        }
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
        struct Layer: Sendable, Identifiable {
            var id: Int
            var rows: Int
            var cols: Int
            var cells: [[GridCell]]
            var originRow: Double
            var originCol: Double
            var isFloating: Bool
            var zIndex: Int
            var mouseEnabled: Bool
        }

        var rows: Int
        var cols: Int
        var cells: [[GridCell]]
        var cursorRow: Int
        var cursorCol: Int
        var cursorGridID: Int
        var useIBeamCursor: Bool
        var layers: [Layer]
        var defaultForeground: UInt32
        var defaultBackground: UInt32
        var highlights: [Int: RawHighlightAttrs]

        var drawBaseCursor: Bool {
            layers.isEmpty
        }

        var gridOrigins: [Int: CGPoint] {
            Dictionary(uniqueKeysWithValues: layers.map {
                ($0.id, CGPoint(x: $0.originCol, y: $0.originRow))
            })
        }
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
            cursorGridID: session.cursor.gridID,
            useIBeamCursor: isInsertMode,
            layers: windowLayers(),
            defaultForeground: session.defaultColors.foreground,
            defaultBackground: session.defaultColors.background,
            highlights: session.highlightTable
        )
    }

    private func windowLayers() -> [GridSnapshot.Layer] {
        let positions = session.windowPositions
        let grids = session.grids

        guard !positions.isEmpty else { return [] }

        var cache: [Int: (row: Double, col: Double)] = [1: (0, 0)]

        func resolveOrigin(for gridID: Int, visited: inout Set<Int>) -> (row: Double, col: Double)? {
            if let cached = cache[gridID] {
                return cached
            }
            guard !visited.contains(gridID) else { return nil }
            visited.insert(gridID)
            defer { visited.remove(gridID) }

            guard let position = positions[gridID] else {
                if gridID == 1 {
                    return (0, 0)
                }
                return nil
            }

            let resolved: (row: Double, col: Double)
            if position.isFloating {
                if let screenRow = position.screenRow, let screenCol = position.screenCol {
                    resolved = (Double(screenRow), Double(screenCol))
                } else {
                    let anchorGridID = position.anchorGridID ?? 1
                    let anchorOrigin = resolveOrigin(for: anchorGridID, visited: &visited) ?? (0, 0)
                    let anchorRow = anchorOrigin.row + (position.anchorRow ?? 0)
                    let anchorCol = anchorOrigin.col + (position.anchorCol ?? 0)
                    let grid = grids[gridID]
                    let height = Double(grid?.rows ?? position.height)
                    let width = Double(grid?.cols ?? position.width)

                    var originRow = anchorRow
                    var originCol = anchorCol

                    switch position.anchor {
                    case .northWest:
                        break
                    case .northEast:
                        originCol -= width
                    case .southWest:
                        originRow -= height
                    case .southEast:
                        originRow -= height
                        originCol -= width
                    }

                    resolved = (originRow, originCol)
                }
            } else {
                resolved = (Double(position.startRow), Double(position.startCol))
            }

            cache[gridID] = resolved
            return resolved
        }

        var layers: [GridSnapshot.Layer] = []
        for (gridID, position) in positions {
            guard let grid = grids[gridID] else { continue }
            var visited: Set<Int> = []
            let origin = resolveOrigin(for: gridID, visited: &visited) ?? (0, 0)
            layers.append(
                GridSnapshot.Layer(
                    id: gridID,
                    rows: grid.rows,
                    cols: grid.cols,
                    cells: grid.cells,
                    originRow: origin.row,
                    originCol: origin.col,
                    isFloating: position.isFloating,
                    zIndex: position.zIndex,
                    mouseEnabled: position.mouseEnabled
                )
            )
        }

        return layers.sorted {
            if $0.isFloating != $1.isFloating {
                return !$0.isFloating
            }
            if $0.zIndex != $1.zIndex {
                return $0.zIndex < $1.zIndex
            }
            if $0.originRow != $1.originRow {
                return $0.originRow < $1.originRow
            }
            if $0.originCol != $1.originCol {
                return $0.originCol < $1.originCol
            }
            return $0.id < $1.id
        }
    }

    // MARK: - Connection Lifecycle

    func connectLocal() {
        connectTask?.cancel()
        sshConnectionState = nil
        currentSSHConfig = nil

        let path = nvimPath
        connectTask = Task {
            if session.state != .disconnected {
                userInitiatedDisconnect = true
                await session.stop()
            }

            userInitiatedDisconnect = false
            hadLiveSession = false

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
        connectTask?.cancel()
        sshConnectionState = .connecting
        currentSSHConfig = config

        connectTask = Task.detached(priority: .userInitiated) { [weak self, config] in
            guard let self else { return }

            if await self.session.state != .disconnected {
                await MainActor.run {
                    self.userInitiatedDisconnect = true
                }
                await self.session.stop()
            }

            await MainActor.run {
                self.userInitiatedDisconnect = false
                self.hadLiveSession = false
                    self.currentSSHConfig = config
                self.sshConnectionState = .connecting
            }

            let transport = SSHRPCTransport(config: config)
            do {
                try await transport.start()

                await MainActor.run {
                    self.sshConnectionState = .connected
                }

                try await self.session.start(
                    send: { data in try await transport.send(data) },
                    receive: transport.received,
                    stop: {
                        await transport.stop()
                    }
                )

                let preferredBackground = await MainActor.run { self.preferredBackground }
                let desiredResize = await MainActor.run { self.desiredResize }

                try? await self.session.command("set background=\(preferredBackground)")
                if let resize = desiredResize {
                    try? await self.session.tryResize(width: resize.cols, height: resize.rows)
                    await MainActor.run {
                        self.lastAppliedResize = resize
                    }
                }

            } catch {
                let message = Self.describeSSHConnectError(error)
                await MainActor.run {
                    self.currentSSHConfig = config
                    self.sshConnectionState = .failed(message)
                }
            }
        }
    }

    nonisolated private static func describeSSHConnectError(_ error: Error) -> String {
        if let sshError = error as? SSHTransportError,
           let description = sshError.errorDescription {
            return description
        }

        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("channel error 9") {
            return "SSH channel closed unexpectedly (NIO error 9). Check host, credentials, and remote command."
        }
        return message
    }

    func disconnect() {
        userInitiatedDisconnect = true
        hadLiveSession = false
        connectTask?.cancel()
        connectTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        lastAppliedResize = nil
        desiredResize = nil
        sshConnectionState = nil
        currentSSHConfig = nil

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
        col: Int,
        gridID: Int = 0
    ) {
        Self.mouseDebugLog("action=\(button):\(action) grid=\(gridID) row=\(row) col=\(col) mods=\(modifiers)")
        Task {
            try? await session.inputMouse(
                button: button,
                action: action,
                row: max(0, row),
                col: max(0, col),
                gridID: gridID,
                modifier: modifiers
            )
        }
    }

    // MARK: - Resize

    func requestResize(cols: Int, rows: Int) {
        let c = max(1, cols)
        let r = max(1, rows)
        desiredResize = (c, r)

        let applied = lastAppliedResize.map { "\($0.cols)x\($0.rows)" } ?? "nil"
        Self.resizeDebugLog("requested=\(c)x\(r) applied=\(applied) state=\(session.state)")

        guard session.state == .attached else { return }

        if let applied = lastAppliedResize,
           applied.cols == c,
           applied.rows == r,
           resizeTask == nil {
            return
        }

        scheduleResizeApplication()
    }

    private func scheduleResizeApplication() {
        guard resizeTask == nil else { return }

        resizeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.resizeTask = nil
                if self.session.state == .attached,
                   let desired = self.desiredResize,
                   self.lastAppliedResize.map({ $0 == desired }) != true {
                    self.scheduleResizeApplication()
                }
            }

            while self.session.state == .attached {
                guard let resize = self.desiredResize else { return }
                if let applied = self.lastAppliedResize,
                   applied == resize {
                    Self.resizeDebugLog("skip already-applied=\(resize.cols)x\(resize.rows)")
                    return
                }

                let applied = self.lastAppliedResize.map { "\($0.cols)x\($0.rows)" } ?? "nil"
                Self.resizeDebugLog("applying requested=\(resize.cols)x\(resize.rows) previous=\(applied)")

                try? await self.session.tryResize(width: resize.cols, height: resize.rows)

                if self.desiredResize.map({ $0 == resize }) == true {
                    self.lastAppliedResize = resize
                    Self.resizeDebugLog("applied=\(resize.cols)x\(resize.rows)")
                    return
                }

                if Self.resizeDebugEnabled,
                   let newest = self.desiredResize {
                    Self.resizeDebugLog("superseded old=\(resize.cols)x\(resize.rows) new=\(newest.cols)x\(newest.rows)")
                }
            }
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
