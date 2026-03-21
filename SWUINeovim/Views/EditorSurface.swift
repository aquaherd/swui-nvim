// EditorSurface.swift
// SWUINeovim
//
// Platform-specific view (NSViewRepresentable / UIViewRepresentable) that hosts
// the CoreText grid renderer. Handles keyboard input, mouse/touch events, IME
// composition, and bridges between the SwiftUI world and the low-level rendering layer.

import SwiftUI
import Combine

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - EditorSurface (SwiftUI bridge)

/// A SwiftUI view that wraps the platform-specific editor surface.
///
/// This is the main rendering surface for the Neovim grid. It:
/// - Draws the cell grid using CoreText (via `CoreTextRenderer`).
/// - Forwards keyboard events to the `NvimSession` as `nvim_input` calls.
/// - Handles mouse/trackpad/touch events for cursor positioning and selection.
/// - Manages IME (Input Method Editor) composition for CJK and other complex input.
/// - Notifies the session of size changes so the grid can be resized.
///
/// ## Usage
///
/// ```swift
/// EditorSurface(session: mySession)
///     .frame(maxWidth: .infinity, maxHeight: .infinity)
/// ```
#if os(macOS)

public struct EditorSurface: NSViewRepresentable {
    @ObservedObject var session: NvimSession

    public init(session: NvimSession) {
        self.session = session
    }

    public func makeNSView(context: Context) -> EditorSurfaceView {
        let view = EditorSurfaceView(session: session)
        view.coordinator = context.coordinator
        return view
    }

    public func updateNSView(_ nsView: EditorSurfaceView, context: Context) {
        nsView.session = session
        nsView.needsDisplay = true
    }

    public func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(session: session)
    }
}

#else

public struct EditorSurface: UIViewRepresentable {
    @ObservedObject var session: NvimSession

    public init(session: NvimSession) {
        self.session = session
    }

    public func makeUIView(context: Context) -> EditorSurfaceView {
        let view = EditorSurfaceView(session: session)
        view.coordinator = context.coordinator
        return view
    }

    public func updateUIView(_ uiView: EditorSurfaceView, context: Context) {
        uiView.session = session
        uiView.setNeedsDisplay()
    }

    public func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(session: session)
    }
}

#endif

// MARK: - EditorCoordinator

/// Coordinator that manages the bridge between SwiftUI updates, the session,
/// and the platform view. Holds Combine subscriptions for redraw notifications.
public final class EditorCoordinator {
    var session: NvimSession
    private var cancellables = Set<AnyCancellable>()

    init(session: NvimSession) {
        self.session = session
    }

    /// Bind the coordinator to a platform view so that session flush events
    /// trigger redraws.
    func bind(to view: EditorSurfaceView) {
        // The session's onFlush callback triggers a
        // display refresh on the rendering surface.
        session.onFlush = { [weak view] in
            #if os(macOS)
            view?.needsDisplay = true
            #else
            view?.setNeedsDisplay()
            #endif
        }
    }
}

// MARK: - EditorSurfaceView (macOS)

#if os(macOS)

/// The AppKit view that performs CoreText rendering and handles input.
public class EditorSurfaceView: NSView, NSTextInputClient {

    // MARK: - Properties

    var session: NvimSession
    weak var coordinator: EditorCoordinator? {
        didSet {
            coordinator?.bind(to: self)
        }
    }

    /// The font used for grid rendering.
    var editorFont: NSFont {
        didSet {
            renderer.setFont(editorFont)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// The CoreText renderer that draws the grid.
    private(set) var renderer: CoreTextGridRenderer

    /// Marked text for IME composition.
    private var markedText: NSMutableAttributedString = NSMutableAttributedString()
    private var markedRange: NSRange = NSRange(location: NSNotFound, length: 0)
    private var selectedRange_: NSRange = NSRange(location: 0, length: 0)

    /// Tracks whether we have a live resize in progress.
    private var isLiveResizing = false

    /// Debounce timer for resize events during live resize.
    private var resizeTimer: Timer?

    // MARK: - Init

    init(session: NvimSession) {
        self.session = session
        self.editorFont = NSFont.monospacedSystemFont(ofSize: 14.0, weight: .regular)
        self.renderer = CoreTextGridRenderer(font: editorFont)
        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        // Enable key input
        // The view needs to be first responder to receive key events.
        needsDisplay = true
    }

    // MARK: - View Lifecycle

    public override var acceptsFirstResponder: Bool { true }
    public override var canBecomeKeyView: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        true
    }

    public override var isFlipped: Bool {
        // Use top-left origin to match Neovim's grid coordinate system.
        true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        handleResize(to: newSize)
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isLiveResizing = false
        handleResize(to: bounds.size)
    }

    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isLiveResizing = true
    }

    // MARK: - Resize Handling

    private func handleResize(to size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }

