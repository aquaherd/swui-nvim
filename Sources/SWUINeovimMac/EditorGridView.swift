import SwiftUI
#if os(macOS)
import AppKit
import CoreText
import Carbon.HIToolbox

struct EditorGridViewRepresentable: NSViewRepresentable {
    let controller: Phase1SessionController
    let fontName: String
    let fontSize: Double

    func makeNSView(context: Context) -> EditorGridNSView {
        let view = EditorGridNSView()
        view.setEditorFont(name: fontName, size: CGFloat(fontSize))
        view.update(with: controller.gridSnapshot)
        view.sendInput = { keys in
            controller.sendInput(keys)
        }
        view.sendMouseInput = { button, action, modifiers, row, col in
            controller.sendMouse(
                button: button,
                action: action,
                modifiers: modifiers,
                row: row,
                col: col
            )
        }
        view.requestResize = { cols, rows in
            controller.requestResize(cols: cols, rows: rows)
        }
        return view
    }

    func updateNSView(_ nsView: EditorGridNSView, context: Context) {
        nsView.setEditorFont(name: fontName, size: CGFloat(fontSize))
        nsView.update(with: controller.gridSnapshot)
        nsView.sendInput = { keys in
            controller.sendInput(keys)
        }
        nsView.sendMouseInput = { button, action, modifiers, row, col in
            controller.sendMouse(
                button: button,
                action: action,
                modifiers: modifiers,
                row: row,
                col: col
            )
        }
        nsView.requestResize = { cols, rows in
            controller.requestResize(cols: cols, rows: rows)
        }
    }
}

final class EditorGridNSView: NSView {
    var sendInput: ((String) -> Void)?
    var sendMouseInput: ((String, String, String, Int, Int) -> Void)?
    var requestResize: ((Int, Int) -> Void)?

    private var snapshot = Phase1SessionController.GridSnapshot(
        rows: 1,
        cols: 1,
        cells: [[.init()]],
        cursorRow: 0,
        cursorCol: 0,
        useIBeamCursor: false,
        defaultForeground: 0xFFFFFF,
        defaultBackground: 0x000000,
        highlights: [:]
    )
    private var lastReportedCellSize: (cols: Int, rows: Int)?

