// EditorView.swift
// SWUINeovim
//
// Main SwiftUI editor view that composes the editor surface (platform-specific
// NSView/UIView) with overlay layers for popup menu, command line, and messages.
// Each EditorView owns one NvimSession and manages its lifecycle.

import SwiftUI
import Combine

// MARK: - EditorView

/// The primary editor view for a single Neovim session.
///
/// This view composes:
/// 1. An `EditorSurface` (platform-native view) for grid rendering and input.
/// 2. SwiftUI overlay layers for popupmenu, cmdline, and messages.
///
/// ## Usage
///
/// ```swift
/// EditorView()
///     .environmentObject(sessionConfig)
/// ```
public struct EditorView: View {
    @StateObject private var session = NvimSession()
    @State private var viewSize: CGSize = .zero
    @State private var isConnected = false
    @State private var showConnectionSheet = false
    @State private var errorMessage: String?

    /// Optional initial file path to open after attaching.
    var initialFilePath: String?

    /// Optional SSH bookmark to connect to on appear.
    var sshBookmark: SSHBookmarkConfig?

    public init(initialFilePath: String? = nil, sshBookmark: SSHBookmarkConfig? = nil) {
        self.initialFilePath = initialFilePath
        self.sshBookmark = sshBookmark
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // Layer 1: Editor surface (CoreText/Metal grid rendering + input)
            editorSurface
                .accessibilityLabel("Neovim editor")
                .accessibilityAddTraits(.allowsDirectInteraction)

            // Layer 2: Floating windows (rendered above the main grid)
            FloatingWindowOverlay(
                grids: session.grids,
                windowPositions: session.windowPositions,
                highlightTable: session.highlightTable,
                defaultColors: session.defaultColors,
                cellSize: currentCellSize
            )

            // Layer 3: Popup menu overlay (completion list)
            if session.popupMenu.isVisible {
                PopupMenuOverlay(
                    state: session.popupMenu,
                    cellSize: currentCellSize,
                    gridOrigin: .zero,
                    onSelect: { index in
                        Task {
                            // Navigate to the selected item by sending appropriate keys
                            let delta = index - session.popupMenu.selectedIndex
                            if delta > 0 {
                                for _ in 0..<delta {
                                    try? await session.input("<C-n>")
                                }
                            } else if delta < 0 {
                                for _ in 0..<(-delta) {
                                    try? await session.input("<C-p>")
                                }
                            }
                            try? await session.input("<CR>")
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
                .animation(.easeOut(duration: 0.12), value: session.popupMenu.isVisible)
            }

            // Layer 4: Tooltip / hover overlay
            if session.tooltip.isVisible {
                TooltipOverlay(
                    state: session.tooltip,
                    cellSize: currentCellSize,
                    highlightTable: session.highlightTable,
                    defaultColors: session.defaultColors
                )
                .transition(.opacity)
                .animation(.easeOut(duration: 0.1), value: session.tooltip.isVisible)
            }

            // Layer 5: Command line overlay (at bottom)
            if session.cmdline.isVisible {
                VStack {
                    Spacer()
                    CmdlineOverlay(
                        state: session.cmdline,
                        highlightTable: session.highlightTable,
                        defaultColors: session.defaultColors
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.easeOut(duration: 0.15), value: session.cmdline.isVisible)
            }

            // Layer 6: Command line block overlay (multiline :lua blocks)
            if !session.cmdlineBlock.isEmpty {
                VStack {
                    Spacer()
                    CmdlineBlockOverlay(
                        blockLines: session.cmdlineBlock,
                        highlightTable: session.highlightTable,
                        defaultColors: session.defaultColors
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.easeOut(duration: 0.15), value: session.cmdlineBlock.count)
            }

            // Layer 7: Message overlay (notification banners)
            if !session.messages.isEmpty {
                VStack {
                    Spacer()
                    MessageOverlay(
                        messages: session.messages,
                        resolveHighlight: { hlID in
                            let attrs = session.highlightTable[hlID]
                            let fg = Color(rgb: attrs?.foreground ?? session.defaultColors.foreground)
                            let bg = Color(rgb: attrs?.background ?? session.defaultColors.background)
                            return (foreground: fg, background: bg)
                        },
                        defaultForeground: Color(rgb: session.defaultColors.foreground),
                        defaultBackground: Color(rgb: session.defaultColors.background)
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, session.cmdline.isVisible ? 52 : 8)
                }
                .animation(.easeOut(duration: 0.2), value: session.messages.count)
            }

            // Layer 8: Busy indicator
            if session.isBusy {
                VStack {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                    }
                    Spacer()
                }
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { viewSize = geometry.size }
                    .onChange(of: geometry.size) { _, newSize in
                        viewSize = newSize
                        handleResize(newSize)
                    }
            }
        )
        .background(editorBackground)
        .overlay(alignment: .center) {
            if !isConnected && session.state == .disconnected {
                disconnectedOverlay
            }
        }
        .overlay(alignment: .center) {
            if let errorMessage {
                errorOverlay(errorMessage)
            }
        }
        .alert("Connection Error", isPresented: .constant(errorMessage != nil)) {
            Button("Dismiss") { errorMessage = nil }
            Button("Retry") {
                errorMessage = nil
                Task { await connect() }
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .navigationTitle(session.title.isEmpty ? "SWUINeovim" : session.title)
        #if os(macOS)
        .navigationSubtitle(modeSubtitle)
        #endif
        .task {
            await connect()
        }
        .onDisappear {
            Task {
                await session.stop()
            }
        }
        .onChange(of: session.state) { _, newState in
            switch newState {
            case .attached:
                isConnected = true
                errorMessage = nil
            case .disconnected:
                isConnected = false
            case .error(let msg):
                errorMessage = msg
                isConnected = false
            default:
                break
            }
        }
    }

    // MARK: - Editor Surface

    @ViewBuilder
    private var editorSurface: some View {
        #if os(macOS)
        EditorSurfaceViewRepresentable(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        EditorSurfaceViewRepresentable(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.keyboard, edges: .bottom)
        #endif
    }

    // MARK: - Computed Properties

    private var currentCellSize: CGSize {
        // Default cell size; will be updated from the renderer
        CGSize(width: 8.4, height: 17.0)
    }

    private var editorBackground: Color {
        let bg = session.defaultColors.background
        let r = Double((bg >> 16) & 0xFF) / 255.0
        let g = Double((bg >> 8) & 0xFF) / 255.0
        let b = Double(bg & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    private var modeSubtitle: String {
        let mode = session.currentMode
        if mode.name.isEmpty { return "" }
        return "— \(mode.name.uppercased())"
    }

    // MARK: - Actions

    private func connect() async {
        #if os(macOS)
        do {
            let transport = LocalTransportHandle()
            try await session.start(
                send: transport.send,
                receive: transport.dataStream,
                stop: transport.stop
            )

            if let filePath = initialFilePath {
                try await session.command("edit \(filePath)")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        #else
        // On iPadOS, show the connection sheet for SSH
        if sshBookmark == nil {
            showConnectionSheet = true
        } else {
            // TODO: Connect via SSH using the bookmark
            errorMessage = "SSH transport not yet implemented."
        }
        #endif
    }

    private func handleResize(_ newSize: CGSize) {
        guard isConnected else { return }
        let cellSize = currentCellSize
        let cols = max(1, Int(floor(newSize.width / cellSize.width)))
        let rows = max(1, Int(floor(newSize.height / cellSize.height)))

        Task {
            try? await session.tryResize(width: cols, height: rows)
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var disconnectedOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Not Connected")
                .font(.title2)
                .foregroundStyle(.secondary)

            #if os(macOS)
            Button("Connect Local") {
                Task { await connect() }
            }
            .buttonStyle(.borderedProminent)
            #endif

            Button("Connect via SSH…") {
                showConnectionSheet = true
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.red)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - SSH Bookmark Config (for iPadOS connections)

/// Lightweight config used to pass SSH bookmark data into EditorView.
/// The full `SSHBookmark` type lives in the Transport package.
public struct SSHBookmarkConfig: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var username: String

    public init(host: String, port: UInt16 = 22, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }
}

// MARK: - LocalTransportHandle (macOS only)

#if os(macOS)
/// A lightweight handle that wraps a local nvim process for use with NvimSession.
/// Bridges the Process-based transport into the closures that NvimSession expects.
final class LocalTransportHandle: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()

    private let dataContinuation: AsyncThrowingStream<Data, Error>.Continuation
    let dataStream: AsyncThrowingStream<Data, Error>

    init(nvimPath: String = "/opt/homebrew/bin/nvim", arguments: [String] = []) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.dataStream = AsyncThrowingStream { continuation = $0 }
        self.dataContinuation = continuation

        process.executableURL = URL(fileURLWithPath: nvimPath)
        process.arguments = ["--embed"] + arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                self?.dataContinuation.finish()
            } else {
                self?.dataContinuation.yield(data)
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.dataContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            dataContinuation.finish(throwing: error)
        }
    }

    func send(_ data: Data) async throws {
        stdinPipe.fileHandleForWriting.write(data)
    }

    func stop() async {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stdinPipe.fileHandleForWriting.closeFile()
        if process.isRunning {
            process.terminate()
        }
        dataContinuation.finish()
    }
}
#endif

// MARK: - EditorSurfaceViewRepresentable

#if os(macOS)
/// macOS: wraps an NSView-based editor surface for CoreText/Metal rendering.
struct EditorSurfaceViewRepresentable: NSViewRepresentable {
    @ObservedObject var session: NvimSession

    func makeNSView(context: Context) -> EditorSurfaceNSView {
        let view = EditorSurfaceNSView(session: session)
        return view
    }

    func updateNSView(_ nsView: EditorSurfaceNSView, context: Context) {
        nsView.session = session
        nsView.needsDisplay = true
    }
}

/// The underlying NSView that handles CoreText rendering and keyboard/mouse input.
class EditorSurfaceNSView: NSView {
    var session: NvimSession

    private lazy var renderer: CoreTextGridRenderer = {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        return CoreTextGridRenderer(font: font)
    }()

    init(session: NvimSession) {
        self.session = session
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        // Register for key events
        becomeFirstResponder()

        // Set up the flush callback
        session.onFlush = { [weak self] in
            DispatchQueue.main.async {
                self?.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let bgColor = session.defaultColors.background
        let r = CGFloat((bgColor >> 16) & 0xFF) / 255.0
        let g = CGFloat((bgColor >> 8) & 0xFF) / 255.0
        let b = CGFloat(bgColor & 0xFF) / 255.0
        context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        context.fill(bounds)

        // Draw each grid
        for (_, grid) in session.grids {
            drawGrid(grid, in: context)
        }

        // Draw cursor
        drawCursor(in: context)
    }

    private func drawGrid(_ grid: Grid, in context: CGContext) {
        let cellWidth = renderer.cellWidth
        let cellHeight = renderer.cellHeight

        for row in 0..<grid.rows {
            guard let rowCells = grid.getRow(row) else { continue }

            let y = CGFloat(row) * cellHeight

            // Draw backgrounds
            var col = 0
            while col < rowCells.count {
                let cell = rowCells[col]
                let attrs = resolveHighlight(cell.highlightID)

                var spanEnd = col + 1
                while spanEnd < rowCells.count && rowCells[spanEnd].highlightID == cell.highlightID {
                    spanEnd += 1
                }

                let bgRect = CGRect(
                    x: CGFloat(col) * cellWidth,
                    y: y,
                    width: CGFloat(spanEnd - col) * cellWidth,
                    height: cellHeight
                )
                context.setFillColor(attrs.background)
                context.fill(bgRect)

                col = spanEnd
            }

            // Draw text
            col = 0
            while col < rowCells.count {
                let cell = rowCells[col]
                if cell.text != " " && !cell.text.isEmpty {
                    let attrs = resolveHighlight(cell.highlightID)
                    let point = CGPoint(
                        x: CGFloat(col) * cellWidth,
                        y: y + renderer.ascent
                    )

                    let attrString = NSAttributedString(
                        string: cell.text,
                        attributes: [
                            .font: renderer.font,
                            .foregroundColor: NSColor(cgColor: attrs.foreground) ?? .white,
                        ]
                    )
                    let line = CTLineCreateWithAttributedString(attrString)

                    context.saveGState()
                    // Flip for CoreText (it expects bottom-left origin)
                    context.translateBy(x: point.x, y: point.y)
                    context.scaleBy(x: 1, y: -1)
                    context.textPosition = .zero
                    CTLineDraw(line, context)
                    context.restoreGState()
                }
                col += 1
            }
        }
    }

    private func drawCursor(in context: CGContext) {
        let cursor = session.cursor
        let cellWidth = renderer.cellWidth
        let cellHeight = renderer.cellHeight

        let x = CGFloat(cursor.col) * cellWidth
        let y = CGFloat(cursor.row) * cellHeight

        let cursorRect: CGRect
        switch session.currentMode.cursorShape {
        case .block:
            cursorRect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
        case .vertical:
            cursorRect = CGRect(x: x, y: y, width: max(2, cellWidth * 0.15), height: cellHeight)
        case .horizontal:
            cursorRect = CGRect(x: x, y: y + cellHeight - 3, width: cellWidth, height: 3)
        }

        let fgColor = session.defaultColors.foreground
        let r = CGFloat((fgColor >> 16) & 0xFF) / 255.0
        let g = CGFloat((fgColor >> 8) & 0xFF) / 255.0
        let b = CGFloat(fgColor & 0xFF) / 255.0
        context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 0.7))
        context.fill(cursorRect)
    }

    private struct ResolvedColors {
        let foreground: CGColor
        let background: CGColor
    }

    private func resolveHighlight(_ hlID: Int) -> ResolvedColors {
        if let attrs = session.highlightTable[hlID] {
            let fg: CGColor
            if let fgVal = attrs.foreground {
                let r = CGFloat((fgVal >> 16) & 0xFF) / 255.0
                let g = CGFloat((fgVal >> 8) & 0xFF) / 255.0
                let b = CGFloat(fgVal & 0xFF) / 255.0
                fg = CGColor(red: r, green: g, blue: b, alpha: 1)
            } else {
                let fgVal = session.defaultColors.foreground
                let r = CGFloat((fgVal >> 16) & 0xFF) / 255.0
                let g = CGFloat((fgVal >> 8) & 0xFF) / 255.0
                let b = CGFloat(fgVal & 0xFF) / 255.0
                fg = CGColor(red: r, green: g, blue: b, alpha: 1)
            }

            let bg: CGColor
            if let bgVal = attrs.background {
                let r = CGFloat((bgVal >> 16) & 0xFF) / 255.0
                let g = CGFloat((bgVal >> 8) & 0xFF) / 255.0
                let b = CGFloat(bgVal & 0xFF) / 255.0
                bg = CGColor(red: r, green: g, blue: b, alpha: 1)
            } else {
                let bgVal = session.defaultColors.background
                let r = CGFloat((bgVal >> 16) & 0xFF) / 255.0
                let g = CGFloat((bgVal >> 8) & 0xFF) / 255.0
                let b = CGFloat(bgVal & 0xFF) / 255.0
                bg = CGColor(red: r, green: g, blue: b, alpha: 1)
            }

            if attrs.reverse {
                return ResolvedColors(foreground: bg, background: fg)
            }
            return ResolvedColors(foreground: fg, background: bg)
        }

        // Default colors
        let fgVal = session.defaultColors.foreground
        let bgVal = session.defaultColors.background
        let fg = CGColor(
            red: CGFloat((fgVal >> 16) & 0xFF) / 255.0,
            green: CGFloat((fgVal >> 8) & 0xFF) / 255.0,
            blue: CGFloat(fgVal & 0xFF) / 255.0,
            alpha: 1
        )
        let bg = CGColor(
            red: CGFloat((bgVal >> 16) & 0xFF) / 255.0,
            green: CGFloat((bgVal >> 8) & 0xFF) / 255.0,
            blue: CGFloat(bgVal & 0xFF) / 255.0,
            alpha: 1
        )
        return ResolvedColors(foreground: fg, background: bg)
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        let key = KeyTranslator.translateKeyEvent(event)
        guard !key.isEmpty else { return }

        Task { @MainActor in
            try? await session.input(key)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // No-op: modifier-only keypresses don't produce Neovim input
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pos = gridPosition(from: event)
        Task { @MainActor in
            try? await session.inputMouse(
                button: "left", action: "press",
                row: pos.row, col: pos.col,
                gridID: session.cursor.gridID
            )
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let pos = gridPosition(from: event)
        Task { @MainActor in
            try? await session.inputMouse(
                button: "left", action: "drag",
                row: pos.row, col: pos.col,
                gridID: session.cursor.gridID
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pos = gridPosition(from: event)
        Task { @MainActor in
            try? await session.inputMouse(
                button: "left", action: "release",
                row: pos.row, col: pos.col,
                gridID: session.cursor.gridID
            )
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let pos = gridPosition(from: event)
        let action = event.deltaY > 0 ? "up" : "down"
        Task { @MainActor in
            try? await session.inputMouse(
                button: "wheel", action: action,
                row: pos.row, col: pos.col,
                gridID: session.cursor.gridID
            )
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let pos = gridPosition(from: event)
        Task { @MainActor in
            try? await session.inputMouse(
                button: "right", action: "press",
                row: pos.row, col: pos.col,
                gridID: session.cursor.gridID
            )
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        let pos = gridPosition(from: event)
        Task { @MainActor in
            try? await session.inputMouse(
                button: "right", action: "release",
                row: pos.row, col: pos.col,
                gridID: session.cursor.gridID
            )
        }
    }

    private func gridPosition(from event: NSEvent) -> (row: Int, col: Int) {
        let location = convert(event.locationInWindow, from: nil)
        let col = max(0, Int(floor(location.x / renderer.cellWidth)))
        let row = max(0, Int(floor(location.y / renderer.cellHeight)))
        return (row, col)
    }
}

// MARK: - CoreTextGridRenderer (minimal helper for EditorSurfaceNSView)

/// Lightweight renderer state for cell metrics and font management.
/// The full CoreTextRenderer is in Rendering/CoreTextRenderer.swift;
/// this is a focused helper for the NSView draw path.
private class CoreTextGridRenderer {
    let font: NSFont
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    init(font: NSFont) {
        self.font = font

        let ctFont = font as CTFont
        let asc = CTFontGetAscent(ctFont)
        let desc = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)

        self.ascent = asc
        self.descent = desc
        self.cellHeight = ceil(asc + desc + leading)

        // Measure monospace cell width from "M"
        let attrString = NSAttributedString(string: "M", attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attrString)
        self.cellWidth = ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
#endif

#if os(iOS)
/// iPadOS: wraps a UIView-based editor surface.
struct EditorSurfaceViewRepresentable: UIViewRepresentable {
    @ObservedObject var session: NvimSession

    func makeUIView(context: Context) -> EditorSurfaceUIView {
        let view = EditorSurfaceUIView(session: session)
        return view
    }

    func updateUIView(_ uiView: EditorSurfaceUIView, context: Context) {
        uiView.session = session
        uiView.setNeedsDisplay()
    }
}

/// UIView subclass for iPadOS editor rendering and input handling.
class EditorSurfaceUIView: UIView, UIKeyInput {
    var session: NvimSession

    var hasText: Bool { true }

    private let cellWidth: CGFloat
    private let cellHeight: CGFloat
    private let font: UIFont

    init(session: NvimSession) {
        self.session = session
        self.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

        let ctFont = font as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        self.cellHeight = ceil(ascent + descent + leading)

        let attrString = NSAttributedString(string: "M", attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attrString)
        self.cellWidth = ceil(CTLineGetTypographicBounds(line, nil, nil, nil))

        super.init(frame: .zero)

        backgroundColor = .black
        isMultipleTouchEnabled = false
        isUserInteractionEnabled = true

        session.onFlush = { [weak self] in
            DispatchQueue.main.async {
                self?.setNeedsDisplay()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - UIKeyInput

    func insertText(_ text: String) {
        let input: String
        if text == "\n" {
            input = "<CR>"
        } else {
            input = text
        }
        Task { @MainActor in
            try? await session.input(input)
        }
    }

    func deleteBackward() {
        Task { @MainActor in
            try? await session.input("<BS>")
        }
    }

    // MARK: - Hardware Keyboard

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []

        // Escape
        commands.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape)))

        // Arrow keys
        commands.append(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleUp)))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleDown)))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeft)))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRight)))

        // Tab
        commands.append(UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTab)))

        // Ctrl combinations
        for char in "abcdefghijklmnopqrstuvwxyz" {
            commands.append(UIKeyCommand(
                input: String(char),
                modifierFlags: .control,
                action: #selector(handleCtrlKey(_:))
            ))
        }

        return commands
    }

    @objc private func handleEscape() {
        Task { @MainActor in try? await session.input("<Esc>") }
    }

    @objc private func handleUp() {
        Task { @MainActor in try? await session.input("<Up>") }
    }

    @objc private func handleDown() {
        Task { @MainActor in try? await session.input("<Down>") }
    }

    @objc private func handleLeft() {
        Task { @MainActor in try? await session.input("<Left>") }
    }

    @objc private func handleRight() {
        Task { @MainActor in try? await session.input("<Right>") }
    }

    @objc private func handleTab() {
        Task { @MainActor in try? await session.input("<Tab>") }
    }

    @objc private func handleCtrlKey(_ command: UIKeyCommand) {
        guard let input = command.input, let char = input.first else { return }
        let key = "<C-\(char)>"
        Task { @MainActor in try? await session.input(key) }
    }

    // MARK: - Touch Input

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        becomeFirstResponder()
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        let col = max(0, Int(floor(location.x / cellWidth)))
        let row = max(0, Int(floor(location.y / cellHeight)))

        Task { @MainActor in
            try? await session.inputMouse(
                button: "left", action: "press",
                row: row, col: col,
                gridID: session.cursor.gridID
            )
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        let col = max(0, Int(floor(location.x / cellWidth)))
        let row = max(0, Int(floor(location.y / cellHeight)))

        Task { @MainActor in
            try? await session.inputMouse(
                button: "left", action: "drag",
                row: row, col: col,
                gridID: session.cursor.gridID
            )
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        let col = max(0, Int(floor(location.x / cellWidth)))
        let row = max(0, Int(floor(location.y / cellHeight)))

        Task { @MainActor in
            try? await session.inputMouse(
                button: "left", action: "release",
                row: row, col: col,
                gridID: session.cursor.gridID
            )
        }
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        // Background
        let bgVal = session.defaultColors.background
        let bgR = CGFloat((bgVal >> 16) & 0xFF) / 255.0
        let bgG = CGFloat((bgVal >> 8) & 0xFF) / 255.0
        let bgB = CGFloat(bgVal & 0xFF) / 255.0
        context.setFillColor(CGColor(red: bgR, green: bgG, blue: bgB, alpha: 1))
        context.fill(bounds)

        // Grid drawing and cursor are handled similarly to macOS
        // (simplified for scaffold; full implementation shares CoreTextRenderer)
        for (_, grid) in session.grids {
            for row in 0..<grid.rows {
                guard let rowCells = grid.getRow(row) else { continue }
                let y = CGFloat(row) * cellHeight
                for (col, cell) in rowCells.enumerated() where !cell.text.isEmpty && cell.text != " " {
                    let x = CGFloat(col) * cellWidth
                    let fgVal = session.defaultColors.foreground
                    let fgColor = UIColor(
                        red: CGFloat((fgVal >> 16) & 0xFF) / 255.0,
                        green: CGFloat((fgVal >> 8) & 0xFF) / 255.0,
                        blue: CGFloat(fgVal & 0xFF) / 255.0,
                        alpha: 1
                    )
                    let attrString = NSAttributedString(
                        string: cell.text,
                        attributes: [
                            .font: font,
                            .foregroundColor: fgColor,
                        ]
                    )
                    attrString.draw(at: CGPoint(x: x, y: y))
                }
            }
        }
    }
}
#endif

// MARK: - KeyTranslator (macOS)

#if os(macOS)
/// Translates NSEvent key events into Neovim key notation strings.
enum KeyTranslator {
    static func translateKeyEvent(_ event: NSEvent) -> String {
        let modifiers = event.modifierFlags
        let hasCtrl = modifiers.contains(.control)
        let hasMeta = modifiers.contains(.option)
        let hasSuper = modifiers.contains(.command)
        let hasShift = modifiers.contains(.shift)

        // Handle special keys
        if let specialKey = translateSpecialKey(event.keyCode) {
            return wrapModifiers(specialKey, ctrl: hasCtrl, meta: hasMeta, super_: hasSuper, shift: hasShift)
        }

        // Handle regular characters
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return ""
        }

        let char = characters

        // Control combinations
        if hasCtrl || hasMeta || hasSuper {
            let base = char.lowercased()
            return wrapModifiers(base, ctrl: hasCtrl, meta: hasMeta, super_: hasSuper, shift: hasShift)
        }

        // Regular text input (including shifted characters)
        if let chars = event.characters, !chars.isEmpty {
            // Escape special characters for Neovim
            switch chars {
            case "<": return "<lt>"
            case "\\": return "<Bslash>"
            case "\r", "\n": return "<CR>"
            case "\t": return "<Tab>"
            case " ": return "<Space>"
            default: return chars
            }
        }

        return ""
    }

    private static func translateSpecialKey(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 53:  return "Esc"
        case 36:  return "CR"
        case 48:  return "Tab"
        case 51:  return "BS"
        case 117: return "Del"
        case 126: return "Up"
        case 125: return "Down"
        case 123: return "Left"
        case 124: return "Right"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PageUp"
        case 121: return "PageDown"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:  return nil
        }
    }

    private static func wrapModifiers(
        _ key: String,
        ctrl: Bool,
        meta: Bool,
        super_: Bool,
        shift: Bool
    ) -> String {
        if !ctrl && !meta && !super_ && !shift {
            return "<\(key)>"
        }

        var prefix = ""
        if shift { prefix += "S-" }
        if ctrl { prefix += "C-" }
        if meta { prefix += "M-" }
        if super_ { prefix += "D-" }

        return "<\(prefix)\(key)>"
    }
}
#endif

// Overlay views are now provided by the Overlays/ directory:
// - PopupMenuOverlay.swift  (ext_popupmenu)
// - CmdlineOverlay.swift    (ext_cmdline)
// - MessageOverlay.swift    (ext_messages)
// - FloatingWindowOverlay.swift (win_float_pos)
// - TooltipOverlay.swift    (LSP hover)

// MARK: - Previews

#if DEBUG
#Preview("Editor View") {
    EditorView()
        .frame(width: 800, height: 600)
}
#endif