        let (cols, rows) = renderer.gridSize(for: size)
        guard cols > 0, rows > 0 else { return }

        // During live resize, debounce to avoid flooding Neovim with resize requests.
        if isLiveResizing {
            resizeTimer?.invalidate()
            resizeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                self?.sendResize(cols: cols, rows: rows)
            }
        } else {
            sendResize(cols: cols, rows: rows)
        }
    }

    private func sendResize(cols: Int, rows: Int) {
        Task { @MainActor in
            try? await session.tryResize(width: cols, height: rows)
        }
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let viewHeight = bounds.height

        // Draw background
        context.setFillColor(defaultBackgroundColor.cgColor)
        context.fill(bounds)

        // Draw each grid
        for (gridID, grid) in session.grids where !isFloatingGrid(gridID) {
            drawGrid(grid, in: context, viewHeight: viewHeight)
        }

        // Draw cursor
        drawCursor(in: context, viewHeight: viewHeight)
    }

    private func isFloatingGrid(_ gridID: Int) -> Bool {
        session.windowPositions[gridID]?.isFloating == true
    }

    private func drawGrid(_ grid: Grid, in context: CGContext, viewHeight: CGFloat) {
        let cellWidth = renderer.cellWidth
        let cellHeight = renderer.cellHeight

        for row in 0..<grid.rows {
            guard let rowCells = grid.getRow(row) else { continue }
            let y = CGFloat(row) * cellHeight

            // Draw backgrounds
            var col = 0
            while col < rowCells.count {
                let cell = rowCells[col]
                let hlAttrs = resolveHighlight(cell.highlightID)
                let bgColor = hlAttrs.reverse
                    ? (hlAttrs.foregroundColor ?? defaultForegroundColor)
                    : (hlAttrs.backgroundColor ?? defaultBackgroundColor)

                // Find run of cells with the same background
                var endCol = col + 1
                while endCol < rowCells.count {
                    let nextCell = rowCells[endCol]
                    let nextAttrs = resolveHighlight(nextCell.highlightID)
                    let nextBg = nextAttrs.reverse
                        ? (nextAttrs.foregroundColor ?? defaultForegroundColor)
                        : (nextAttrs.backgroundColor ?? defaultBackgroundColor)
                    if nextBg != bgColor { break }
                    endCol += 1
                }

                let rect = CGRect(
                    x: CGFloat(col) * cellWidth,
                    y: y,
                    width: CGFloat(endCol - col) * cellWidth,
                    height: cellHeight
                )
                context.setFillColor(bgColor.cgColor)
                context.fill(rect)
                col = endCol
            }

            // Draw text
            col = 0
            var runStart = 0
            var runText = ""
            var runHL = rowCells.first?.highlightID ?? 0

            for (i, cell) in rowCells.enumerated() {
                if cell.highlightID != runHL || i == 0 {
                    if !runText.isEmpty && i > 0 {
                        drawTextRun(
                            runText, at: runStart, row: row,
                            highlightID: runHL, in: context
                        )
                    }
                    runStart = i
                    runText = cell.text
                    runHL = cell.highlightID
                } else {
                    runText += cell.text
                }
            }

            // Draw final run
            if !runText.isEmpty {
                drawTextRun(
                    runText, at: runStart, row: row,
                    highlightID: runHL, in: context
                )
            }
        }
    }

    private func drawTextRun(
        _ text: String,
        at startCol: Int,
        row: Int,
        highlightID: Int,
        in context: CGContext
    ) {
        let hlAttrs = resolveHighlight(highlightID)
        let fgColor = hlAttrs.reverse
            ? (hlAttrs.backgroundColor ?? defaultBackgroundColor)
            : (hlAttrs.foregroundColor ?? defaultForegroundColor)

        var font = editorFont
        if hlAttrs.bold && hlAttrs.italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: [.boldFontMask, .italicFontMask])
        } else if hlAttrs.bold {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        } else if hlAttrs.italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }

        font = GlyphFallbackFonts.cascadedPlatformFont(base: font)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fgColor,
        ]

        let attrString = NSAttributedString(string: text, attributes: attrs)
        let ctLine = CTLineCreateWithAttributedString(attrString)

        let x = CGFloat(startCol) * renderer.cellWidth
        let y = CGFloat(row) * renderer.cellHeight + renderer.ascent

        context.saveGState()
        // Flip for CoreText (it uses bottom-left origin in unflipped contexts,
        // but our view is flipped, so we need to un-flip for text drawing)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(ctLine, context)
        context.restoreGState()

        // Draw decorations
        if hlAttrs.underline {
            drawUnderline(at: startCol, row: row, length: text.count, color: hlAttrs.specialColor ?? fgColor, in: context)
        }
        if hlAttrs.strikethrough {
            drawStrikethrough(at: startCol, row: row, length: text.count, color: fgColor, in: context)
        }
        if hlAttrs.undercurl {
            drawUndercurl(at: startCol, row: row, length: text.count, color: hlAttrs.specialColor ?? fgColor, in: context)
        }
    }

    private func drawUnderline(at col: Int, row: Int, length: Int, color: NSColor, in context: CGContext) {
        let x = CGFloat(col) * renderer.cellWidth
        let y = CGFloat(row + 1) * renderer.cellHeight - 1.5
        let width = CGFloat(length) * renderer.cellWidth

        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.0)
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x + width, y: y))
        context.strokePath()
    }

    private func drawStrikethrough(at col: Int, row: Int, length: Int, color: NSColor, in context: CGContext) {
        let x = CGFloat(col) * renderer.cellWidth
        let y = CGFloat(row) * renderer.cellHeight + renderer.cellHeight * 0.5
        let width = CGFloat(length) * renderer.cellWidth

        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.0)
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x + width, y: y))
        context.strokePath()
    }

    private func drawUndercurl(at col: Int, row: Int, length: Int, color: NSColor, in context: CGContext) {
        let startX = CGFloat(col) * renderer.cellWidth
        let baseY = CGFloat(row + 1) * renderer.cellHeight - 2.0
        let totalWidth = CGFloat(length) * renderer.cellWidth
        let wavelength = renderer.cellWidth * 0.5
        let amplitude: CGFloat = 1.5

        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.0)
        context.move(to: CGPoint(x: startX, y: baseY))

        var x = startX
        var phase = true
        while x < startX + totalWidth {
            let nextX = min(x + wavelength, startX + totalWidth)
            let controlY = phase ? baseY - amplitude : baseY + amplitude
            context.addQuadCurve(
                to: CGPoint(x: nextX, y: baseY),
                control: CGPoint(x: (x + nextX) / 2, y: controlY)
            )
            x = nextX
            phase.toggle()
        }
        context.strokePath()
    }

    private func drawCursor(in context: CGContext, viewHeight: CGFloat) {
        let cursor = session.cursor
        let x = CGFloat(cursor.col) * renderer.cellWidth
        let y = CGFloat(cursor.row) * renderer.cellHeight

        let cursorColor = defaultForegroundColor

        context.saveGState()

        switch session.currentMode.cursorShape {
        case .block:
            context.setFillColor(cursorColor.withAlphaComponent(0.6).cgColor)
            context.fill(CGRect(x: x, y: y, width: renderer.cellWidth, height: renderer.cellHeight))
        case .vertical:
            context.setFillColor(cursorColor.cgColor)
            context.fill(CGRect(x: x, y: y, width: 2.0, height: renderer.cellHeight))
        case .horizontal:
            context.setFillColor(cursorColor.cgColor)
            context.fill(CGRect(x: x, y: y + renderer.cellHeight - 2.0, width: renderer.cellWidth, height: 2.0))
        }

        context.restoreGState()
    }

    // MARK: - Highlight Resolution

    private struct ResolvedHighlight {
        var foregroundColor: NSColor?
        var backgroundColor: NSColor?
        var specialColor: NSColor?
        var bold: Bool = false
        var italic: Bool = false
        var underline: Bool = false
        var undercurl: Bool = false
        var strikethrough: Bool = false
        var reverse: Bool = false
    }

    private var defaultForegroundColor: NSColor {
        colorFromRGB(session.defaultColors.foreground)
    }

    private var defaultBackgroundColor: NSColor {
        colorFromRGB(session.defaultColors.background)
    }

    private func resolveHighlight(_ hlID: Int) -> ResolvedHighlight {
        guard let attrs = session.highlightTable[hlID] else {
            return ResolvedHighlight()
        }

        var resolved = ResolvedHighlight()
        if let fg = attrs.foreground { resolved.foregroundColor = colorFromRGB(fg) }
        if let bg = attrs.background { resolved.backgroundColor = colorFromRGB(bg) }
        if let sp = attrs.special { resolved.specialColor = colorFromRGB(sp) }
        resolved.bold = attrs.bold
        resolved.italic = attrs.italic
        resolved.underline = attrs.underline
        resolved.undercurl = attrs.undercurl
        resolved.strikethrough = attrs.strikethrough
        resolved.reverse = attrs.reverse

        return resolved
    }

    private func colorFromRGB(_ rgb: UInt32) -> NSColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return NSColor(sRGBRed: r, green: g, blue: b, alpha: 1.0)
    }

    // MARK: - Keyboard Input

    public override func keyDown(with event: NSEvent) {
        // First, let the input manager handle it for IME
        inputContext?.handleEvent(event)
    }

    public override func flagsChanged(with event: NSEvent) {
        // Modifier key changes — no-op for now, but we could track modifiers.
    }

    /// Translate an NSEvent key event into Neovim's key notation string.
    private func translateKeyEvent(_ event: NSEvent) -> String? {
        let modifiers = event.modifierFlags
        let hasControl = modifiers.contains(.control)
        let hasOption = modifiers.contains(.option)
        let hasCommand = modifiers.contains(.command)
        let hasShift = modifiers.contains(.shift)

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else {
            return nil
        }

        let keyCode = event.keyCode
        var keyName: String?

        // Map special keys
        switch keyCode {
        case 36:  keyName = "CR"
        case 48:  keyName = "Tab"
        case 51:  keyName = "BS"
        case 53:  keyName = "Esc"
        case 123: keyName = "Left"
        case 124: keyName = "Right"
        case 125: keyName = "Down"
        case 126: keyName = "Up"
        case 116: keyName = "PageUp"
        case 121: keyName = "PageDown"
        case 115: keyName = "Home"
        case 119: keyName = "End"
        case 117: keyName = "Del"
        case 122: keyName = "F1"
        case 120: keyName = "F2"
        case 99:  keyName = "F3"
        case 118: keyName = "F4"
        case 96:  keyName = "F5"
        case 97:  keyName = "F6"
        case 98:  keyName = "F7"
        case 100: keyName = "F8"
        case 101: keyName = "F9"
        case 109: keyName = "F10"
        case 103: keyName = "F11"
        case 111: keyName = "F12"
        case 76:  keyName = "Enter"
        case 49:  keyName = "Space"
        default:  keyName = nil
        }

        // Build the key notation
        let key: String
        if let special = keyName {
            key = special
        } else if chars == "<" {
            key = "lt"
        } else if chars == "\\" {
            key = "Bslash"
        } else {
            // For regular characters, use the character itself
            if hasControl || hasOption || hasCommand {
                key = chars
            } else if hasShift, chars.count == 1, let scalar = chars.unicodeScalars.first,
                      scalar.isASCII, scalar.value >= 0x20 {
                // For printable characters with only shift, just send the shifted character
                if let shifted = event.characters {
                    return shifted
                }
                return chars
            } else {
                return event.characters ?? chars
            }
        }

        // Build modifier prefix
        var mods = ""
        if hasShift { mods += "S-" }
        if hasControl { mods += "C-" }
        if hasOption { mods += "M-" }
        if hasCommand { mods += "D-" }

        if mods.isEmpty && keyName == nil {
            // No modifiers on a regular key — send raw character
            return event.characters ?? chars
        }

        return "<\(mods)\(key)>"
    }

    // MARK: - Mouse Events

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)
        let col = Int(point.x / renderer.cellWidth)
        let row = Int(point.y / renderer.cellHeight)

        let modifier = modifierString(from: event.modifierFlags)

        Task { @MainActor in
            try? await session.inputMouse(
                button: "left",
                action: "press",
                row: row,
                col: col,
                modifier: modifier
            )
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let col = Int(point.x / renderer.cellWidth)
        let row = Int(point.y / renderer.cellHeight)

        let modifier = modifierString(from: event.modifierFlags)

        Task { @MainActor in
            try? await session.inputMouse(
                button: "left",
                action: "drag",
                row: row,
                col: col,
                modifier: modifier
            )
        }
    }

    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let col = Int(point.x / renderer.cellWidth)
        let row = Int(point.y / renderer.cellHeight)

        let modifier = modifierString(from: event.modifierFlags)

        Task { @MainActor in
            try? await session.inputMouse(
                button: "left",
                action: "release",
                row: row,
                col: col,
                modifier: modifier
            )
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let col = Int(point.x / renderer.cellWidth)
        let row = Int(point.y / renderer.cellHeight)

        Task { @MainActor in
            try? await session.inputMouse(button: "right", action: "press", row: row, col: col)
        }
    }

    public override func rightMouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let col = Int(point.x / renderer.cellWidth)
        let row = Int(point.y / renderer.cellHeight)

        Task { @MainActor in
            try? await session.inputMouse(button: "right", action: "release", row: row, col: col)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let col = Int(point.x / renderer.cellWidth)
        let row = Int(point.y / renderer.cellHeight)

        let modifier = modifierString(from: event.modifierFlags)

        // Determine scroll direction
        let dy = event.scrollingDeltaY
        let dx = event.scrollingDeltaX

        if abs(dy) > abs(dx) {
            let action = dy > 0 ? "up" : "down"
            let lines = max(1, Int(abs(dy) / 3))
            Task { @MainActor in
                for _ in 0..<lines {
                    try? await session.inputMouse(
                        button: "wheel",
                        action: action,
                        row: row,
                        col: col,
                        modifier: modifier
                    )
                }
            }
        } else if abs(dx) > 0 {
            let action = dx > 0 ? "left" : "right"
            let cols = max(1, Int(abs(dx) / 3))
            Task { @MainActor in
                for _ in 0..<cols {
                    try? await session.inputMouse(
                        button: "wheel",
                        action: action,
                        row: row,
                        col: col,
                        modifier: modifier
                    )
                }
            }
        }
    }

    private func modifierString(from flags: NSEvent.ModifierFlags) -> String {
        var mods = ""
        if flags.contains(.shift) { mods += "S" }
        if flags.contains(.control) { mods += "C" }
        if flags.contains(.option) { mods += "A" }
        if flags.contains(.command) { mods += "D" }
        return mods
    }

    // MARK: - NSTextInputClient (IME Support)

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let attrString = string as? NSAttributedString {
            text = attrString.string
        } else if let str = string as? String {
            text = str
        } else {
            return
        }

        // Clear marked text
        markedText = NSMutableAttributedString()
        markedRange = NSRange(location: NSNotFound, length: 0)

        // Handle the special case where the input manager sends us a translated key
        // For single characters without modifiers, we can check if this was from a keyDown
        // that we need to translate.
        if text.count == 1, let scalar = text.unicodeScalars.first {
            // Check for control characters
            if scalar.value < 0x20 {
                // Control character — translate to Neovim notation
                let char = Character(Unicode.Scalar(scalar.value + 0x40))
                let nvimKey = "<C-\(char)>"
                Task { @MainActor in
                    try? await session.input(nvimKey)
                }
                return
            }
        }

        // Send the text directly to Neovim
        // We need to escape special characters in Neovim's key notation
        let escaped = text
            .replacingOccurrences(of: "<", with: "<lt>")
            .replacingOccurrences(of: "\\", with: "<Bslash>")

        Task { @MainActor in
            try? await session.input(escaped)
        }
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attrString = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attrString)
        } else if let str = string as? String {
            markedText = NSMutableAttributedString(string: str)
        }
        selectedRange_ = selectedRange
        markedRange = NSRange(location: 0, length: markedText.length)
        needsDisplay = true
    }

    public func unmarkText() {
        markedText = NSMutableAttributedString()
        markedRange = NSRange(location: NSNotFound, length: 0)
        needsDisplay = true
    }

    public func selectedRange() -> NSRange {
        selectedRange_
    }

    public func markedRange() -> NSRange {
        markedRange
    }

    public func hasMarkedText() -> Bool {
        markedRange.location != NSNotFound && markedRange.length > 0
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.font, .foregroundColor, .backgroundColor, .underlineStyle]
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Return the rect of the cursor position for IME candidate window positioning
        let cursor = session.cursor
        let x = CGFloat(cursor.col) * renderer.cellWidth
        let y = CGFloat(cursor.row) * renderer.cellHeight

        let localRect = NSRect(x: x, y: y, width: renderer.cellWidth, height: renderer.cellHeight)
        let windowRect = convert(localRect, to: nil)
        return window?.convertToScreen(windowRect) ?? localRect
    }

    public func characterIndex(for point: NSPoint) -> Int {
        0
    }

    // MARK: - performKeyEquivalent

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let Cmd+Q, Cmd+W, Cmd+M, etc. go to the system
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers == .command {
            let chars = event.charactersIgnoringModifiers ?? ""
            switch chars {
            case "q", "w", "m", "h", ",":
                // Let these pass through to the menu system
                return false
            default:
                break
            }
        }

        // For everything else, handle it ourselves and send to Neovim
        if let nvimKey = translateKeyEvent(event) {
            Task { @MainActor in
                try? await session.input(nvimKey)
            }
            return true
        }

        return false
    }

    // MARK: - doCommandBySelector

    public override func doCommand(by selector: Selector) {
        // Called by the input manager for key bindings we don't handle.
        // We intentionally do nothing here to prevent the system beep
        // on unhandled key events.
    }
}

