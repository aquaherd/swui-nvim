import Foundation
import Observation
import MsgPack
import NvimRPC

@MainActor
@Observable
final class Phase1SessionController {
    struct GridCellState: Equatable, Sendable {
        var text: String = " "
        var highlightID: Int = 0
    }

    struct HighlightStyle: Equatable, Sendable {
        var foreground: UInt32?
        var background: UInt32?
        var reverse: Bool = false
    }

    struct GridSnapshot: Sendable {
        var rows: Int
        var cols: Int
        var cells: [[GridCellState]]
        var cursorRow: Int
        var cursorCol: Int
        var useIBeamCursor: Bool
        var defaultForeground: UInt32
        var defaultBackground: UInt32
        var highlights: [Int: HighlightStyle]
    }

    enum ConnectionState: String {
        case disconnected
        case connecting
        case attached
        case failed
    }

    var state: ConnectionState = .disconnected
    var statusMessage: String = "Idle"
    var nvimPath: String = "/opt/local/bin/nvim"
    var redrawEventCount: Int = 0
    var gridRows: Int = 36
    var gridCols: Int = 120
    var gridCells: [[GridCellState]] = []
    var cursorRow: Int = 0
    var cursorCol: Int = 0
    var defaultForeground: UInt32 = 0xFFFFFF
    var defaultBackground: UInt32 = 0x000000
    var highlightTable: [Int: HighlightStyle] = [:]
    var currentMode: String = "n"
    var preferredBackground: String = "dark"
    var onRemoteExit: (() -> Void)?

    private var channel: RPCChannel?
    private var notificationTask: Task<Void, Never>?
    private var desiredResize: (cols: Int, rows: Int)?
    private var lastAppliedResize: (cols: Int, rows: Int)?
    private var userInitiatedDisconnect = false

    // Pending (non-observable) grid state — mutated during redraw batch,
    // then copied to observable properties on "flush" to prevent mid-batch renders.
    private var pendingRows: Int = 36
    private var pendingCols: Int = 120
    private var pendingCells: [[GridCellState]] = []
    private var pendingCursorRow: Int = 0
    private var pendingCursorCol: Int = 0
    private var pendingDefaultFG: UInt32 = 0xFFFFFF
    private var pendingDefaultBG: UInt32 = 0x000000
    private var pendingHighlights: [Int: HighlightStyle] = [:]
    private var pendingMode: String = "n"

    init() {
        gridCells = Self.makeBlankGrid(rows: gridRows, cols: gridCols)
        pendingCells = gridCells
    }

    var gridSnapshot: GridSnapshot {
        GridSnapshot(
            rows: gridRows,
            cols: gridCols,
            cells: gridCells,
            cursorRow: cursorRow,
            cursorCol: cursorCol,
            useIBeamCursor: isInsertMode,
            defaultForeground: defaultForeground,
            defaultBackground: defaultBackground,
            highlights: highlightTable
        )
    }

    private var isInsertMode: Bool {
        let normalized = currentMode.lowercased()
        return normalized == "i" ||
            normalized.hasPrefix("i") ||
            normalized.contains("insert") ||
            normalized == "ic" ||
            normalized == "ix"
    }

