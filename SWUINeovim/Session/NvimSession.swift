// NvimSession.swift
// SWUINeovim
//
// Actor managing a single Neovim RPC session.
// Owns the transport, RPC channel, UI state machine, grid contents,
// highlight table, and cursor state. Publishes observable state for
// SwiftUI consumption.

import Foundation
import Combine
import MsgPack

// MARK: - Session State

/// The lifecycle state of a Neovim session.
public enum NvimSessionState: Sendable, Equatable {
    case disconnected
    case connecting
    case attached
    case detaching
    case error(String)

    public static func == (lhs: NvimSessionState, rhs: NvimSessionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.attached, .attached),
             (.detaching, .detaching):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Raw Highlight Attributes

/// Raw highlight attributes parsed from `hl_attr_define` msgpack data.
/// Uses UInt32 color values before platform color resolution.
public struct RawHighlightAttrs: Sendable, Equatable {
    public var foreground: UInt32?
    public var background: UInt32?
    public var special: UInt32?
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var undercurl: Bool
    public var underdouble: Bool
    public var underdotted: Bool
    public var underdashed: Bool
    public var strikethrough: Bool
    public var reverse: Bool
    public var blend: Int

    public init(
        foreground: UInt32? = nil,
        background: UInt32? = nil,
        special: UInt32? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        undercurl: Bool = false,
        underdouble: Bool = false,
        underdotted: Bool = false,
        underdashed: Bool = false,
        strikethrough: Bool = false,
        reverse: Bool = false,
        blend: Int = 0
    ) {
        self.foreground = foreground
        self.background = background
        self.special = special
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.undercurl = undercurl
        self.underdouble = underdouble
        self.underdotted = underdotted
        self.underdashed = underdashed
        self.strikethrough = strikethrough
        self.reverse = reverse
        self.blend = blend
    }

    /// Parse highlight attributes from a Neovim `hl_attr_define` map.
    public static func from(msgpack value: MsgPackValue) -> RawHighlightAttrs {
        var attrs = RawHighlightAttrs()
        guard case .map(let dict) = value else { return attrs }

        for (key, val) in dict {
            guard let keyStr = key.stringValue else { continue }
            switch keyStr {
            case "foreground":
                attrs.foreground = val.uintValue.flatMap { UInt32(exactly: $0) }
            case "background":
                attrs.background = val.uintValue.flatMap { UInt32(exactly: $0) }
            case "special":
                attrs.special = val.uintValue.flatMap { UInt32(exactly: $0) }
            case "bold":
                attrs.bold = val.boolValue ?? false
            case "italic":
                attrs.italic = val.boolValue ?? false
            case "underline":
                attrs.underline = val.boolValue ?? false
            case "undercurl":
                attrs.undercurl = val.boolValue ?? false
            case "underdouble":
                attrs.underdouble = val.boolValue ?? false
            case "underdotted":
                attrs.underdotted = val.boolValue ?? false
            case "underdashed":
                attrs.underdashed = val.boolValue ?? false
            case "strikethrough":
                attrs.strikethrough = val.boolValue ?? false
            case "reverse":
                attrs.reverse = val.boolValue ?? false
            case "blend":
                attrs.blend = val.intValue.flatMap { Int(exactly: $0) } ?? 0
            default:
                break
            }
        }

        return attrs
    }
}

// NOTE: CursorState is defined in CursorRenderer.swift
// NOTE: ModeInfo and CursorShape are defined in NvimUIEvents.swift

// MARK: - Default Colors

/// Default foreground/background/special colors from `default_colors_set`.
public struct DefaultColors: Sendable, Equatable {
    public var foreground: UInt32
    public var background: UInt32
    public var special: UInt32

    public init(foreground: UInt32 = 0xFFFFFF, background: UInt32 = 0x000000, special: UInt32 = 0xFF0000) {
        self.foreground = foreground
        self.background = background
        self.special = special
    }
}

// MARK: - Popup Menu Item

/// A single item in the Neovim completion popup menu.
public struct PopupMenuItem: Sendable, Equatable, Identifiable {
    public var id: Int
    public var word: String
    public var kind: String
    public var menu: String
    public var info: String

    public init(id: Int = 0, word: String = "", kind: String = "", menu: String = "", info: String = "") {
        self.id = id
        self.word = word
        self.kind = kind
        self.menu = menu
        self.info = info
    }
}

// MARK: - Popup Menu State

/// State of the Neovim external popup menu.
public struct PopupMenuState: Sendable, Equatable {
    public var isVisible: Bool
    public var items: [PopupMenuItem]
    public var selectedIndex: Int
    public var row: Int
    public var col: Int
    public var gridID: Int

    public init(
        isVisible: Bool = false,
        items: [PopupMenuItem] = [],
        selectedIndex: Int = -1,
        row: Int = 0,
        col: Int = 0,
        gridID: Int = 1
    ) {
        self.isVisible = isVisible
        self.items = items
        self.selectedIndex = selectedIndex
        self.row = row
        self.col = col
        self.gridID = gridID
    }
}

// MARK: - Command Line State

/// State of the Neovim external command line.
public struct CmdlineState: Sendable, Equatable {
    public var isVisible: Bool
    public var content: [(highlightID: Int, text: String)]
    public var position: Int
    public var firstCharacter: String
    public var prompt: String
    public var indent: Int
    public var level: Int

    public static func == (lhs: CmdlineState, rhs: CmdlineState) -> Bool {
        lhs.isVisible == rhs.isVisible &&
        lhs.position == rhs.position &&
        lhs.firstCharacter == rhs.firstCharacter &&
        lhs.prompt == rhs.prompt &&
        lhs.indent == rhs.indent &&
        lhs.level == rhs.level &&
        lhs.content.count == rhs.content.count &&
        zip(lhs.content, rhs.content).allSatisfy { $0.highlightID == $1.highlightID && $0.text == $1.text }
    }

    public init(
        isVisible: Bool = false,
        content: [(highlightID: Int, text: String)] = [],
        position: Int = 0,
        firstCharacter: String = "",
        prompt: String = "",
        indent: Int = 0,
        level: Int = 0
    ) {
        self.isVisible = isVisible
        self.content = content
        self.position = position
        self.firstCharacter = firstCharacter
        self.prompt = prompt
        self.indent = indent
        self.level = level
    }