#else

// MARK: - EditorSurfaceView (iPadOS)

/// The UIKit view that performs CoreText rendering and handles input.
public class EditorSurfaceView: UIView, UIKeyInput, UITextInput {

    // MARK: - Properties

    var session: NvimSession
    weak var coordinator: EditorCoordinator? {
        didSet {
            coordinator?.bind(to: self)
        }
    }

    /// The font used for grid rendering.
    var editorFont: UIFont {
        didSet {
            renderer.setFont(editorFont)
            setNeedsDisplay()
        }
    }

    /// The CoreText renderer that draws the grid.
    private(set) var renderer: CoreTextGridRenderer

    // MARK: - Init

    init(session: NvimSession) {
        self.session = session
        self.editorFont = UIFont.monospacedSystemFont(ofSize: 14.0, weight: .regular)
        self.renderer = CoreTextGridRenderer(font: editorFont)
        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func commonInit() {
        backgroundColor = .black
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = false
        contentMode = .redraw
    }

    // MARK: - First Responder

    public override var canBecomeFirstResponder: Bool { true }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        handleResize(to: bounds.size)
    }

    private func handleResize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let (cols, rows) = renderer.gridSize(for: size)
        guard cols > 0, rows > 0 else { return }

        Task { @MainActor in
            try? await session.tryResize(width: cols, height: rows)
        }
    }

    // MARK: - Drawing

    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        // Fill background
        context.setFillColor(colorFromRGB(session.defaultColors.background).cgColor)
        context.fill(bounds)

        // Draw grids
        for (gridID, grid) in session.grids where !isFloatingGrid(gridID) {
            drawGrid(grid, in: context)
        }

        // Draw cursor
        drawCursor(in: context)
    }

    private func isFloatingGrid(_ gridID: Int) -> Bool {
        session.windowPositions[gridID]?.isFloating == true
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
                let bgColor = resolveBackgroundColor(for: cell.highlightID)

                var endCol = col + 1
                while endCol < rowCells.count {
                    let nextBg = resolveBackgroundColor(for: rowCells[endCol].highlightID)
                    if nextBg != bgColor { break }
                    endCol += 1
                }

                let rect = CGRect(
                    x: CGFloat(col) * cellWidth,
                    y: y,
                    width: CGFloat(endCol - col) * cellWidth,
                    height: cellHeight
                )
                context.setFillColor(bgColor.cgColor)
                context.fill(rect)
                col = endCol
            }

            // Draw text runs
            col = 0
            var runStart = 0
            var runText = ""
            var runHL = rowCells.first?.highlightID ?? 0

            for (i, cell) in rowCells.enumerated() {
                if cell.highlightID != runHL || i == 0 {
                    if !runText.isEmpty && i > 0 {
                        drawTextRun(runText, at: runStart, row: row, highlightID: runHL, in: context)
                    }
                    runStart = i
                    runText = cell.text
                    runHL = cell.highlightID
                } else {
                    runText += cell.text
                }
            }
            if !runText.isEmpty {
                drawTextRun(runText, at: runStart, row: row, highlightID: runHL, in: context)
            }
        }
    }

    private func drawTextRun(_ text: String, at startCol: Int, row: Int, highlightID: Int, in context: CGContext) {
        let fgColor = resolveForegroundColor(for: highlightID)

        var font = editorFont
        if let attrs = session.highlightTable[highlightID] {
            if attrs.bold && attrs.italic {
                if let desc = editorFont.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) {
                    font = UIFont(descriptor: desc, size: editorFont.pointSize)
                }
            } else if attrs.bold {
                if let desc = editorFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                    font = UIFont(descriptor: desc, size: editorFont.pointSize)
                }
            } else if attrs.italic {
                if let desc = editorFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                    font = UIFont(descriptor: desc, size: editorFont.pointSize)
                }
            }
        }

        font = GlyphFallbackFonts.cascadedPlatformFont(base: font)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fgColor,
        ]

        let attrString = NSAttributedString(string: text, attributes: attrs)
        let ctLine = CTLineCreateWithAttributedString(attrString)

        let x = CGFloat(startCol) * renderer.cellWidth
        let y = CGFloat(row) * renderer.cellHeight + renderer.ascent

        context.saveGState()
        // UIKit uses top-left origin, CoreText uses bottom-left
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }

    private func drawCursor(in context: CGContext) {
        let cursor = session.cursor
        let x = CGFloat(cursor.col) * renderer.cellWidth
        let y = CGFloat(cursor.row) * renderer.cellHeight
        let cursorColor = colorFromRGB(session.defaultColors.foreground)

        context.saveGState()

        switch session.currentMode.cursorShape {
        case .block:
            context.setFillColor(cursorColor.withAlphaComponent(0.6).cgColor)
            context.fill(CGRect(x: x, y: y, width: renderer.cellWidth, height: renderer.cellHeight))
        case .vertical:
            context.setFillColor(cursorColor.cgColor)
            context.fill(CGRect(x: x, y: y, width: 2.0, height: renderer.cellHeight))
        case .horizontal:
            context.setFillColor(cursorColor.cgColor)
            context.fill(CGRect(x: x, y: y + renderer.cellHeight - 2.0, width: renderer.cellWidth, height: 2.0))
        }

        context.restoreGState()
    }

    // MARK: - Color Resolution

    private func resolveBackgroundColor(for hlID: Int) -> UIColor {
        guard let attrs = session.highlightTable[hlID] else {
            return colorFromRGB(session.defaultColors.background)
        }
        if attrs.reverse {
            if let fg = attrs.foreground {
                return colorFromRGB(fg)
            }
            return colorFromRGB(session.defaultColors.foreground)
        }
        if let bg = attrs.background {
            return colorFromRGB(bg)
        }
        return colorFromRGB(session.defaultColors.background)
    }

    private func resolveForegroundColor(for hlID: Int) -> UIColor {
        guard let attrs = session.highlightTable[hlID] else {
            return colorFromRGB(session.defaultColors.foreground)
        }
        if attrs.reverse {
            if let bg = attrs.background {
                return colorFromRGB(bg)
            }
            return colorFromRGB(session.defaultColors.background)
        }
        if let fg = attrs.foreground {
            return colorFromRGB(fg)
        }
        return colorFromRGB(session.defaultColors.foreground)
    }

    private func colorFromRGB(_ rgb: UInt32) -> UIColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    // MARK: - Touch Handling

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        becomeFirstResponder()

        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        let col = Int(point.x / renderer.cellWidth)
        let row = Int(point.y / renderer.cellHeight)

        Task { @MainActor in
            try? await session.inputMouse(button: "left", action: "press", row: row, col: col)
        }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        let col = Int(point.x / renderer.cellWidth)
        let row = Int(point.y / renderer.cellHeight)

        Task { @MainActor in
            try? await session.inputMouse(button: "left", action: "drag", row: row, col: col)
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        let col = Int(point.x / renderer.cellWidth)
        let row = Int(point.y / renderer.cellHeight)

        Task { @MainActor in
            try? await session.inputMouse(button: "left", action: "release", row: row, col: col)
        }
    }

    // MARK: - UIKeyInput

    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        let escaped = text
            .replacingOccurrences(of: "<", with: "<lt>")
            .replacingOccurrences(of: "\\", with: "<Bslash>")

        Task { @MainActor in
            try? await session.input(escaped)
        }
    }

    public func deleteBackward() {
        Task { @MainActor in
            try? await session.input("<BS>")
        }
    }

    // MARK: - Hardware Keyboard (iPadOS)

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false

        for press in presses {
            guard let key = press.key else { continue }

            if let nvimKey = translateUIPress(key) {
                Task { @MainActor in
                    try? await session.input(nvimKey)
                }
                handled = true
            }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    private func translateUIPress(_ key: UIKey) -> String? {
        let modifiers = key.modifierFlags
        let hasControl = modifiers.contains(.control)
        let hasOption = modifiers.contains(.alternate)
        let hasCommand = modifiers.contains(.command)
        let hasShift = modifiers.contains(.shift)

        var keyName: String?

        switch key.keyCode {
        case .keyboardReturnOrEnter:  keyName = "CR"
        case .keyboardTab:            keyName = "Tab"
        case .keyboardDeleteOrBackspace: keyName = "BS"
        case .keyboardEscape:         keyName = "Esc"
        case .keyboardLeftArrow:      keyName = "Left"
        case .keyboardRightArrow:     keyName = "Right"
        case .keyboardDownArrow:      keyName = "Down"
        case .keyboardUpArrow:        keyName = "Up"
        case .keyboardPageUp:         keyName = "PageUp"
        case .keyboardPageDown:       keyName = "PageDown"
        case .keyboardHome:           keyName = "Home"
        case .keyboardEnd:            keyName = "End"
        case .keyboardDeleteForward:  keyName = "Del"
        case .keyboardF1:             keyName = "F1"
        case .keyboardF2:             keyName = "F2"
        case .keyboardF3:             keyName = "F3"
        case .keyboardF4:             keyName = "F4"
        case .keyboardF5:             keyName = "F5"
        case .keyboardF6:             keyName = "F6"
        case .keyboardF7:             keyName = "F7"
        case .keyboardF8:             keyName = "F8"
        case .keyboardF9:             keyName = "F9"
        case .keyboardF10:            keyName = "F10"
        case .keyboardF11:            keyName = "F11"
        case .keyboardF12:            keyName = "F12"
        case .keyboardSpacebar:       keyName = "Space"
        default:                      keyName = nil
        }

        let chars = key.charactersIgnoringModifiers

        let finalKey: String
        if let special = keyName {
            finalKey = special
        } else if let chars, !chars.isEmpty {
            if chars == "<" {
                finalKey = "lt"
            } else if chars == "\\" {
                finalKey = "Bslash"
            } else {
                if !hasControl && !hasOption && !hasCommand {
                    // No special modifiers — send the character directly
                    if hasShift {
                        return key.characters ?? chars
                    }
                    return chars
                }
                finalKey = chars
            }
        } else {
            return nil
        }

        var mods = ""
        if hasShift { mods += "S-" }
        if hasControl { mods += "C-" }
        if hasOption { mods += "M-" }
        if hasCommand { mods += "D-" }

        if mods.isEmpty && keyName == nil {
            return key.characters ?? chars
        }

        return "<\(mods)\(finalKey)>"
    }

    // MARK: - UITextInput (minimal conformance for hardware keyboard)

    // Most of these are stubs to satisfy the protocol. The real input
    // goes through pressesBegan and insertText.

    public var markedTextRange: UITextRange? { nil }
    public var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set { }
    }

    public var selectedTextRange: UITextRange? {
        get { nil }
        set { }
    }

    public var beginningOfDocument: UITextPosition { EditorTextPosition(offset: 0) }
    public var endOfDocument: UITextPosition { EditorTextPosition(offset: 0) }
    public var inputDelegate: (any UITextInputDelegate)? {
        get { nil }
        set { }
    }
    public var tokenizer: any UITextInputTokenizer {
        UITextInputStringTokenizer(textInput: self)
    }

    public func text(in range: UITextRange) -> String? { nil }
    public func replace(_ range: UITextRange, withText text: String) { }
    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) { }
    public func unmarkText() { }

    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? { nil }
    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? { nil }
    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? { nil }
    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult { .orderedSame }
    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int { 0 }
    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? { nil }
    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? { nil }
    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) { }
    public func firstRect(for range: UITextRange) -> CGRect { .zero }
    public func caretRect(for position: UITextPosition) -> CGRect {
        let cursor = session.cursor
        let x = CGFloat(cursor.col) * renderer.cellWidth
        let y = CGFloat(cursor.row) * renderer.cellHeight
        return CGRect(x: x, y: y, width: 2, height: renderer.cellHeight)
    }
    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    public func closestPosition(to point: CGPoint) -> UITextPosition? { EditorTextPosition(offset: 0) }
    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { nil }
    public func characterRange(at point: CGPoint) -> UITextRange? { nil }
}