    private var font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    private var renderFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    private var fallbackFontCandidates: [NSFont] = []
    private var attrs: [NSAttributedString.Key: Any] = [:]
    private var cursorBlinkTimer: Timer?
    private var cursorBlinkVisible = true
    private var windowBecameKeyObserver: NSObjectProtocol?
    private var windowResignedKeyObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        renderFont = font
        attrs = [.font: renderFont]
        refreshFallbackFontCandidates()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        renderFont = font
        attrs = [.font: renderFont]
        refreshFallbackFontCandidates()
    }

    func setEditorFont(name: String, size: CGFloat) {
        let normalizedSize = max(8, size)
        var resolved = NSFont(name: name, size: normalizedSize)
            ?? NSFont.monospacedSystemFont(ofSize: normalizedSize, weight: .regular)

        if !isMonospaced(resolved) {
            resolved = NSFont.monospacedSystemFont(ofSize: normalizedSize, weight: .regular)
        }

        guard resolved.fontName != font.fontName || resolved.pointSize != font.pointSize else {
            return
        }

        font = resolved
        refreshFallbackFontCandidates()
        renderFont = makeCascadedRenderFont(base: font)
        attrs = [.font: renderFont]
        lastReportedCellSize = nil
        needsDisplay = true
        emitResizeIfNeeded()
    }

    func update(with snapshot: Phase1SessionController.GridSnapshot) {
        self.snapshot = snapshot
        needsDisplay = true
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
        emitResizeIfNeeded()
    }

    override func layout() {
        super.layout()
        emitResizeIfNeeded()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateCursorBlinkState()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        updateCursorBlinkState()
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWindowFocusObservers()
        updateCursorBlinkState()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeWindowFocusObservers()
            stopCursorBlinking()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }

        let bg = nsColor(rgb: snapshot.defaultBackground)
        cg.setFillColor(bg.cgColor)
        cg.fill(bounds)

        let cellSize = measureCell()
        let textYOffset = max(0, floor((cellSize.height - font.boundingRectForFont.height) / 2.0))

        // 1) Draw cell backgrounds by highlight runs (required for statusline visibility).
        for row in 0..<snapshot.rows {
            var col = 0
            while col < snapshot.cols {
                let cell = snapshot.cells[row][col]
                let runBackground = backgroundColor(for: cell.highlightID)
                let start = col
                col += 1

                while col < snapshot.cols {
                    let next = snapshot.cells[row][col]
                    if backgroundColor(for: next.highlightID) != runBackground { break }
                    col += 1
                }

                let rect = CGRect(
                    x: CGFloat(start) * cellSize.width,
                    y: CGFloat(row) * cellSize.height,
                    width: CGFloat(col - start) * cellSize.width,
                    height: cellSize.height
                )
                cg.setFillColor(runBackground.cgColor)
                cg.fill(rect)
            }
        }

        // 2) Draw text per cell in flipped coordinates for pixel-stable placement.
        for row in 0..<snapshot.rows {
            for col in 0..<snapshot.cols {
                let cell = snapshot.cells[row][col]
                guard !cell.text.isEmpty, cell.text != " " else { continue }
                let fg = foregroundColor(for: cell.highlightID)

                let point = CGPoint(
                    x: CGFloat(col) * cellSize.width,
                    y: CGFloat(row) * cellSize.height + textYOffset
                )

                (cell.text as NSString).draw(
                    at: point,
                    withAttributes: [
                        .font: renderFont,
                        .foregroundColor: fg,
                    ]
                )
            }
        }

        drawCursor(in: cg, cellSize: cellSize)
    }

    override func keyDown(with event: NSEvent) {
        guard let key = translate(event: event) else {
            super.keyDown(with: event)
            return
        }
        sendInput?(key)
    }

    override func mouseDown(with event: NSEvent) {
        sendMouseEvent(button: "left", action: "press", event: event)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseEvent(button: "left", action: "release", event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMouseEvent(button: "left", action: "drag", event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMouseEvent(button: "right", action: "press", event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouseEvent(button: "right", action: "release", event: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMouseEvent(button: "right", action: "drag", event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMouseEvent(button: "middle", action: "press", event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouseEvent(button: "middle", action: "release", event: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMouseEvent(button: "middle", action: "drag", event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let action: String
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            action = event.scrollingDeltaY > 0 ? "up" : "down"
        } else {
            action = event.scrollingDeltaX > 0 ? "left" : "right"
        }
        sendMouseEvent(button: "wheel", action: action, location: location, flags: event.modifierFlags)
    }

    override func resetCursorRects() {
        discardCursorRects()
        let cursor: NSCursor = snapshot.useIBeamCursor ? .iBeam : .arrow
        addCursorRect(bounds, cursor: cursor)
    }

    private func drawCursor(in cg: CGContext, cellSize: CGSize) {
        if shouldBlinkCursor && !cursorBlinkVisible {
            return
        }

        let row = max(0, min(snapshot.rows - 1, snapshot.cursorRow))
        let col = max(0, min(snapshot.cols - 1, snapshot.cursorCol))
        let rect = CGRect(
            x: CGFloat(col) * cellSize.width,
            y: CGFloat(row) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        )

        let cursorColor = nsColor(rgb: 0x7AA2F7).cgColor
        if snapshot.useIBeamCursor {
            let beamWidth: CGFloat = 2.0
            let beamRect = CGRect(
                x: rect.minX + 1,
                y: rect.minY + 1,
                width: beamWidth,
                height: max(1, rect.height - 2)
            )
            cg.setFillColor(cursorColor)
            cg.fill(beamRect)
        } else {
            cg.setFillColor(nsColor(rgb: 0x7AA2F7).withAlphaComponent(0.45).cgColor)
            cg.fill(rect)
        }
    }

    private func measureCell() -> CGSize {
        var chars: [UniChar] = [77] // "M"
        var glyphs = [CGGlyph](repeating: 0, count: 1)

        let ctFont = font as CTFont
        let hasGlyph = CTFontGetGlyphsForCharacters(ctFont, &chars, &glyphs, 1)

        var advance = CGSize(width: font.maximumAdvancement.width, height: 0)
        if hasGlyph {
            _ = CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advance, 1)
        }

        let lineHeight = ceil(font.ascender - font.descender)
        return CGSize(
            width: max(1, advance.width),
            height: max(1, lineHeight)
        )
    }

    private func isMonospaced(_ font: NSFont) -> Bool {
        let traits = CTFontGetSymbolicTraits(font as CTFont)
        return traits.contains(.traitMonoSpace)
    }

    private func refreshFallbackFontCandidates() {
        let available = NSFontManager.shared.availableFonts
        let rankedNames = available
            .filter { name in
                let lower = name.lowercased()
                return lower.contains("nerd") ||
                    lower.contains("nfm") ||
                    lower.contains("symbols")
            }
            .sorted { lhs, rhs in
                rankFallbackName(lhs) < rankFallbackName(rhs)
            }

        fallbackFontCandidates = rankedNames.compactMap { name in
            NSFont(name: name, size: font.pointSize)
        }
    }

    private func rankFallbackName(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.contains("symbols") && lower.contains("mono") { return 0 }
        if lower.contains("symbols") { return 1 }
        if lower.contains("nerd") && lower.contains("mono") { return 2 }
        if lower.contains("nfm") { return 3 }
        return 10
    }

    private func makeCascadedRenderFont(base: NSFont) -> NSFont {
        guard !fallbackFontCandidates.isEmpty else {
            return base
        }

        let fallbackDescriptors = fallbackFontCandidates.map { $0.fontDescriptor }
        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: fallbackDescriptors
        ])

        if let cascaded = NSFont(descriptor: descriptor, size: base.pointSize) {
            return cascaded
        }

        return base
    }

    private func emitResizeIfNeeded() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let cell = measureCell()
        guard cell.width > 0, cell.height > 0 else { return }

        let cols = max(1, Int(floor(bounds.width / cell.width)))
        let rows = max(1, Int(floor(bounds.height / cell.height)))

        if let last = lastReportedCellSize,
           last.cols == cols,
           last.rows == rows {
            return
        }

        lastReportedCellSize = (cols, rows)
        requestResize?(cols, rows)
    }

    private func sendMouseEvent(button: String, action: String, event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        sendMouseEvent(button: button, action: action, location: location, flags: event.modifierFlags)
    }

    private func sendMouseEvent(
        button: String,
        action: String,
        location: CGPoint,
        flags: NSEvent.ModifierFlags
    ) {
        guard let cell = cellCoordinates(at: location) else { return }
        let modifiers = mouseModifierString(flags: flags)
        sendMouseInput?(button, action, modifiers, cell.row, cell.col)
    }

    private func cellCoordinates(at location: CGPoint) -> (row: Int, col: Int)? {
        let cell = measureCell()
        guard cell.width > 0, cell.height > 0 else { return nil }

        let col = Int(floor(location.x / cell.width))
        let row = Int(floor(location.y / cell.height))
        guard row >= 0, col >= 0 else { return nil }
        return (
            row: min(max(0, row), max(0, snapshot.rows - 1)),
            col: min(max(0, col), max(0, snapshot.cols - 1))
        )
    }

    private func mouseModifierString(flags: NSEvent.ModifierFlags) -> String {
        var mods: [String] = []
        if flags.contains(.control) { mods.append("C") }
        if flags.contains(.shift) { mods.append("S") }
        if flags.contains(.option) { mods.append("A") }
        if flags.contains(.command) { mods.append("D") }
        return mods.joined(separator: "-")
    }

    private func foregroundColor(for highlightID: Int) -> NSColor {
        if let style = snapshot.highlights[highlightID] {
            if style.reverse {
                let effectiveBG = style.background ?? snapshot.defaultBackground
                return nsColor(rgb: effectiveBG)
            }
            if let fg = style.foreground {
                return nsColor(rgb: fg)
            }
        }
        return nsColor(rgb: snapshot.defaultForeground)
    }

    private func backgroundColor(for highlightID: Int) -> NSColor {
        if let style = snapshot.highlights[highlightID] {
            if style.reverse {
                let effectiveFG = style.foreground ?? snapshot.defaultForeground
                return nsColor(rgb: effectiveFG)
            }
            if let bg = style.background {
                return nsColor(rgb: bg)
            }
        }
        return nsColor(rgb: snapshot.defaultBackground)
    }

    private func nsColor(rgb: UInt32) -> NSColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    private func translate(event: NSEvent) -> String? {
        if let special = specialKeyName(for: Int(event.keyCode)) {
            return applyModifiers(special, flags: event.modifierFlags)
        }

        guard let chars = event.charactersIgnoringModifiers, let c = chars.first else {
            return nil
        }

        let key = String(c)
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if let rendered = event.characters, !rendered.isEmpty {
                return String(rendered.prefix(1))
            }
            return key
        }

        return applyModifiers(key.lowercased(), flags: event.modifierFlags)
    }

    private func specialKeyName(for keyCode: Int) -> String? {
        switch keyCode {
        case kVK_Return: return "CR"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "BS"
        case kVK_ForwardDelete: return "Del"
        case kVK_Escape: return "Esc"
        case kVK_LeftArrow: return "Left"
        case kVK_RightArrow: return "Right"
        case kVK_UpArrow: return "Up"
        case kVK_DownArrow: return "Down"
        default: return nil
        }
    }

    private func applyModifiers(_ name: String, flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("C") }
        if flags.contains(.shift) { parts.append("S") }
        if flags.contains(.option) { parts.append("M") }
        if flags.contains(.command) { parts.append("D") }

        if parts.isEmpty {
            return "<\(name)>"
        }

        return "<\(parts.joined(separator: "-"))-\(name)>"
    }

    private var shouldBlinkCursor: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    private func updateCursorBlinkState() {
        if shouldBlinkCursor {
            startCursorBlinking()
        } else {
            stopCursorBlinking()
        }
    }

    private func startCursorBlinking() {
        if cursorBlinkTimer != nil { return }
        cursorBlinkVisible = true
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.cursorBlinkVisible.toggle()
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(cursorBlinkTimer!, forMode: .common)
        needsDisplay = true
    }

    private func stopCursorBlinking() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        cursorBlinkVisible = true
        needsDisplay = true
    }

    private func registerWindowFocusObservers() {
        removeWindowFocusObservers()
        guard let window else { return }

        windowBecameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateCursorBlinkState()
            }
        }

        windowResignedKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateCursorBlinkState()
            }
        }
    }

    private func removeWindowFocusObservers() {
        if let observer = windowBecameKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            windowBecameKeyObserver = nil
        }
        if let observer = windowResignedKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            windowResignedKeyObserver = nil
        }
    }
}
#endif