    /// Concatenated plain text of the command line content.
    public var text: String {
        content.map(\.text).joined()
    }
}

// MARK: - Message Entry

/// A message entry from `msg_show`.
public struct MessageEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var kind: String
    public var content: [(highlightID: Int, text: String)]
    public var replaceLast: Bool

    public static func == (lhs: MessageEntry, rhs: MessageEntry) -> Bool {
        lhs.id == rhs.id &&
        lhs.kind == rhs.kind &&
        lhs.replaceLast == rhs.replaceLast &&
        lhs.content.count == rhs.content.count &&
        zip(lhs.content, rhs.content).allSatisfy { $0.highlightID == $1.highlightID && $0.text == $1.text }
    }

    public init(id: UUID = UUID(), kind: String = "", content: [(highlightID: Int, text: String)] = [], replaceLast: Bool = false) {
        self.id = id
        self.kind = kind
        self.content = content
        self.replaceLast = replaceLast
    }

    /// Concatenated plain text of the message.
    public var text: String {
        content.map(\.text).joined()
    }
}

// MARK: - Grid

/// A 2-D grid of cells, representing one Neovim window or the global grid.
public final class Grid: @unchecked Sendable {
    public let id: Int
    public private(set) var rows: Int
    public private(set) var cols: Int
    public private(set) var cells: [[GridCell]]

    /// Set of row indices that have been modified since the last render pass.
    public var dirtyRows: Set<Int> = []

    private let lock = NSLock()

    public init(id: Int, rows: Int, cols: Int) {
        self.id = id
        self.rows = rows
        self.cols = cols
        self.cells = Array(
            repeating: Array(repeating: GridCell(), count: cols),
            count: rows
        )
    }

    /// Resize the grid, preserving existing content where possible.
    public func resize(rows newRows: Int, cols newCols: Int) {
        lock.withLock {
            var newCells = Array(
                repeating: Array(repeating: GridCell(), count: newCols),
                count: newRows
            )
            let copyRows = min(rows, newRows)
            let copyCols = min(cols, newCols)
            for r in 0..<copyRows {
                for c in 0..<copyCols {
                    newCells[r][c] = cells[r][c]
                }
            }
            cells = newCells
            rows = newRows
            cols = newCols
            dirtyRows = Set(0..<newRows)
        }
    }

    /// Clear the entire grid to empty cells.
    public func clear() {
        lock.withLock {
            for r in 0..<rows {
                for c in 0..<cols {
                    cells[r][c] = GridCell()
                }
            }
            dirtyRows = Set(0..<rows)
        }
    }

    /// Write a line of cells starting at the given row and column.
    /// This is the handler for `grid_line` events.
    ///
    /// - Parameters:
    ///   - row: The row index.
    ///   - colStart: The starting column.
    ///   - cellData: Array of cell updates from Neovim. Each element is
    ///     `[text, (hl_id, repeat)]`. The highlight ID carries forward if omitted.
    public func putLine(row: Int, colStart: Int, cellData: [MsgPackValue]) {
        lock.withLock {
            guard row >= 0 && row < rows else { return }
            var col = colStart
            var currentHL = 0

            for cell in cellData {
                guard case .array(let parts) = cell, !parts.isEmpty else { continue }

                let text = parts[0].stringValue ?? " "
                if parts.count > 1, let hlID = parts[1].intValue {
                    currentHL = Int(hlID)
                }
                let repeatCount = parts.count > 2 ? (parts[2].intValue.flatMap { Int(exactly: $0) } ?? 1) : 1

                for _ in 0..<repeatCount {
                    guard col < cols else { break }
                    cells[row][col] = GridCell(text: text, highlightID: currentHL)
                    col += 1
                }
            }

            dirtyRows.insert(row)
        }
    }

    /// Scroll a region of the grid.
    ///
    /// - Parameters:
    ///   - top: Top row of the scroll region (inclusive).
    ///   - bottom: Bottom row of the scroll region (exclusive).
    ///   - left: Left column of the scroll region (inclusive).
    ///   - right: Right column of the scroll region (exclusive).
    ///   - rowCount: Number of rows to scroll. Positive scrolls up (content moves up),
    ///     negative scrolls down.
    public func scroll(top: Int, bottom: Int, left: Int, right: Int, rowCount: Int) {
        lock.withLock {
            if rowCount > 0 {
                // Scroll up: copy rows from top+rowCount..bottom-1 to top..bottom-rowCount-1
                for r in top..<(bottom - rowCount) {
                    let srcRow = r + rowCount
                    guard srcRow < bottom else { continue }
                    for c in left..<right {
                        cells[r][c] = cells[srcRow][c]
                    }
                }
                // Clear the vacated rows at the bottom
                for r in (bottom - rowCount)..<bottom {
                    for c in left..<right {
                        cells[r][c] = GridCell()
                    }
                }
            } else if rowCount < 0 {
                // Scroll down
                let absCount = -rowCount
                for r in stride(from: bottom - 1, through: top + absCount, by: -1) {
                    let srcRow = r - absCount
                    guard srcRow >= top else { continue }
                    for c in left..<right {
                        cells[r][c] = cells[srcRow][c]
                    }
                }
                // Clear the vacated rows at the top
                for r in top..<(top + absCount) {
                    for c in left..<right {
                        cells[r][c] = GridCell()
                    }
                }
            }
            for r in top..<bottom {
                dirtyRows.insert(r)
            }
        }
    }

    /// Mark all rows as clean (called after rendering).
    public func clearDirtyRows() {
        lock.withLock {
            dirtyRows.removeAll()
        }
    }

    /// Get the current dirty rows snapshot.
    public func getDirtyRows() -> Set<Int> {
        lock.withLock { dirtyRows }
    }

    /// Get a snapshot of a specific row's cells.
    public func getRow(_ row: Int) -> [GridCell]? {
        lock.withLock {
            guard row >= 0 && row < rows else { return nil }
            return cells[row]
        }
    }
}

// MARK: - Multigrid Window Info

// NOTE: FloatAnchor is defined in NvimUIEvents.swift

/// Position information for a multigrid window.
public struct WindowPosition: Sendable, Equatable {
    public var gridID: Int
    public var startRow: Int
    public var startCol: Int
    public var width: Int
    public var height: Int

    /// For floating windows only.
    public var isFloating: Bool
    public var anchor: FloatAnchor
    public var anchorGridID: Int?
    public var anchorRow: Double?
    public var anchorCol: Double?
    public var focusable: Bool
    public var zIndex: Int