// MARK: - UITextPosition / UITextRange stubs

private class EditorTextPosition: UITextPosition {
    let offset: Int
    init(offset: Int) {
        self.offset = offset
    }
}

private class EditorTextRange: UITextRange {
    private let start_: UITextPosition
    private let end_: UITextPosition

    override var start: UITextPosition { start_ }
    override var end: UITextPosition { end_ }
    override var isEmpty: Bool { true }

    init(start: UITextPosition, end: UITextPosition) {
        self.start_ = start
        self.end_ = end
    }
}

#endif

// MARK: - CoreTextGridRenderer (lightweight wrapper)

/// A lightweight renderer wrapper used by the EditorSurfaceView for metrics.
/// This is distinct from the full CoreTextRenderer in the Rendering module;
/// this version is minimal and focused on cell metrics for layout purposes.
public final class CoreTextGridRenderer {

    /// The font used for rendering.
    public private(set) var font: Any // NSFont or UIFont

    /// Cell width in points.
    public private(set) var cellWidth: CGFloat

    /// Cell height in points.
    public private(set) var cellHeight: CGFloat

    /// Font ascent (distance from baseline to top of tallest glyph).
    public private(set) var ascent: CGFloat

    /// Font descent (distance from baseline to bottom of lowest glyph).
    public private(set) var descent: CGFloat