    func connectLocal() {
        guard state == .disconnected else { return }
        userInitiatedDisconnect = false

        state = .connecting
        statusMessage = "Starting local nvim --embed…"

        let transport = LocalProcessRPCTransport(nvimPath: nvimPath)
        let channel = RPCChannel(transport: transport)
        self.channel = channel

        Task {
            do {
                try await channel.start()
                try await attachUI(channel: channel)
                try? await applyDesiredResize(channel: channel)
                try? await applyPreferredBackground(channel: channel)
                startNotificationLoop(channel: channel)
                await MainActor.run {
                    self.state = .attached
                    self.statusMessage = "Attached via local transport"
                    self.redrawEventCount = 0
                }
            } catch {
                await MainActor.run {
                    self.state = .failed
                    self.statusMessage = "Connect failed: \(error)"
                }
            }
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        notificationTask?.cancel()
        notificationTask = nil

        let channel = self.channel
        self.channel = nil

        Task {
            await channel?.stop()
            await MainActor.run {
                self.state = .disconnected
                self.statusMessage = "Disconnected"
                self.resetGrid()
                self.lastAppliedResize = nil
            }
        }
    }

    func sendInput(_ keys: String) {
        guard let channel else { return }
        Task {
            _ = try? await channel.request(method: "nvim_input", params: [.string(keys)])
        }
    }

    func sendMouse(
        button: String,
        action: String,
        modifiers: String,
        row: Int,
        col: Int
    ) {
        guard let channel else { return }
        Task {
            _ = try? await channel.request(
                method: "nvim_input_mouse",
                params: [
                    .string(button),
                    .string(action),
                    .string(modifiers),
                    .int(0),
                    .int(Int64(max(0, row))),
                    .int(Int64(max(0, col))),
                ]
            )
        }
    }

    func requestResize(cols: Int, rows: Int) {
        let normalizedCols = max(1, cols)
        let normalizedRows = max(1, rows)
        desiredResize = (normalizedCols, normalizedRows)

        guard let channel else {
            return
        }

        Task {
            try? await applyDesiredResize(channel: channel)
        }
    }

    func updateAppearance(isDark: Bool) {
        let value = isDark ? "dark" : "light"
        preferredBackground = value

        guard state == .attached, let channel else {
            return
        }

        Task {
            try? await applyPreferredBackground(channel: channel)
        }
    }

    func save() {
        runCommand("write", success: "Saved current buffer")
    }

    func save(as path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Save As path is empty"
            return
        }

        let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\")
        runCommand("write \(escaped)", success: "Saved to \(trimmed)")
    }

    private func runCommand(_ command: String, success: String) {
        guard let channel else {
            statusMessage = "Not connected"
            return
        }

        Task {
            do {
                _ = try await channel.request(method: "nvim_command", params: [.string(command)])
                await MainActor.run {
                    self.statusMessage = success
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Command failed: \(error)"
                }
            }
        }
    }

    private func attachUI(channel: RPCChannel) async throws {
        let options: MsgPackValue = .map([
            .string("ext_linegrid"): .bool(true),
            .string("ext_multigrid"): .bool(false),
            .string("ext_popupmenu"): .bool(false),
            .string("ext_cmdline"): .bool(false),
            .string("ext_messages"): .bool(false),
            .string("rgb"): .bool(true),
        ])

        _ = try await channel.request(
            method: "nvim_ui_attach",
            params: [
                .int(120),
                .int(36),
                options,
            ]
        )
    }

    private func applyPreferredBackground(channel: RPCChannel) async throws {
        _ = try await channel.request(
            method: "nvim_command",
            params: [.string("set background=\(preferredBackground)")]
        )
    }

    private func applyDesiredResize(channel: RPCChannel) async throws {
        guard let desiredResize else { return }
        if let applied = lastAppliedResize,
           applied.cols == desiredResize.cols,
           applied.rows == desiredResize.rows {
            return
        }

        _ = try await channel.request(
            method: "nvim_ui_try_resize",
            params: [
                .int(Int64(desiredResize.cols)),
                .int(Int64(desiredResize.rows)),
            ]
        )
        lastAppliedResize = desiredResize
    }

    private func startNotificationLoop(channel: RPCChannel) {
        notificationTask = Task {
            let stream = await channel.notifications
            for await message in stream {
                guard case .notification(let method, _) = message else { continue }
                if method == "redraw" {
                    guard case .notification(_, let params) = message else { continue }
                    await MainActor.run {
                        self.redrawEventCount &+= 1
                        self.processRedrawBatch(params)
                    }
                }
            }

            await MainActor.run {
                guard !self.userInitiatedDisconnect else {
                    self.userInitiatedDisconnect = false
                    return
                }

                if self.state == .attached || self.state == .connecting {
                    self.state = .disconnected
                    self.statusMessage = "Neovim exited"
                    self.resetGrid()
                    self.lastAppliedResize = nil
                    self.channel = nil
                    self.onRemoteExit?()
                }
            }
        }
    }