    public init(
        gridID: Int,
        startRow: Int = 0,
        startCol: Int = 0,
        width: Int = 0,
        height: Int = 0,
        isFloating: Bool = false,
        anchor: FloatAnchor = .northWest,
        anchorGridID: Int? = nil,
        anchorRow: Double? = nil,
        anchorCol: Double? = nil,
        focusable: Bool = true,
        zIndex: Int = 50
    ) {
        self.gridID = gridID
        self.startRow = startRow
        self.startCol = startCol
        self.width = width
        self.height = height
        self.isFloating = isFloating
        self.anchor = anchor
        self.anchorGridID = anchorGridID
        self.anchorRow = anchorRow
        self.anchorCol = anchorCol
        self.focusable = focusable
        self.zIndex = zIndex
    }
}

// MARK: - NvimSession Actor

/// The main session actor managing communication with a Neovim instance.
///
/// This actor:
/// - Manages the RPC transport lifecycle (start/stop).
/// - Attaches the UI with negotiated capabilities.
/// - Processes `redraw` notification batches.
/// - Maintains grid state, highlight table, cursor, mode, and overlay state.
/// - Publishes state changes for SwiftUI observation.
///
/// ## Usage
///
/// ```swift
/// let session = NvimSession()
/// try await session.start(transport: myTransport)
/// // The session processes redraw events automatically.
/// // Send keystrokes:
/// try await session.input("<C-a>")
/// // Read state:
/// let grid = await session.grids[1]
/// ```
@MainActor
public final class NvimSession: ObservableObject {
    // MARK: - Published State

    @Published public private(set) var state: NvimSessionState = .disconnected
    @Published public private(set) var grids: [Int: Grid] = [:]
    @Published public private(set) var highlightTable: [Int: RawHighlightAttrs] = [:]
    @Published public private(set) var defaultColors = DefaultColors()
    @Published public private(set) var cursor = CursorState()
    @Published public private(set) var currentMode = ModeInfo()
    @Published public private(set) var modeInfoList: [ModeInfo] = []
    @Published public private(set) var popupMenu = PopupMenuState()
    @Published public private(set) var cmdline = CmdlineState()
    @Published public private(set) var cmdlineBlock: [[(highlightID: Int, text: String)]] = []
    @Published public private(set) var messages: [MessageEntry] = []
    @Published public private(set) var messageHistory: [MessageEntry] = []
    @Published public private(set) var tooltip = TooltipState()
    @Published public private(set) var windowPositions: [Int: WindowPosition] = [:]
    @Published public private(set) var title: String = ""
    @Published public private(set) var isBusy: Bool = false

    /// Whether the UI should attach with Neovim's multigrid extension.
    ///
    /// Renderers that only draw grid 1 should disable this so regular window
    /// content is rendered onto the root grid instead of secondary grids.
    public var usesMultigrid: Bool = true

    /// The number of grid columns to request from Neovim.
    public var requestedCols: Int = 80

    /// The number of grid rows to request from Neovim.
    public var requestedRows: Int = 24

    /// A callback invoked after each `flush` event, signalling that the
    /// UI should re-render. Set by the EditorSurface.
    public var onFlush: (() -> Void)?

    // MARK: - Private

    /// Encoder/decoder for MsgPack RPC.
    private let encoder = MsgPackEncoder()
    private let decoder = MsgPackDecoder()

    /// Monotonically increasing message ID for outgoing requests.
    private var nextMsgID: UInt32 = 0

    /// In-flight RPC request continuations, keyed by msgid.
    private var pendingRequests: [UInt32: CheckedContinuation<MsgPackValue, Error>] = [:]

    /// Background task reading data from the transport.
    private var readTask: Task<Void, Never>?

    /// The active byte transport (local process or SSH).
    private var transportSend: ((Data) async throws -> Void)?
    private var transportStop: (() async -> Void)?
    private var transportDataStream: AsyncThrowingStream<Data, Error>?

    // MARK: - Init

    public init() {}

    deinit {
        readTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Start the session by connecting to a transport, attaching the UI,
    /// and beginning to process redraw events.
    ///
    /// - Parameters:
    ///   - send: A closure that sends raw bytes to the Neovim process.
    ///   - receive: An async stream yielding incoming data chunks.
    ///   - stop: A closure to tear down the transport.
    public func start(
        send: @escaping (Data) async throws -> Void,
        receive: AsyncThrowingStream<Data, Error>,
        stop: @escaping () async -> Void
    ) async throws {
        guard state == .disconnected || state != .connecting else { return }

        state = .connecting
        transportSend = send
        transportStop = stop
        transportDataStream = receive

        // Start reading incoming data
        readTask = Task { [weak self] in
            await self?.readLoop()
        }

        // Attach UI
        try await attachUI()

        state = .attached
    }

    /// Detach from Neovim and stop the transport.
    public func stop() async {
        guard state == .attached || state == .connecting else { return }
        state = .detaching

        // Try to detach gracefully
        do {
            _ = try await rpcRequest(method: "nvim_ui_detach", params: [])
        } catch {
            // Best effort — transport may already be closed
        }

        readTask?.cancel()
        readTask = nil

        // Fail any requests still pending after detach/shutdown.
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: NvimSessionError.sessionStopped)
        }

        await transportStop?()
        transportSend = nil
        transportStop = nil
        transportDataStream = nil