    #if os(macOS)
    public init(font: NSFont) {
        self.font = font
        let ctFont = font as CTFont
        let asc = CTFontGetAscent(ctFont)
        let desc = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        self.ascent = ceil(asc)
        self.descent = ceil(desc)
        self.cellHeight = ceil(asc + desc + leading)

        // Measure cell width using the advance of "M"
        let attrString = NSAttributedString(string: "M", attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attrString)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        self.cellWidth = ceil(width)
    }

    public func setFont(_ newFont: NSFont) {
        self.font = newFont
        let ctFont = newFont as CTFont
        let asc = CTFontGetAscent(ctFont)
        let desc = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        self.ascent = ceil(asc)
        self.descent = ceil(desc)
        self.cellHeight = ceil(asc + desc + leading)

        let attrString = NSAttributedString(string: "M", attributes: [.font: newFont])
        let line = CTLineCreateWithAttributedString(attrString)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        self.cellWidth = ceil(width)
    }
    #else
    public init(font: UIFont) {
        self.font = font
        let ctFont = font as CTFont
        let asc = CTFontGetAscent(ctFont)
        let desc = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        self.ascent = ceil(asc)
        self.descent = ceil(desc)
        self.cellHeight = ceil(asc + desc + leading)

        let attrString = NSAttributedString(string: "M", attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attrString)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        self.cellWidth = ceil(width)
    }

    public func setFont(_ newFont: UIFont) {
        self.font = newFont
        let ctFont = newFont as CTFont
        let asc = CTFontGetAscent(ctFont)
        let desc = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        self.ascent = ceil(asc)
        self.descent = ceil(desc)
        self.cellHeight = ceil(asc + desc + leading)

        let attrString = NSAttributedString(string: "M", attributes: [.font: newFont])
        let line = CTLineCreateWithAttributedString(attrString)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        self.cellWidth = ceil(width)
    }
    #endif

    /// Calculate how many columns and rows fit in the given view size.
    public func gridSize(for size: CGSize) -> (columns: Int, rows: Int) {
        let cols = max(1, Int(floor(size.width / cellWidth)))
        let rows = max(1, Int(floor(size.height / cellHeight)))
        return (cols, rows)
    }
}