    private func resetGrid() {
        pendingRows = 36
        pendingCols = 120
        pendingCells = Self.makeBlankGrid(rows: pendingRows, cols: pendingCols)
        pendingCursorRow = 0
        pendingCursorCol = 0
        pendingHighlights.removeAll()
        pendingMode = "n"
        // Also reset observable state immediately for a clean slate
        gridRows = pendingRows
        gridCols = pendingCols
        gridCells = pendingCells
        cursorRow = 0
        cursorCol = 0
        highlightTable.removeAll()
        currentMode = "n"
    }

    private static func makeBlankGrid(rows: Int, cols: Int) -> [[GridCellState]] {
        let row = [GridCellState](repeating: GridCellState(), count: max(1, cols))
        return [[GridCellState]](repeating: row, count: max(1, rows))
    }

    // MARK: - Redraw Parsing

    private func processRedrawBatch(_ events: [MsgPackValue]) {
        for event in events {
            guard case .array(let parts) = event, !parts.isEmpty else { continue }
            guard let eventName = parts[0].stringValue else { continue }

            for argIndex in 1..<parts.count {
                guard case .array(let args) = parts[argIndex] else { continue }
                processRedrawEvent(name: eventName, args: args)
            }
        }
    }

    private func processRedrawEvent(name: String, args: [MsgPackValue]) {
        switch name {
        case "grid_resize":
            handleGridResize(args)
        case "grid_line":
            handleGridLine(args)
        case "grid_cursor_goto":
            handleGridCursorGoto(args)
        case "grid_clear":
            handleGridClear(args)
        case "grid_scroll":
            handleGridScroll(args)
        case "hl_attr_define":
            handleHlAttrDefine(args)
        case "default_colors_set":
            handleDefaultColorsSet(args)
        case "mode_change":
            handleModeChange(args)
        case "flush":
            handleFlush()
        default:
            break
        }
    }

    /// Commit pending grid state to observable properties, triggering a single
    /// SwiftUI view update per redraw batch instead of per-event.
    private func handleFlush() {
        gridRows = pendingRows
        gridCols = pendingCols
        gridCells = pendingCells
        cursorRow = pendingCursorRow
        cursorCol = pendingCursorCol
        defaultForeground = pendingDefaultFG
        defaultBackground = pendingDefaultBG
        highlightTable = pendingHighlights
        currentMode = pendingMode
    }

    private func handleGridResize(_ args: [MsgPackValue]) {
        guard args.count >= 3,
              let cols = args[1].intValue.flatMap({ Int(exactly: $0) }),
              let rows = args[2].intValue.flatMap({ Int(exactly: $0) })
        else { return }

        pendingRows = max(1, rows)
        pendingCols = max(1, cols)
        pendingCells = Self.makeBlankGrid(rows: pendingRows, cols: pendingCols)
    }

    private func handleGridLine(_ args: [MsgPackValue]) {
        guard args.count >= 4,
              let row = args[1].intValue.flatMap({ Int(exactly: $0) }),
              let colStart = args[2].intValue.flatMap({ Int(exactly: $0) }),
              let cellData = args[3].arrayValue,
              row >= 0, row < pendingRows
        else { return }

        var col = max(0, colStart)
        var currentHL = 0

        for cell in cellData {
            guard case .array(let spec) = cell, !spec.isEmpty else { continue }
            guard let text = spec[0].stringValue else { continue }

            if spec.count >= 2, let hl = spec[1].intValue.flatMap({ Int(exactly: $0) }) {
                currentHL = hl
            }

            let repeatCount: Int
            if spec.count >= 3, let rep = spec[2].intValue.flatMap({ Int(exactly: $0) }) {
                repeatCount = max(1, rep)
            } else {
                repeatCount = 1
            }

            for _ in 0..<repeatCount {
                guard col < pendingCols else { break }
                pendingCells[row][col] = GridCellState(text: text, highlightID: currentHL)
                col += 1
            }
        }
    }