        state = .disconnected
    }

    // MARK: - Input

    /// Send a keystroke to Neovim.
    ///
    /// - Parameter keys: The key string in Neovim notation (e.g. `"<C-a>"`, `"<D-s>"`).
    public func input(_ keys: String) async throws {
        _ = try await rpcRequest(method: "nvim_input", params: [.string(keys)])
    }

    /// Send mouse input to Neovim.
    ///
    /// - Parameters:
    ///   - button: Mouse button name (`"left"`, `"right"`, `"middle"`, `"wheel"`).
    ///   - action: Action name (`"press"`, `"drag"`, `"release"`, `"up"`, `"down"`, `"left"`, `"right"`).
    ///   - row: Grid row.
    ///   - col: Grid column.
    ///   - gridID: The grid ID (for multigrid).
    ///   - modifier: Modifier keys string (e.g. `""`, `"C"`, `"S"`, `"A"`).
    public func inputMouse(
        button: String,
        action: String,
        row: Int,
        col: Int,
        gridID: Int = 0,
        modifier: String = ""
    ) async throws {
        _ = try await rpcRequest(method: "nvim_input_mouse", params: [
            .string(button),
            .string(action),
            .string(modifier),
            .int(Int64(gridID)),
            .int(Int64(row)),
            .int(Int64(col)),
        ])
    }

    /// Notify Neovim that the UI grid has been resized.
    ///
    /// - Parameters:
    ///   - gridID: The grid to resize (use 1 for the global grid).
    ///   - width: New width in columns.
    ///   - height: New height in rows.
    public func tryResize(gridID: Int = 1, width: Int, height: Int) async throws {
        if grids.keys.contains(where: { _ in true }) && grids.count > 1 {
            // Multigrid mode
            _ = try await rpcRequest(method: "nvim_ui_try_resize_grid", params: [
                .int(Int64(gridID)),
                .int(Int64(width)),
                .int(Int64(height)),
            ])
        } else {
            _ = try await rpcRequest(method: "nvim_ui_try_resize", params: [
                .int(Int64(width)),
                .int(Int64(height)),
            ])
        }
        requestedCols = width
        requestedRows = height
    }

    /// Execute a Neovim command.
    public func command(_ cmd: String) async throws {
        _ = try await rpcRequest(method: "nvim_command", params: [.string(cmd)])
    }

    /// Evaluate a Neovim expression and return the result.
    public func eval(_ expr: String) async throws -> MsgPackValue {
        return try await rpcRequest(method: "nvim_eval", params: [.string(expr)])
    }

    // MARK: - UI Attachment

    private func attachUI() async throws {
        let uiOptions: MsgPackValue = .map([
            .string("ext_linegrid"):  .bool(true),
            .string("ext_multigrid"): .bool(usesMultigrid),
            .string("ext_popupmenu"): .bool(true),
            .string("ext_cmdline"):   .bool(true),
            .string("ext_messages"):  .bool(true),
            .string("ext_hlstate"):   .bool(true),
            .string("rgb"):           .bool(true),
        ])

        _ = try await rpcRequest(
            method: "nvim_ui_attach",
            params: [
                .int(Int64(requestedCols)),
                .int(Int64(requestedRows)),
                uiOptions,
            ]
        )
    }

    // MARK: - RPC

    /// Send an RPC request and await the response.
    private func rpcRequest(method: String, params: [MsgPackValue]) async throws -> MsgPackValue {
        guard let send = transportSend else {
            throw NvimSessionError.notConnected
        }

        let msgid = nextMsgID
        nextMsgID &+= 1

        let message: MsgPackValue = .array([
            .int(0),
            .uint(UInt64(msgid)),
            .string(method),
            .array(params),
        ])

        let data = try encoder.encode(message)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[msgid] = continuation

            Task {
                do {
                    try await send(data)
                } catch {
                    if let cont = self.pendingRequests.removeValue(forKey: msgid) {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Send an RPC notification (fire-and-forget).
    private func rpcNotify(method: String, params: [MsgPackValue]) async throws {
        guard let send = transportSend else {
            throw NvimSessionError.notConnected
        }

        let message: MsgPackValue = .array([
            .int(2),
            .string(method),
            .array(params),
        ])

        let data = try encoder.encode(message)
        try await send(data)
    }

    /// Send a response to an incoming request from Neovim.
    private func rpcRespond(msgid: UInt32, error: MsgPackValue = .nil, result: MsgPackValue = .nil) async throws {
        guard let send = transportSend else {
            throw NvimSessionError.notConnected
        }

        let message: MsgPackValue = .array([
            .int(1),
            .uint(UInt64(msgid)),
            error,
            result,
        ])

        let data = try encoder.encode(message)
        try await send(data)
    }

    // MARK: - Read Loop

    private func readLoop() async {
        guard let stream = transportDataStream else { return }
        var buffer = [UInt8]()

        do {
            for try await chunk in stream {
                guard !Task.isCancelled else { break }

                buffer.append(contentsOf: chunk)

                // Try to consume complete MsgPack values from the buffer
                while !buffer.isEmpty {
                    let reader = BufferReader(data: buffer)
                    do {
                        let value = try reader.readValue()
                        let consumed = reader.offset
                        buffer.removeFirst(consumed)
                        await handleIncomingMessage(value)
                    } catch is BufferReader.IncompleteError {
                        break // Need more data
                    } catch {
                        // Skip corrupted byte
                        buffer.removeFirst(1)
                    }
                }
            }
        } catch {
            if !Task.isCancelled {
                state = .error("Transport read error: \(error.localizedDescription)")
            }
        }

        // Transport ended
        if state == .attached {
            state = .disconnected
        }

        // Fail pending requests
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: NvimSessionError.transportClosed)
        }
    }

    // MARK: - Message Handling

    private func handleIncomingMessage(_ value: MsgPackValue) async {
        guard case .array(let arr) = value, !arr.isEmpty else { return }
        guard let typeInt = arr[0].intValue ?? arr[0].uintValue.flatMap({ Int64(exactly: $0) }) else { return }

        switch typeInt {
        case 0:
            // Incoming request from Neovim
            guard arr.count >= 4,
                  let msgid = (arr[1].uintValue.flatMap { UInt32(exactly: $0) } ?? arr[1].intValue.flatMap { UInt32(exactly: $0) }),
                  let method = arr[2].stringValue,
                  let params = arr[3].arrayValue
            else { return }

            await handleRequest(msgid: msgid, method: method, params: params)

        case 1:
            // Response to an outgoing request
            guard arr.count >= 4,
                  let msgid = (arr[1].uintValue.flatMap { UInt32(exactly: $0) } ?? arr[1].intValue.flatMap { UInt32(exactly: $0) })
            else { return }

            let error = arr[2]
            let result = arr[3]

            if let continuation = pendingRequests.removeValue(forKey: msgid) {
                if error.isNil {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: NvimSessionError.rpcError(error))
                }
            }

        case 2:
            // Notification
            guard arr.count >= 3,
                  let method = arr[1].stringValue,
                  let params = arr[2].arrayValue
            else { return }

            await handleNotification(method: method, params: params)

        default:
            break
        }
    }

    private func handleRequest(msgid: UInt32, method: String, params: [MsgPackValue]) async {
        // Neovim may send requests for things like `nvim_error_event`.
        // Respond with nil for now.
        try? await rpcRespond(msgid: msgid, result: .nil)
    }

    private func handleNotification(method: String, params: [MsgPackValue]) async {
        switch method {
        case "redraw":
            processRedrawBatch(params)
        default:
            // Unknown notification — ignore
            break
        }
    }

    // MARK: - Redraw Processing

    private func processRedrawBatch(_ events: [MsgPackValue]) {
        for event in events {
            guard case .array(let parts) = event, !parts.isEmpty else { continue }
            guard let eventName = parts[0].stringValue else { continue }

            // Each event can have multiple "argument sets" following the name
            for argIndex in 1..<parts.count {
                guard case .array(let args) = parts[argIndex] else { continue }
                processRedrawEvent(name: eventName, args: args)
            }
        }
    }

    private func processRedrawEvent(name: String, args: [MsgPackValue]) {
        switch name {
        // --- Grid events ---
        case "grid_resize":
            handleGridResize(args)
        case "grid_line":
            handleGridLine(args)
        case "grid_scroll":
            handleGridScroll(args)
        case "grid_cursor_goto":
            handleGridCursorGoto(args)
        case "grid_clear":
            handleGridClear(args)
        case "grid_destroy":
            handleGridDestroy(args)

        // --- Highlight ---
        case "hl_attr_define":
            handleHlAttrDefine(args)
        case "default_colors_set":
            handleDefaultColorsSet(args)
        case "hl_group_set":
            break // Informational; not needed for rendering

        // --- Mode ---
        case "mode_info_set":
            handleModeInfoSet(args)
        case "mode_change":
            handleModeChange(args)

        // --- Window position (multigrid) ---
        case "win_pos":
            handleWinPos(args)
        case "win_float_pos":
            handleWinFloatPos(args)
        case "win_hide":
            handleWinHide(args)
        case "win_close":
            handleWinClose(args)

        // --- Popup menu ---
        case "popupmenu_show":
            handlePopupMenuShow(args)
        case "popupmenu_hide":
            popupMenu.isVisible = false
        case "popupmenu_select":
            handlePopupMenuSelect(args)

        // --- Command line ---
        case "cmdline_show":
            handleCmdlineShow(args)
        case "cmdline_hide":
            cmdline.isVisible = false
        case "cmdline_pos":
            handleCmdlinePos(args)
        case "cmdline_special_char":
            handleCmdlineSpecialChar(args)
        case "cmdline_block_show":
            handleCmdlineBlockShow(args)
        case "cmdline_block_append":
            handleCmdlineBlockAppend(args)
        case "cmdline_block_hide":
            cmdlineBlock.removeAll()

        // --- Messages ---
        case "msg_show":
            handleMsgShow(args)
        case "msg_clear":
            messages.removeAll()
        case "msg_showmode", "msg_showcmd", "msg_ruler":
            break // Could be shown in a status area
        case "msg_history_show":
            handleMsgHistoryShow(args)

        // --- Misc ---
        case "set_title":
            if let t = args.first?.stringValue {
                title = t
            }
        case "busy_start":
            isBusy = true
        case "busy_stop":
            isBusy = false
        case "flush":
            handleFlush()
        case "option_set":
            break // Could process guifont etc.
        case "set_icon":
            break
        case "mouse_on", "mouse_off":
            break
        case "bell", "visual_bell":
            break

        default:
            // Unknown event — skip
            break
        }
    }

    // MARK: - Grid Event Handlers

    private func handleGridResize(_ args: [MsgPackValue]) {
        guard args.count >= 3,
              let gridID = args[0].intValue.flatMap({ Int(exactly: $0) }),
              let cols = args[1].intValue.flatMap({ Int(exactly: $0) }),
              let rows = args[2].intValue.flatMap({ Int(exactly: $0) })
        else { return }

        if let grid = grids[gridID] {
            grid.resize(rows: rows, cols: cols)
        } else {
            grids[gridID] = Grid(id: gridID, rows: rows, cols: cols)
        }
    }

    private func handleGridLine(_ args: [MsgPackValue]) {
        guard args.count >= 4,
              let gridID = args[0].intValue.flatMap({ Int(exactly: $0) }),
              let row = args[1].intValue.flatMap({ Int(exactly: $0) }),
              let colStart = args[2].intValue.flatMap({ Int(exactly: $0) }),
              let cellData = args[3].arrayValue
        else { return }

        grids[gridID]?.putLine(row: row, colStart: colStart, cellData: cellData)
    }

    private func handleGridScroll(_ args: [MsgPackValue]) {
        guard args.count >= 7,
              let gridID = args[0].intValue.flatMap({ Int(exactly: $0) }),
              let top = args[1].intValue.flatMap({ Int(exactly: $0) }),
              let bottom = args[2].intValue.flatMap({ Int(exactly: $0) }),
              let left = args[3].intValue.flatMap({ Int(exactly: $0) }),
              let right = args[4].intValue.flatMap({ Int(exactly: $0) }),
              let rowCount = args[5].intValue.flatMap({ Int(exactly: $0) })
        else { return }

        grids[gridID]?.scroll(top: top, bottom: bottom, left: left, right: right, rowCount: rowCount)
    }

    private func handleGridCursorGoto(_ args: [MsgPackValue]) {
        guard args.count >= 3,
              let gridID = args[0].intValue.flatMap({ Int(exactly: $0) }),
              let row = args[1].intValue.flatMap({ Int(exactly: $0) }),
              let col = args[2].intValue.flatMap({ Int(exactly: $0) })
        else { return }

        cursor = CursorState(gridID: gridID, row: row, col: col)
    }

    private func handleGridClear(_ args: [MsgPackValue]) {
        guard let gridID = args.first?.intValue.flatMap({ Int(exactly: $0) }) else { return }
        grids[gridID]?.clear()
    }

    private func handleGridDestroy(_ args: [MsgPackValue]) {
        guard let gridID = args.first?.intValue.flatMap({ Int(exactly: $0) }) else { return }
        grids.removeValue(forKey: gridID)
        windowPositions.removeValue(forKey: gridID)
    }

    // MARK: - Highlight Handlers

    private func handleHlAttrDefine(_ args: [MsgPackValue]) {
        guard args.count >= 2,
              let hlID = args[0].intValue.flatMap({ Int(exactly: $0) })
        else { return }

        let attrs = RawHighlightAttrs.from(msgpack: args[1])
        highlightTable[hlID] = attrs
    }

    private func handleDefaultColorsSet(_ args: [MsgPackValue]) {
        guard args.count >= 3 else { return }
        if let fg = args[0].uintValue.flatMap({ UInt32(exactly: $0) }) {
            defaultColors.foreground = fg
        }
        if let bg = args[1].uintValue.flatMap({ UInt32(exactly: $0) }) {
            defaultColors.background = bg
        }
        if let sp = args[2].uintValue.flatMap({ UInt32(exactly: $0) }) {
            defaultColors.special = sp
        }
    }

    // MARK: - Mode Handlers

    private func handleModeInfoSet(_ args: [MsgPackValue]) {
        // args: [cursor_style_enabled, mode_info_list]
        guard args.count >= 2, case .array(let modeList) = args[1] else { return }

        modeInfoList = modeList.compactMap { entry -> ModeInfo? in
            guard case .map(let dict) = entry else { return nil }
            var info = ModeInfo()
            for (key, val) in dict {
                guard let keyStr = key.stringValue else { continue }
                switch keyStr {
                case "name":
                    info.name = val.stringValue ?? ""
                case "short_name":
                    info.shortName = val.stringValue ?? ""
                case "cursor_shape":
                    if let s = val.stringValue { info.cursorShape = CursorShape(from: s) }
                case "cell_percentage":
                    info.cellPercentage = val.intValue.flatMap({ Int(exactly: $0) }) ?? 0
                case "blinkwait":
                    info.blinkwait = val.intValue.flatMap({ Int(exactly: $0) }) ?? 0
                case "blinkon":
                    info.blinkon = val.intValue.flatMap({ Int(exactly: $0) }) ?? 0
                case "blinkoff":
                    info.blinkoff = val.intValue.flatMap({ Int(exactly: $0) }) ?? 0
                case "attr_id":
                    info.attrID = val.intValue.flatMap({ Int(exactly: $0) }) ?? 0
                case "attr_id_lm":
                    info.attrIDLm = val.intValue.flatMap({ Int(exactly: $0) }) ?? 0
                case "mouse_shape":
                    info.mouseShape = val.intValue.flatMap({ Int(exactly: $0) }) ?? 0
                default:
                    break
                }
            }
            return info
        }
    }

    private func handleModeChange(_ args: [MsgPackValue]) {
        // args: [mode_name, mode_index]
        guard args.count >= 2,
              let modeIndex = args[1].intValue.flatMap({ Int(exactly: $0) }),
              modeIndex < modeInfoList.count
        else { return }

        currentMode = modeInfoList[modeIndex]
    }

    // MARK: - Window Position Handlers

    private func handleWinPos(_ args: [MsgPackValue]) {
        // args: [grid, win, startrow, startcol, width, height]
        guard args.count >= 6,
              let gridID = args[0].intValue.flatMap({ Int(exactly: $0) }),
              let startRow = args[2].intValue.flatMap({ Int(exactly: $0) }),
              let startCol = args[3].intValue.flatMap({ Int(exactly: $0) }),
              let width = args[4].intValue.flatMap({ Int(exactly: $0) }),
              let height = args[5].intValue.flatMap({ Int(exactly: $0) })
        else { return }

        windowPositions[gridID] = WindowPosition(
            gridID: gridID,
            startRow: startRow,
            startCol: startCol,
            width: width,
            height: height
        )
    }

    private func handleWinFloatPos(_ args: [MsgPackValue]) {
        // args: [grid, win, anchor, anchor_grid, anchor_row, anchor_col, focusable, zindex]
        guard args.count >= 6,
              let gridID = args[0].intValue.flatMap({ Int(exactly: $0) }),
              let anchorGrid = args[3].intValue.flatMap({ Int(exactly: $0) })
        else { return }

        let anchorStr = args[2].stringValue ?? "NW"
        let anchor = FloatAnchor(rawValue: anchorStr) ?? .northWest
        let anchorRow = args[4].doubleValue ?? args[4].intValue.flatMap({ Double($0) }) ?? 0
        let anchorCol = args[5].doubleValue ?? args[5].intValue.flatMap({ Double($0) }) ?? 0
        let focusable = args.count > 6 ? (args[6].boolValue ?? true) : true
        let zIndex = args.count > 7 ? (args[7].intValue.flatMap({ Int(exactly: $0) }) ?? 50) : 50

        windowPositions[gridID] = WindowPosition(
            gridID: gridID,
            isFloating: true,
            anchor: anchor,
            anchorGridID: anchorGrid,
            anchorRow: anchorRow,
            anchorCol: anchorCol,
            focusable: focusable,
            zIndex: zIndex
        )

        // Detect tooltip-like floating windows (hover info, diagnostics).
        // These are typically small, non-focusable floating windows.
        // We populate the tooltip state so the TooltipOverlay can display them.
        if !focusable, let grid = grids[gridID] {
            var content: [(highlightID: Int, text: String)] = []
            for row in 0..<grid.rows {
                if let rowCells = grid.getRow(row) {
                    if row > 0 {
                        content.append((highlightID: 0, text: "\n"))
                    }
                    // Group cells by highlight for styled output
                    var currentText = ""
                    var currentHL = 0
                    for cell in rowCells {
                        if cell.highlightID == currentHL {
                            currentText += cell.text
                        } else {
                            if !currentText.isEmpty {
                                content.append((highlightID: currentHL, text: currentText))
                            }
                            currentText = cell.text
                            currentHL = cell.highlightID
                        }
                    }
                    if !currentText.isEmpty {
                        content.append((highlightID: currentHL, text: currentText))
                    }
                }
            }

            tooltip = TooltipState(
                isVisible: true,
                content: content,
                row: Int(anchorRow),
                col: Int(anchorCol),
                gridID: anchorGrid
            )
        }
    }

    private func handleWinHide(_ args: [MsgPackValue]) {
        guard let gridID = args.first?.intValue.flatMap({ Int(exactly: $0) }) else { return }
        // If this was a tooltip floating window, hide the tooltip
        if let pos = windowPositions[gridID], pos.isFloating && !pos.focusable {
            tooltip.isVisible = false
        }
        windowPositions.removeValue(forKey: gridID)
    }

    private func handleWinClose(_ args: [MsgPackValue]) {
        guard let gridID = args.first?.intValue.flatMap({ Int(exactly: $0) }) else { return }
        // If this was a tooltip floating window, hide the tooltip
        if let pos = windowPositions[gridID], pos.isFloating && !pos.focusable {
            tooltip.isVisible = false
        }
        grids.removeValue(forKey: gridID)
        windowPositions.removeValue(forKey: gridID)
    }

    // MARK: - Popup Menu Handlers

    private func handlePopupMenuShow(_ args: [MsgPackValue]) {
        // args: [items, selected, row, col, grid]
        guard args.count >= 4,
              case .array(let items) = args[0]
        else { return }

        let selected = args[1].intValue.flatMap({ Int(exactly: $0) }) ?? -1
        let row = args[2].intValue.flatMap({ Int(exactly: $0) }) ?? 0
        let col = args[3].intValue.flatMap({ Int(exactly: $0) }) ?? 0
        let gridID = args.count > 4 ? (args[4].intValue.flatMap({ Int(exactly: $0) }) ?? 1) : 1

        let menuItems: [PopupMenuItem] = items.enumerated().compactMap { index, item in
            guard case .array(let parts) = item, parts.count >= 4 else { return nil }
            return PopupMenuItem(
                id: index,
                word: parts[0].stringValue ?? "",
                kind: parts[1].stringValue ?? "",
                menu: parts[2].stringValue ?? "",
                info: parts[3].stringValue ?? ""
            )
        }

        popupMenu = PopupMenuState(
            isVisible: true,
            items: menuItems,
            selectedIndex: selected,
            row: row,
            col: col,
            gridID: gridID
        )
    }

    private func handlePopupMenuSelect(_ args: [MsgPackValue]) {
        guard let selected = args.first?.intValue.flatMap({ Int(exactly: $0) }) else { return }
        popupMenu.selectedIndex = selected
    }

    // MARK: - Command Line Handlers

    private func handleCmdlineShow(_ args: [MsgPackValue]) {
        // args: [content, pos, firstc, prompt, indent, level]
        guard args.count >= 6 else { return }

        var content: [(highlightID: Int, text: String)] = []
        if case .array(let contentParts) = args[0] {
            for part in contentParts {
                guard case .array(let chunk) = part, chunk.count >= 2,
                      let hlID = chunk[0].intValue.flatMap({ Int(exactly: $0) }),
                      let text = chunk[1].stringValue
                else { continue }
                content.append((highlightID: hlID, text: text))
            }
        }

        let pos = args[1].intValue.flatMap({ Int(exactly: $0) }) ?? 0
        let firstc = args[2].stringValue ?? ""
        let prompt = args[3].stringValue ?? ""
        let indent = args[4].intValue.flatMap({ Int(exactly: $0) }) ?? 0
        let level = args[5].intValue.flatMap({ Int(exactly: $0) }) ?? 0

        cmdline = CmdlineState(
            isVisible: true,
            content: content,
            position: pos,
            firstCharacter: firstc,
            prompt: prompt,
            indent: indent,
            level: level
        )
    }

    private func handleCmdlinePos(_ args: [MsgPackValue]) {
        guard args.count >= 1,
              let pos = args[0].intValue.flatMap({ Int(exactly: $0) })
        else { return }
        cmdline.position = pos
    }

    private func handleCmdlineSpecialChar(_ args: [MsgPackValue]) {
        // args: [c, shift, level]
        guard args.count >= 1,
              let char = args[0].stringValue
        else { return }
        // Insert the special character at the cursor position in the command line content
        var text = cmdline.text
        let pos = min(cmdline.position, text.count)
        let insertIndex = text.index(text.startIndex, offsetBy: pos)
        text.insert(contentsOf: char, at: insertIndex)
        cmdline.content = [(highlightID: 0, text: text)]
        cmdline.position = pos + char.count
    }

    private func handleCmdlineBlockShow(_ args: [MsgPackValue]) {
        // args: [lines] where lines is [[attr, text], ...]
        cmdlineBlock.removeAll()
        guard let linesArr = args.first?.arrayValue else { return }

        for lineVal in linesArr {
            guard case .array(let chunks) = lineVal else { continue }
            var line: [(highlightID: Int, text: String)] = []
            for chunk in chunks {
                guard case .array(let parts) = chunk, parts.count >= 2,
                      let hlID = parts[0].intValue.flatMap({ Int(exactly: $0) }),
                      let text = parts[1].stringValue
                else { continue }
                line.append((highlightID: hlID, text: text))
            }
            cmdlineBlock.append(line)
        }
    }

    private func handleCmdlineBlockAppend(_ args: [MsgPackValue]) {
        // args: [line] where line is [[attr, text], ...]
        guard let lineArr = args.first?.arrayValue else { return }
        var line: [(highlightID: Int, text: String)] = []
        for chunk in lineArr {
            guard case .array(let parts) = chunk, parts.count >= 2,
                  let hlID = parts[0].intValue.flatMap({ Int(exactly: $0) }),
                  let text = parts[1].stringValue
            else { continue }
            line.append((highlightID: hlID, text: text))
        }
        cmdlineBlock.append(line)
    }

    // MARK: - Message Handlers

    private func handleMsgShow(_ args: [MsgPackValue]) {
        // args: [kind, content, replace_last]
        guard args.count >= 2 else { return }

        let kind = args[0].stringValue ?? ""
        var content: [(highlightID: Int, text: String)] = []
        if case .array(let contentParts) = args[1] {
            for part in contentParts {
                guard case .array(let chunk) = part, chunk.count >= 2,
                      let hlID = chunk[0].intValue.flatMap({ Int(exactly: $0) }),
                      let text = chunk[1].stringValue
                else { continue }
                content.append((highlightID: hlID, text: text))
            }
        }
        let replaceLast = args.count > 2 ? (args[2].boolValue ?? false) : false

        let entry = MessageEntry(kind: kind, content: content, replaceLast: replaceLast)

        if replaceLast && !messages.isEmpty {
            messages[messages.count - 1] = entry
        } else {
            messages.append(entry)
        }
    }

    private func handleMsgHistoryShow(_ args: [MsgPackValue]) {
        // args: [entries] where entries is [[kind, content], ...]
        guard let entriesArr = args.first?.arrayValue else { return }
        messageHistory.removeAll()

        for entryVal in entriesArr {
            guard case .array(let parts) = entryVal, parts.count >= 2 else { continue }
            let kind = parts[0].stringValue ?? ""
            var content: [(highlightID: Int, text: String)] = []
            if case .array(let contentParts) = parts[1] {
                for part in contentParts {
                    guard case .array(let chunk) = part, chunk.count >= 2,
                          let hlID = chunk[0].intValue.flatMap({ Int(exactly: $0) }),
                          let text = chunk[1].stringValue
                    else { continue }
                    content.append((highlightID: hlID, text: text))
                }
            }
            messageHistory.append(MessageEntry(kind: kind, content: content))
        }
    }

    // MARK: - Flush

    private func handleFlush() {
        // Signal to the renderer that a complete frame is ready.
        onFlush?()
    }
}

