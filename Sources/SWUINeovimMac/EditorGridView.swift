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
        //    Box-drawing characters are skipped here and rendered in step 3.
        for row in 0..<snapshot.rows {
            for col in 0..<snapshot.cols {
                let cell = snapshot.cells[row][col]
                guard !cell.text.isEmpty, cell.text != " " else { continue }
                if BoxDrawing.info(for: cell.text) != nil { continue }
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

        // 3) Owner-draw box-drawing / line-drawing characters as CGContext paths.
        drawBoxDrawingCharacters(in: cg, cellSize: cellSize)

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

    // MARK: - Box-Drawing / Line-Drawing Owner Draw

    private func drawBoxDrawingCharacters(in cg: CGContext, cellSize: CGSize) {
        let lineWidth: CGFloat = 1.0
        let heavyLineWidth: CGFloat = 2.0

        for row in 0..<snapshot.rows {
            for col in 0..<snapshot.cols {
                let cell = snapshot.cells[row][col]
                guard let info = BoxDrawing.info(for: cell.text) else { continue }

                let fg = foregroundColor(for: cell.highlightID)
                let cellRect = CGRect(
                    x: CGFloat(col) * cellSize.width,
                    y: CGFloat(row) * cellSize.height,
                    width: cellSize.width,
                    height: cellSize.height
                )
                let cx = cellRect.midX
                let cy = cellRect.midY

                cg.saveGState()
                cg.setStrokeColor(fg.cgColor)
                cg.setLineCap(.square)
                cg.setLineJoin(.miter)

                let w = info.heavy ? heavyLineWidth : lineWidth
                cg.setLineWidth(w)

                if info.rounded {
                    drawRoundedCorner(info: info, in: cg, cellRect: cellRect, cx: cx, cy: cy)
                } else {
                    if info.left {
                        cg.move(to: CGPoint(x: cellRect.minX, y: cy))
                        cg.addLine(to: CGPoint(x: cx, y: cy))
                        cg.strokePath()
                    }
                    if info.right {
                        cg.move(to: CGPoint(x: cx, y: cy))
                        cg.addLine(to: CGPoint(x: cellRect.maxX, y: cy))
                        cg.strokePath()
                    }
                    if info.up {
                        cg.move(to: CGPoint(x: cx, y: cellRect.minY))
                        cg.addLine(to: CGPoint(x: cx, y: cy))
                        cg.strokePath()
                    }
                    if info.down {
                        cg.move(to: CGPoint(x: cx, y: cy))
                        cg.addLine(to: CGPoint(x: cx, y: cellRect.maxY))
                        cg.strokePath()
                    }
                }

                // Double-line variants: draw a second line offset from the first
                if info.double {
                    let offset: CGFloat = 2.0
                    cg.setLineWidth(lineWidth)
                    if info.left && info.right {
                        // Two horizontal lines
                        cg.move(to: CGPoint(x: cellRect.minX, y: cy - offset))
                        cg.addLine(to: CGPoint(x: cellRect.maxX, y: cy - offset))
                        cg.strokePath()
                        cg.move(to: CGPoint(x: cellRect.minX, y: cy + offset))
                        cg.addLine(to: CGPoint(x: cellRect.maxX, y: cy + offset))
                        cg.strokePath()
                    } else if info.up && info.down {
                        // Two vertical lines
                        cg.move(to: CGPoint(x: cx - offset, y: cellRect.minY))
                        cg.addLine(to: CGPoint(x: cx - offset, y: cellRect.maxY))
                        cg.strokePath()
                        cg.move(to: CGPoint(x: cx + offset, y: cellRect.minY))
                        cg.addLine(to: CGPoint(x: cx + offset, y: cellRect.maxY))
                        cg.strokePath()
                    }
                }

                // Dashed line variants
                if info.dashed {
                    let dashLen: CGFloat = cellSize.width * 0.2
                    cg.setLineDash(phase: 0, lengths: [dashLen, dashLen])
                    if info.left {
                        cg.move(to: CGPoint(x: cellRect.minX, y: cy))
                        cg.addLine(to: CGPoint(x: cx, y: cy))
                        cg.strokePath()
                    }
                    if info.right {
                        cg.move(to: CGPoint(x: cx, y: cy))
                        cg.addLine(to: CGPoint(x: cellRect.maxX, y: cy))
                        cg.strokePath()
                    }
                    if info.up {
                        cg.move(to: CGPoint(x: cx, y: cellRect.minY))
                        cg.addLine(to: CGPoint(x: cx, y: cy))
                        cg.strokePath()
                    }
                    if info.down {
                        cg.move(to: CGPoint(x: cx, y: cy))
                        cg.addLine(to: CGPoint(x: cx, y: cellRect.maxY))
                        cg.strokePath()
                    }
                    cg.setLineDash(phase: 0, lengths: [])
                }

                cg.restoreGState()
            }
        }
    }

    private func drawRoundedCorner(
        info: BoxDrawing.Info,
        in cg: CGContext,
        cellRect: CGRect,
        cx: CGFloat,
        cy: CGFloat
    ) {
        // For rounded corners (╭╮╯╰), draw an arc connecting the two segments.
        // The radius is the smaller of half-width and half-height, capped for aesthetics.
        let halfW = cellRect.width / 2
        let halfH = cellRect.height / 2
        let radius = min(halfW, halfH)

        if info.right && info.down {
            // ╭ — arc from down-segment end to right-segment end
            cg.move(to: CGPoint(x: cx, y: cellRect.maxY))
            cg.addLine(to: CGPoint(x: cx, y: cy + radius))
            cg.addArc(center: CGPoint(x: cx + radius, y: cy + radius),
                       radius: radius,
                       startAngle: .pi,
                       endAngle: .pi * 1.5,
                       clockwise: false)
            cg.addLine(to: CGPoint(x: cellRect.maxX, y: cy))
            cg.strokePath()
        } else if info.left && info.down {
            // ╮ — arc from left-segment end to down-segment end
            cg.move(to: CGPoint(x: cellRect.minX, y: cy))
            cg.addLine(to: CGPoint(x: cx - radius, y: cy))
            cg.addArc(center: CGPoint(x: cx - radius, y: cy + radius),
                       radius: radius,
                       startAngle: .pi * 1.5,
                       endAngle: 0,
                       clockwise: false)
            cg.addLine(to: CGPoint(x: cx, y: cellRect.maxY))
            cg.strokePath()
        } else if info.left && info.up {
            // ╯ — arc from up-segment end to left-segment end
            cg.move(to: CGPoint(x: cx, y: cellRect.minY))
            cg.addLine(to: CGPoint(x: cx, y: cy - radius))
            cg.addArc(center: CGPoint(x: cx - radius, y: cy - radius),
                       radius: radius,
                       startAngle: 0,
                       endAngle: .pi * 0.5,
                       clockwise: false)
            cg.addLine(to: CGPoint(x: cellRect.minX, y: cy))
            cg.strokePath()
        } else if info.right && info.up {
            // ╰ — arc from right-segment end to up-segment end
            cg.move(to: CGPoint(x: cellRect.maxX, y: cy))
            cg.addLine(to: CGPoint(x: cx + radius, y: cy))
            cg.addArc(center: CGPoint(x: cx + radius, y: cy - radius),
                       radius: radius,
                       startAngle: .pi * 0.5,
                       endAngle: .pi,
                       clockwise: false)
            cg.addLine(to: CGPoint(x: cx, y: cellRect.minY))
            cg.strokePath()
        }
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

// MARK: - Box-Drawing Character Lookup

/// Maps Unicode box-drawing characters (U+2500–U+257F) and rounded-corner
/// characters (U+256D–U+2570) to their segment connectivity so the grid
/// renderer can owner-draw them as CGContext paths instead of font glyphs.
enum BoxDrawing {

    struct Info {
        /// Whether a line extends to the left edge of the cell.
        let left: Bool
        /// Whether a line extends to the right edge of the cell.
        let right: Bool
        /// Whether a line extends to the top edge of the cell.
        let up: Bool
        /// Whether a line extends to the bottom edge of the cell.
        let down: Bool
        /// Whether this is a rounded corner (use arc instead of mitre).
        let rounded: Bool
        /// Whether the line should be drawn with heavy (thick) weight.
        let heavy: Bool
        /// Whether the character uses double-line style.
        let double: Bool
        /// Whether the character uses dashed-line style.
        let dashed: Bool

        init(
            left: Bool = false,
            right: Bool = false,
            up: Bool = false,
            down: Bool = false,
            rounded: Bool = false,
            heavy: Bool = false,
            double: Bool = false,
            dashed: Bool = false
        ) {
            self.left = left
            self.right = right
            self.up = up
            self.down = down
            self.rounded = rounded
            self.heavy = heavy
            self.double = double
            self.dashed = dashed
        }
    }

    /// Returns segment info for a box-drawing character, or `nil` if
    /// the string is not a recognized box-drawing character.
    static func info(for text: String) -> Info? {
        guard let scalar = text.unicodeScalars.first,
              text.unicodeScalars.count == 1 else { return nil }
        return table[scalar]
    }

    // Light lines
    private static let h   = Info(left: true, right: true)                       // ─
    private static let v   = Info(up: true, down: true)                          // │
    private static let dr  = Info(right: true, down: true)                       // ┌
    private static let dl  = Info(left: true, down: true)                        // ┐
    private static let ur  = Info(right: true, up: true)                         // └
    private static let ul  = Info(left: true, up: true)                          // ┘
    private static let vr  = Info(right: true, up: true, down: true)             // ├
    private static let vl  = Info(left: true, up: true, down: true)              // ┤
    private static let dh  = Info(left: true, right: true, down: true)           // ┬
    private static let uh  = Info(left: true, right: true, up: true)             // ┴
    private static let vh  = Info(left: true, right: true, up: true, down: true) // ┼

    // Heavy lines
    private static let hH  = Info(left: true, right: true, heavy: true)
    private static let vH  = Info(up: true, down: true, heavy: true)
    private static let drH = Info(right: true, down: true, heavy: true)
    private static let dlH = Info(left: true, down: true, heavy: true)
    private static let urH = Info(right: true, up: true, heavy: true)
    private static let ulH = Info(left: true, up: true, heavy: true)
    private static let vrH = Info(right: true, up: true, down: true, heavy: true)
    private static let vlH = Info(left: true, up: true, down: true, heavy: true)
    private static let dhH = Info(left: true, right: true, down: true, heavy: true)
    private static let uhH = Info(left: true, right: true, up: true, heavy: true)
    private static let vhH = Info(left: true, right: true, up: true, down: true, heavy: true)

    // Double lines
    private static let hD  = Info(left: true, right: true, double: true)
    private static let vD  = Info(up: true, down: true, double: true)

    // Rounded corners
    private static let rDR = Info(right: true, down: true, rounded: true)  // ╭
    private static let rDL = Info(left: true, down: true, rounded: true)   // ╮
    private static let rUL = Info(left: true, up: true, rounded: true)     // ╯
    private static let rUR = Info(right: true, up: true, rounded: true)    // ╰

    // Dashed lines
    private static let hDash = Info(left: true, right: true, dashed: true)
    private static let vDash = Info(up: true, down: true, dashed: true)
    private static let hDashH = Info(left: true, right: true, heavy: true, dashed: true)
    private static let vDashH = Info(up: true, down: true, heavy: true, dashed: true)

    /// Lookup table mapping Unicode scalars to their box-drawing segment info.
    private static let table: [Unicode.Scalar: Info] = [
        // ── Light box drawing ──────────────────────────────────────────
        "\u{2500}": h,    // ─  BOX DRAWINGS LIGHT HORIZONTAL
        "\u{2502}": v,    // │  BOX DRAWINGS LIGHT VERTICAL
        "\u{250C}": dr,   // ┌  BOX DRAWINGS LIGHT DOWN AND RIGHT
        "\u{2510}": dl,   // ┐  BOX DRAWINGS LIGHT DOWN AND LEFT
        "\u{2514}": ur,   // └  BOX DRAWINGS LIGHT UP AND RIGHT
        "\u{2518}": ul,   // ┘  BOX DRAWINGS LIGHT UP AND LEFT
        "\u{251C}": vr,   // ├  BOX DRAWINGS LIGHT VERTICAL AND RIGHT
        "\u{2524}": vl,   // ┤  BOX DRAWINGS LIGHT VERTICAL AND LEFT
        "\u{252C}": dh,   // ┬  BOX DRAWINGS LIGHT DOWN AND HORIZONTAL
        "\u{2534}": uh,   // ┴  BOX DRAWINGS LIGHT UP AND HORIZONTAL
        "\u{253C}": vh,   // ┼  BOX DRAWINGS LIGHT VERTICAL AND HORIZONTAL

        // ── Heavy box drawing ──────────────────────────────────────────
        "\u{2501}": hH,   // ━  BOX DRAWINGS HEAVY HORIZONTAL
        "\u{2503}": vH,   // ┃  BOX DRAWINGS HEAVY VERTICAL
        "\u{250F}": drH,  // ┏  BOX DRAWINGS HEAVY DOWN AND RIGHT
        "\u{2513}": dlH,  // ┓  BOX DRAWINGS HEAVY DOWN AND LEFT
        "\u{2517}": urH,  // ┗  BOX DRAWINGS HEAVY UP AND RIGHT
        "\u{251B}": ulH,  // ┛  BOX DRAWINGS HEAVY UP AND LEFT
        "\u{2523}": vrH,  // ┣  BOX DRAWINGS HEAVY VERTICAL AND RIGHT
        "\u{252B}": vlH,  // ┫  BOX DRAWINGS HEAVY VERTICAL AND LEFT
        "\u{2533}": dhH,  // ┳  BOX DRAWINGS HEAVY DOWN AND HORIZONTAL
        "\u{253B}": uhH,  // ┻  BOX DRAWINGS HEAVY UP AND HORIZONTAL
        "\u{254B}": vhH,  // ╋  BOX DRAWINGS HEAVY VERTICAL AND HORIZONTAL

        // ── Double box drawing ─────────────────────────────────────────
        "\u{2550}": hD,   // ═  BOX DRAWINGS DOUBLE HORIZONTAL
        "\u{2551}": vD,   // ║  BOX DRAWINGS DOUBLE VERTICAL

        // ── Rounded corners ────────────────────────────────────────────
        "\u{256D}": rDR,  // ╭  BOX DRAWINGS LIGHT ARC DOWN AND RIGHT
        "\u{256E}": rDL,  // ╮  BOX DRAWINGS LIGHT ARC DOWN AND LEFT
        "\u{256F}": rUL,  // ╯  BOX DRAWINGS LIGHT ARC UP AND LEFT
        "\u{2570}": rUR,  // ╰  BOX DRAWINGS LIGHT ARC UP AND RIGHT

        // ── Dashed lines ───────────────────────────────────────────────
        "\u{2504}": hDash,  // ┄  BOX DRAWINGS LIGHT TRIPLE DASH HORIZONTAL
        "\u{2505}": hDashH, // ┅  BOX DRAWINGS HEAVY TRIPLE DASH HORIZONTAL
        "\u{2506}": vDash,  // ┆  BOX DRAWINGS LIGHT TRIPLE DASH VERTICAL
        "\u{2507}": vDashH, // ┇  BOX DRAWINGS HEAVY TRIPLE DASH VERTICAL
        "\u{2508}": hDash,  // ┈  BOX DRAWINGS LIGHT QUADRUPLE DASH HORIZONTAL
        "\u{2509}": hDashH, // ┉  BOX DRAWINGS HEAVY QUADRUPLE DASH HORIZONTAL
        "\u{250A}": vDash,  // ┊  BOX DRAWINGS LIGHT QUADRUPLE DASH VERTICAL
        "\u{250B}": vDashH, // ┋  BOX DRAWINGS HEAVY QUADRUPLE DASH VERTICAL

        // ── Mixed light/heavy (common subset) ─────────────────────────
        "\u{250D}": Info(right: true, down: true, heavy: false),  // ┍
        "\u{250E}": Info(right: true, down: true, heavy: false),  // ┎
        "\u{2511}": Info(left: true, down: true, heavy: false),   // ┑
        "\u{2512}": Info(left: true, down: true, heavy: false),   // ┒
        "\u{2515}": Info(right: true, up: true, heavy: false),    // ┕
        "\u{2516}": Info(right: true, up: true, heavy: false),    // ┖
        "\u{2519}": Info(left: true, up: true, heavy: false),     // ┙
        "\u{251A}": Info(left: true, up: true, heavy: false),     // ┚
        "\u{251D}": Info(right: true, up: true, down: true),      // ┝
        "\u{251E}": Info(right: true, up: true, down: true),      // ┞
        "\u{251F}": Info(right: true, up: true, down: true),      // ┟
        "\u{2520}": Info(right: true, up: true, down: true, heavy: true), // ┠
        "\u{2521}": Info(right: true, up: true, down: true),      // ┡
        "\u{2522}": Info(right: true, up: true, down: true),      // ┢
        "\u{2525}": Info(left: true, up: true, down: true),       // ┥
        "\u{2526}": Info(left: true, up: true, down: true),       // ┦
        "\u{2527}": Info(left: true, up: true, down: true),       // ┧
        "\u{2528}": Info(left: true, up: true, down: true, heavy: true), // ┨
        "\u{2529}": Info(left: true, up: true, down: true),       // ┩
        "\u{252A}": Info(left: true, up: true, down: true),       // ┪
        "\u{252D}": Info(left: true, right: true, down: true),    // ┭
        "\u{252E}": Info(left: true, right: true, down: true),    // ┮
        "\u{252F}": Info(left: true, right: true, down: true),    // ┯
        "\u{2530}": Info(left: true, right: true, down: true),    // ┰
        "\u{2531}": Info(left: true, right: true, down: true),    // ┱
        "\u{2532}": Info(left: true, right: true, down: true),    // ┲
        "\u{2535}": Info(left: true, right: true, up: true),      // ┵
        "\u{2536}": Info(left: true, right: true, up: true),      // ┶
        "\u{2537}": Info(left: true, right: true, up: true),      // ┷
        "\u{2538}": Info(left: true, right: true, up: true),      // ┸
        "\u{2539}": Info(left: true, right: true, up: true),      // ┹
        "\u{253A}": Info(left: true, right: true, up: true),      // ┺
        "\u{253D}": Info(left: true, right: true, up: true, down: true), // ┽
        "\u{253E}": Info(left: true, right: true, up: true, down: true), // ┾
        "\u{253F}": Info(left: true, right: true, up: true, down: true), // ┿
        "\u{2540}": Info(left: true, right: true, up: true, down: true), // ╀
        "\u{2541}": Info(left: true, right: true, up: true, down: true), // ╁
        "\u{2542}": Info(left: true, right: true, up: true, down: true, heavy: true), // ╂
        "\u{2543}": Info(left: true, right: true, up: true, down: true), // ╃
        "\u{2544}": Info(left: true, right: true, up: true, down: true), // ╄
        "\u{2545}": Info(left: true, right: true, up: true, down: true), // ╅
        "\u{2546}": Info(left: true, right: true, up: true, down: true), // ╆
        "\u{2547}": Info(left: true, right: true, up: true, down: true), // ╇
        "\u{2548}": Info(left: true, right: true, up: true, down: true), // ╈
        "\u{2549}": Info(left: true, right: true, up: true, down: true), // ╉
        "\u{254A}": Info(left: true, right: true, up: true, down: true), // ╊
    ]
}

#endif