    private func handleGridCursorGoto(_ args: [MsgPackValue]) {
        guard args.count >= 3,
              let row = args[1].intValue.flatMap({ Int(exactly: $0) }),
              let col = args[2].intValue.flatMap({ Int(exactly: $0) })
        else { return }

        pendingCursorRow = max(0, min(pendingRows - 1, row))
        pendingCursorCol = max(0, min(pendingCols - 1, col))
    }

    private func handleGridClear(_ args: [MsgPackValue]) {
        _ = args
        pendingCells = Self.makeBlankGrid(rows: pendingRows, cols: pendingCols)
    }

    private func handleGridScroll(_ args: [MsgPackValue]) {
        guard args.count >= 6,
              let top = args[1].intValue.flatMap({ Int(exactly: $0) }),
              let bottom = args[2].intValue.flatMap({ Int(exactly: $0) }),
              let left = args[3].intValue.flatMap({ Int(exactly: $0) }),
              let right = args[4].intValue.flatMap({ Int(exactly: $0) }),
              let rowCount = args[5].intValue.flatMap({ Int(exactly: $0) })
        else { return }

        let topBound = max(0, min(pendingRows, top))
        let bottomBound = max(topBound, min(pendingRows, bottom))
        let leftBound = max(0, min(pendingCols, left))
        let rightBound = max(leftBound, min(pendingCols, right))

        guard rowCount != 0,
              bottomBound > topBound,
              rightBound > leftBound
        else { return }

        if rowCount > 0 {
            for row in topBound..<(bottomBound - rowCount) {
                for col in leftBound..<rightBound {
                    pendingCells[row][col] = pendingCells[row + rowCount][col]
                }
            }
            for row in max(topBound, bottomBound - rowCount)..<bottomBound {
                for col in leftBound..<rightBound {
                    pendingCells[row][col] = GridCellState()
                }
            }
        } else {
            let amount = -rowCount
            guard amount < (bottomBound - topBound) else { return }
            for row in stride(from: bottomBound - 1, through: topBound + amount, by: -1) {
                for col in leftBound..<rightBound {
                    pendingCells[row][col] = pendingCells[row - amount][col]
                }
            }
            for row in topBound..<(topBound + amount) {
                for col in leftBound..<rightBound {
                    pendingCells[row][col] = GridCellState()
                }
            }
        }
    }

    private func handleHlAttrDefine(_ args: [MsgPackValue]) {
        guard args.count >= 2,
              let hlID = args[0].intValue.flatMap({ Int(exactly: $0) })
        else { return }

        guard case .map(let attrMap) = args[1] else { return }
        var style = HighlightStyle()

        for (key, value) in attrMap {
            guard let keyString = key.stringValue else { continue }
            switch keyString {
            case "foreground":
                style.foreground = value.uintValue.flatMap { UInt32(exactly: $0) }
            case "background":
                style.background = value.uintValue.flatMap { UInt32(exactly: $0) }
            case "reverse":
                style.reverse = value.boolValue ?? false
            default:
                break
            }
        }

        pendingHighlights[hlID] = style
    }

    private func handleDefaultColorsSet(_ args: [MsgPackValue]) {
        guard args.count >= 2 else { return }
        if let fg = args[0].uintValue.flatMap({ UInt32(exactly: $0) }) {
            pendingDefaultFG = fg
        }
        if let bg = args[1].uintValue.flatMap({ UInt32(exactly: $0) }) {
            pendingDefaultBG = bg
        }
    }

    private func handleModeChange(_ args: [MsgPackValue]) {
        guard let mode = args.first?.stringValue, !mode.isEmpty else { return }
        pendingMode = mode
    }
}