// MARK: - Errors

public enum NvimSessionError: Error, LocalizedError, Sendable {
    case notConnected
    case sessionStopped
    case transportClosed
    case rpcError(MsgPackValue)
    case attachFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to a Neovim instance."
        case .sessionStopped:
            return "The Neovim session was stopped."
        case .transportClosed:
            return "The transport connection was closed."
        case .rpcError(let value):
            return "Neovim RPC error: \(value)"
        case .attachFailed(let reason):
            return "Failed to attach UI: \(reason)"
        }
    }
}

// MARK: - BufferReader (inline msgpack stream reader)

/// Minimal streaming MsgPack reader used inside the read loop to parse
/// complete values out of a byte buffer. Throws `IncompleteError` when
/// there are not enough bytes for a complete value.
private final class BufferReader {
    struct IncompleteError: Error {}

    let data: [UInt8]
    private(set) var offset: Int = 0

    init(data: [UInt8]) {
        self.data = data
    }

    func readValue() throws -> MsgPackValue {
        guard offset < data.count else { throw IncompleteError() }
        let byte = data[offset]
        offset += 1

        if byte & 0x80 == 0 { return .uint(UInt64(byte)) }
        if byte & 0xe0 == 0xe0 { return .int(Int64(Int8(bitPattern: byte))) }
        if byte & 0xf0 == 0x80 { return try readMap(count: Int(byte & 0x0f)) }
        if byte & 0xf0 == 0x90 { return try readArray(count: Int(byte & 0x0f)) }
        if byte & 0xe0 == 0xa0 { return try .string(readString(count: Int(byte & 0x1f))) }

        switch byte {
        case 0xc0: return .nil
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)

        case 0xc4: return try .binary(readBytes(count: Int(readByte())))
        case 0xc5: return try .binary(readBytes(count: Int(readU16())))
        case 0xc6: return try .binary(readBytes(count: Int(readU32())))

        case 0xc7:
            let n = Int(try readByte())
            let t = Int8(bitPattern: try readByte())
            return try .ext(type: t, data: readBytes(count: n))
        case 0xc8:
            let n = Int(try readU16())
            let t = Int8(bitPattern: try readByte())
            return try .ext(type: t, data: readBytes(count: n))
        case 0xc9:
            let n = Int(try readU32())
            let t = Int8(bitPattern: try readByte())
            return try .ext(type: t, data: readBytes(count: n))

        case 0xca: return .float(Float(bitPattern: try readU32()))
        case 0xcb: return .double(Double(bitPattern: try readU64()))

        case 0xcc: return .uint(UInt64(try readByte()))
        case 0xcd: return .uint(UInt64(try readU16()))
        case 0xce: return .uint(UInt64(try readU32()))
        case 0xcf: return .uint(try readU64())

        case 0xd0: return .int(Int64(Int8(bitPattern: try readByte())))
        case 0xd1: return .int(Int64(Int16(bitPattern: try readU16())))
        case 0xd2: return .int(Int64(Int32(bitPattern: try readU32())))
        case 0xd3: return .int(Int64(Int64(bitPattern: try readU64())))

        case 0xd4: let t = Int8(bitPattern: try readByte()); return try .ext(type: t, data: readBytes(count: 1))
        case 0xd5: let t = Int8(bitPattern: try readByte()); return try .ext(type: t, data: readBytes(count: 2))
        case 0xd6: let t = Int8(bitPattern: try readByte()); return try .ext(type: t, data: readBytes(count: 4))
        case 0xd7: let t = Int8(bitPattern: try readByte()); return try .ext(type: t, data: readBytes(count: 8))
        case 0xd8: let t = Int8(bitPattern: try readByte()); return try .ext(type: t, data: readBytes(count: 16))

        case 0xd9: return try .string(readString(count: Int(readByte())))
        case 0xda: return try .string(readString(count: Int(readU16())))
        case 0xdb: return try .string(readString(count: Int(readU32())))

        case 0xdc: return try readArray(count: Int(readU16()))
        case 0xdd: return try readArray(count: Int(readU32()))
        case 0xde: return try readMap(count: Int(readU16()))
        case 0xdf: return try readMap(count: Int(readU32()))

        default: throw IncompleteError()
        }
    }

    private func readByte() throws -> UInt8 {
        guard offset < data.count else { throw IncompleteError() }
        let b = data[offset]; offset += 1; return b
    }

    private func readU16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw IncompleteError() }
        let v = UInt16(data[offset]) << 8 | UInt16(data[offset + 1]); offset += 2; return v
    }

    private func readU32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw IncompleteError() }
        let v = UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16 | UInt32(data[offset+2]) << 8 | UInt32(data[offset+3])
        offset += 4; return v
    }

    private func readU64() throws -> UInt64 {
        guard offset + 8 <= data.count else { throw IncompleteError() }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[offset + i]) }
        offset += 8; return v
    }

    private func readBytes(count: Int) throws -> Data {
        guard offset + count <= data.count else { throw IncompleteError() }
        let d = data[offset..<(offset + count)]; offset += count; return Data(d)
    }

    private func readString(count: Int) throws -> String {
        let bytes = try readBytes(count: count)
        return String(data: bytes, encoding: .utf8) ?? String(repeating: "\u{FFFD}", count: max(count, 1))
    }

    private func readArray(count: Int) throws -> MsgPackValue {
        var arr: [MsgPackValue] = []
        arr.reserveCapacity(count)
        for _ in 0..<count { arr.append(try readValue()) }
        return .array(arr)
    }

    private func readMap(count: Int) throws -> MsgPackValue {
        var dict: [MsgPackValue: MsgPackValue] = [:]
        dict.reserveCapacity(count)
        for _ in 0..<count {
            let k = try readValue()
            let v = try readValue()
            dict[k] = v
        }
        return .map(dict)
    }
}