import SwiftUI
#if os(macOS)
import AppKit
import CoreText
import Carbon.HIToolbox
import Metal
import QuartzCore
import SWUINeovim

struct EditorGridViewRepresentable: NSViewRepresentable {
    let controller: MacSessionController
    let snapshot: MacSessionController.GridSnapshot
    let fontName: String
    let fontSize: Double
    var metalEnabled: Bool = true

    func makeNSView(context: Context) -> EditorGridNSView {
        let view = EditorGridNSView()
        view.metalEnabled = metalEnabled
        view.setEditorFont(name: fontName, size: CGFloat(fontSize))
        view.update(with: snapshot)
        view.sendInput = { keys in
            controller.sendInput(keys)
        }
        view.sendMouseInput = { button, action, modifiers, row, col, gridID in
            controller.sendMouse(
                button: button,
                action: action,
                modifiers: modifiers,
                row: row,
                col: col,
                gridID: gridID
            )
        }
        view.requestResize = { cols, rows in
            controller.requestResize(cols: cols, rows: rows)
        }
        return view
    }

    func updateNSView(_ nsView: EditorGridNSView, context: Context) {
        nsView.metalEnabled = metalEnabled
        nsView.setEditorFont(name: fontName, size: CGFloat(fontSize))
        nsView.update(with: snapshot)
        nsView.sendInput = { keys in
            controller.sendInput(keys)
        }
        nsView.sendMouseInput = { button, action, modifiers, row, col, gridID in
            controller.sendMouse(
                button: button,
                action: action,
                modifiers: modifiers,
                row: row,
                col: col,
                gridID: gridID
            )
        }
        nsView.requestResize = { cols, rows in
            controller.requestResize(cols: cols, rows: rows)
        }
    }
}

final class EditorGridNSView: NSView {
    var sendInput: ((String) -> Void)?
    var sendMouseInput: ((String, String, String, Int, Int, Int) -> Void)?
    var requestResize: ((Int, Int) -> Void)?

    private var snapshot = MacSessionController.GridSnapshot(
        rows: 1,
        cols: 1,
        cells: [[GridCell()]],
        cursorRow: 0,
        cursorCol: 0,
        cursorGridID: 1,
        useIBeamCursor: false,
        layers: [],
        defaultForeground: 0xFFFFFF,
        defaultBackground: 0x000000,
        highlights: [:]
    )
    private var lastReportedCellSize: (cols: Int, rows: Int)?

    private var font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    private var renderFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    private var renderFontBold: NSFont = .monospacedSystemFont(ofSize: 14, weight: .bold)
    private var renderFontItalic: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    private var renderFontBoldItalic: NSFont = .monospacedSystemFont(ofSize: 14, weight: .bold)
    private var fallbackFontCandidates: [NSFont] = []
    private var attrs: [NSAttributedString.Key: Any] = [:]
    private var cursorBlinkTimer: Timer?
    private var cursorBlinkVisible = true
    private var windowBecameKeyObserver: NSObjectProtocol?
    private var windowResignedKeyObserver: NSObjectProtocol?
    private var trackingArea: NSTrackingArea?
    private var previousAcceptsMouseMovedEvents: Bool?
    private var lastHoveredCell: (row: Int, col: Int, gridID: Int)?

    // MARK: - Metal Rendering

    /// Whether the system has a Metal-capable GPU. Checked once at class load time.
    static let isMetalAvailable: Bool = MTLCreateSystemDefaultDevice() != nil

    /// Whether the Metal renderer is actually usable (GPU + shader pipeline).
    static let isMetalRendererAvailable: Bool = {
        guard isMetalAvailable, let atlas = MetalGlyphAtlas() else { return false }
        return atlas.canUseMetalRenderer
    }()

    /// Whether Metal rendering is enabled by user preference (default: true).
    var metalEnabled: Bool = true

    private var metalAtlas: MetalGlyphAtlas?
    private var metalLayer: CAMetalLayer?
    private var metalBenchmark = RenderBenchmark()
    private var coreTextBenchmark = RenderBenchmark()
    private var useMetalRenderer = false
#if DEBUG
    private static let resizeDebugEnabled = ProcessInfo.processInfo.environment["SWUINVIM_DEBUG_RESIZE"] == "1"
    private static let mouseDebugEnabled = ProcessInfo.processInfo.environment["SWUINVIM_DEBUG_MOUSE"] == "1"
#else
    private static let resizeDebugEnabled = false
    private static let mouseDebugEnabled = false
#endif

    private static func resizeDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        guard resizeDebugEnabled else { return }
        print("[ResizeDebug][NSView] \(message())")
#endif
    }

    private static func mouseDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        guard mouseDebugEnabled else { return }
        print("[MouseDebug] \(message())")
#endif
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        renderFont = font
        attrs = [.font: renderFont]
        refreshFallbackFontCandidates()
        setupMetal()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        renderFont = font
        attrs = [.font: renderFont]
        refreshFallbackFontCandidates()
        setupMetal()
    }

    // MARK: - Metal Setup

    private func setupMetal() {
        guard EditorGridNSView.isMetalAvailable else {
            NSLog("[EditorGridNSView] Metal renderer: DISABLED — no Metal-capable GPU detected, using CoreText renderer")
            return
        }
        guard let atlas = MetalGlyphAtlas() else {
            NSLog("[EditorGridNSView] Metal renderer: DISABLED — MetalGlyphAtlas init failed, using CoreText renderer")
            return
        }
        guard atlas.canUseMetalRenderer else {
            NSLog("[EditorGridNSView] Metal renderer: DISABLED — shader pipeline unavailable, using CoreText renderer")
            return
        }
        NSLog("[EditorGridNSView] Metal renderer: AVAILABLE — GPU: %@", atlas.device.name)

        self.metalAtlas = atlas

        let layer = CAMetalLayer()
        layer.device = atlas.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.isHidden = true

        self.wantsLayer = true
        self.layer?.addSublayer(layer)
        self.metalLayer = layer
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
        renderFontBold = makeCascadedRenderFont(base: styledVariant(of: font, traits: .bold))
        renderFontItalic = makeCascadedRenderFont(base: styledVariant(of: font, traits: .italic))
        renderFontBoldItalic = makeCascadedRenderFont(base: styledVariant(of: font, traits: [.bold, .italic]))
        attrs = [.font: renderFont]
        lastReportedCellSize = nil
        metalAtlas?.clearAtlas()
        metalAtlas?.measureCellSize(font: font as CTFont)
        needsDisplay = true
        emitResizeIfNeeded()
    }

    func update(with snapshot: MacSessionController.GridSnapshot) {
        self.snapshot = snapshot
        needsDisplay = true
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
        emitResizeIfNeeded()
    }

    override func layout() {
        super.layout()
        metalLayer?.frame = bounds
        emitResizeIfNeeded()
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea

        super.updateTrackingAreas()
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
        if let window, previousAcceptsMouseMovedEvents == nil {
            previousAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
        }
        registerWindowFocusObservers()
        updateCursorBlinkState()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            if let window, let previousAcceptsMouseMovedEvents {
                window.acceptsMouseMovedEvents = previousAcceptsMouseMovedEvents
            }
            previousAcceptsMouseMovedEvents = nil
            removeWindowFocusObservers()
            stopCursorBlinking()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        let cellSize = measureCell()

        // Use Metal when the user has it enabled and the hardware supports it.
        let useMetalForFrame = metalEnabled && (metalAtlas?.canUseMetalRenderer ?? false)

        if useMetalForFrame, let atlas = metalAtlas, let layer = metalLayer {
            drawWithMetal(atlas: atlas, layer: layer, cellSize: cellSize)
            useMetalRenderer = true

            // Draw cursor via CoreText on top of the Metal layer.
            if let cg = NSGraphicsContext.current?.cgContext {
                drawMultigridCursor(in: cg, cellSize: cellSize)
            }
        } else {
            // Hide metal layer when using CoreText
            metalLayer?.isHidden = true
            useMetalRenderer = false
            drawWithCoreText(dirtyRect: dirtyRect, cellSize: cellSize)
        }
    }

    // MARK: - CoreText Draw Path

    private func drawWithCoreText(dirtyRect: NSRect, cellSize: CGSize) {
        let startTime = CACurrentMediaTime()

        guard let cg = NSGraphicsContext.current?.cgContext else { return }

        let bg = nsColor(rgb: snapshot.defaultBackground)
        cg.setFillColor(bg.cgColor)
        cg.fill(bounds)

        // Draw base grid (grid 1)
        drawGridCoreText(
            cells: snapshot.cells,
            rows: snapshot.rows,
            cols: snapshot.cols,
            origin: .zero,
            cellSize: cellSize,
            in: cg
        )

        // Draw non-floating multigrid layers on top (editor panes, statusline, etc.)
        for layer in snapshot.layers where !layer.isFloating && layer.id != 1 {
            let origin = CGPoint(
                x: CGFloat(layer.originCol) * cellSize.width,
                y: CGFloat(layer.originRow) * cellSize.height
            )
            drawGridCoreText(
                cells: layer.cells,
                rows: layer.rows,
                cols: layer.cols,
                origin: origin,
                cellSize: cellSize,
                in: cg
            )
        }

        drawMultigridCursor(in: cg, cellSize: cellSize)

        coreTextBenchmark.record(CACurrentMediaTime() - startTime)
    }

    /// Draws a grid of cells at the given pixel origin using CoreText.
    private func drawGridCoreText(
        cells: [[GridCell]],
        rows: Int,
        cols: Int,
        origin: CGPoint,
        cellSize: CGSize,
        in cg: CGContext
    ) {
        let textYOffset = max(0, floor((cellSize.height - font.boundingRectForFont.height) / 2.0))

        // 1) Draw cell backgrounds by highlight runs.
        for row in 0..<rows {
            var col = 0
            while col < cols {
                let cell = cells[row][col]
                let runBackground = backgroundColor(for: cell.highlightID)
                let start = col
                col += 1

                while col < cols {
                    let next = cells[row][col]
                    if backgroundColor(for: next.highlightID) != runBackground { break }
                    col += 1
                }

                let rect = CGRect(
                    x: origin.x + CGFloat(start) * cellSize.width,
                    y: origin.y + CGFloat(row) * cellSize.height,
                    width: CGFloat(col - start) * cellSize.width,
                    height: cellSize.height
                )
                cg.setFillColor(runBackground.cgColor)
                cg.fill(rect)
            }
        }

        // 2) Draw text per cell.
        for row in 0..<rows {
            for col in 0..<cols {
                let cell = cells[row][col]
                guard !cell.text.isEmpty, cell.text != " " else { continue }
                if BoxDrawing.info(for: cell.text) != nil { continue }
                let fg = foregroundColor(for: cell.highlightID)
                let hlAttrs = snapshot.highlights[cell.highlightID]
                let bold = hlAttrs?.bold ?? false
                let italic = hlAttrs?.italic ?? false
                let drawFont: NSFont
                switch (bold, italic) {
                case (true, true):  drawFont = renderFontBoldItalic
                case (true, false): drawFont = renderFontBold
                case (false, true): drawFont = renderFontItalic
                default:            drawFont = renderFont
                }

                let cellRect = CGRect(
                    x: origin.x + CGFloat(col) * cellSize.width,
                    y: origin.y + CGFloat(row) * cellSize.height,
                    width: cellSize.width,
                    height: cellSize.height
                )
                let point = CGPoint(
                    x: cellRect.origin.x,
                    y: cellRect.origin.y + textYOffset
                )

                cg.saveGState()
                cg.clip(to: cellRect)
                (cell.text as NSString).draw(
                    at: point,
                    withAttributes: [
                        .font: drawFont,
                        .foregroundColor: fg,
                    ]
                )
                cg.restoreGState()
            }
        }

        // 3) Owner-draw box-drawing characters.
        drawBoxDrawingCharactersInGrid(cells: cells, rows: rows, cols: cols, origin: origin, cellSize: cellSize, in: cg)
    }

    // MARK: - Metal Draw Path

    private func drawWithMetal(atlas: MetalGlyphAtlas, layer: CAMetalLayer, cellSize: CGSize) {
        let startTime = CACurrentMediaTime()

        // Update layer size to match view
        let scale = window?.backingScaleFactor ?? 2.0
        let drawableSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        layer.frame = bounds
        layer.drawableSize = drawableSize
        layer.contentsScale = scale
        layer.isHidden = false

        // Update atlas cell metrics
        atlas.measureCellSize(font: font as CTFont)

        // Rasterise all visible glyphs and build instance buffer
        let instances = buildMetalInstances(atlas: atlas, cellSize: cellSize)

        guard let drawable = layer.nextDrawable() else { return }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear

        // Clear to default background
        let bgR = Float((snapshot.defaultBackground >> 16) & 0xFF) / 255.0
        let bgG = Float((snapshot.defaultBackground >> 8) & 0xFF) / 255.0
        let bgB = Float(snapshot.defaultBackground & 0xFF) / 255.0
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bgR), green: Double(bgG), blue: Double(bgB), alpha: 1.0
        )
        passDescriptor.colorAttachments[0].storeAction = .store

        guard let commandBuffer = atlas.commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }

        atlas.draw(
            instances: instances,
            viewportSize: SIMD2<Float>(Float(bounds.width), Float(bounds.height)),
            renderEncoder: encoder
        )

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        metalBenchmark.record(CACurrentMediaTime() - startTime)
    }

    private func buildMetalInstances(atlas: MetalGlyphAtlas, cellSize: CGSize) -> [CellInstance] {
        var flatCells: [(glyph: GlyphKey, fg: (Float, Float, Float, Float), bg: (Float, Float, Float, Float))] = []

        // Helper to append cells for a grid at a col/row origin offset
        func appendGrid(cells: [[GridCell]], rows: Int, cols: Int, originCol: Double, originRow: Double) {
            for row in 0..<rows {
                for col in 0..<cols {
                    let cell = cells[row][col]
                    let hlAttrs = snapshot.highlights[cell.highlightID]

                    let fgRGB: UInt32
                    let bgRGB: UInt32
                    if hlAttrs?.reverse == true {
                        fgRGB = hlAttrs?.background ?? snapshot.defaultBackground
                        bgRGB = hlAttrs?.foreground ?? snapshot.defaultForeground
                    } else {
                        fgRGB = hlAttrs?.foreground ?? snapshot.defaultForeground
                        bgRGB = hlAttrs?.background ?? snapshot.defaultBackground
                    }

                    let fg = rgbToFloats(fgRGB)
                    let bg = rgbToFloats(bgRGB, alpha: blendAlpha(for: hlAttrs))

                    let text = cell.text
                    let glyphKey: GlyphKey
                    if text.isEmpty || text == " " || cell.isDoubleWidthContinuation {
                        glyphKey = GlyphKey(characters: "", bold: false, italic: false, fontSize: font.pointSize)
                    } else {
                        let bold = hlAttrs?.bold ?? false
                        let italic = hlAttrs?.italic ?? false
                        glyphKey = GlyphKey(characters: text, bold: bold, italic: italic, fontSize: font.pointSize)

                        let ctFont: CTFont
                        switch (bold, italic) {
                        case (true, true):  ctFont = renderFontBoldItalic as CTFont
                        case (true, false): ctFont = renderFontBold as CTFont
                        case (false, true): ctFont = renderFontItalic as CTFont
                        default:            ctFont = renderFont as CTFont
                        }
                        atlas.rasterise(glyphKey, font: ctFont)
                    }

                    flatCells.append((glyph: glyphKey, fg: fg, bg: bg))
                }
            }
        }

        // Base grid (grid 1) at origin (0,0)
        appendGrid(cells: snapshot.cells, rows: snapshot.rows, cols: snapshot.cols, originCol: 0, originRow: 0)

        // Build base grid instances
        var instances = atlas.buildInstanceBuffer(
            cells: flatCells,
            columns: snapshot.cols,
            rows: snapshot.rows
        )

        // Non-floating multigrid layers drawn on top at their grid origins
        for layer in snapshot.layers where !layer.isFloating && layer.id != 1 {
            flatCells.removeAll(keepingCapacity: true)
            appendGrid(cells: layer.cells, rows: layer.rows, cols: layer.cols, originCol: layer.originCol, originRow: layer.originRow)

            let layerInstances = atlas.buildInstanceBuffer(
                cells: flatCells,
                columns: layer.cols,
                rows: layer.rows
            )

            // Offset gridX/gridY to the layer's origin position
            let colOffset = UInt16(max(0, Int(layer.originCol)))
            let rowOffset = UInt16(max(0, Int(layer.originRow)))
            for var inst in layerInstances {
                inst.gridX += colOffset
                inst.gridY += rowOffset
                instances.append(inst)
            }
        }

        return instances
    }

    private func rgbToFloats(_ rgb: UInt32, alpha: Float = 1.0) -> (Float, Float, Float, Float) {
        let r = Float((rgb >> 16) & 0xFF) / 255.0
        let g = Float((rgb >> 8) & 0xFF) / 255.0
        let b = Float(rgb & 0xFF) / 255.0
        return (r, g, b, alpha)
    }

    private func blendAlpha(for style: RawHighlightAttrs?) -> Float {
        guard let blend = style?.blend else { return 1.0 }
        let clamped = min(max(blend, 0), 100)
        return Float(100 - clamped) / 100.0
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

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        sendMouseMoveEvent(location: location, flags: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        lastHoveredCell = nil
        super.mouseExited(with: event)
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

    private func drawMultigridCursor(in cg: CGContext, cellSize: CGSize) {
        if shouldBlinkCursor && !cursorBlinkVisible {
            return
        }

        // Find the layer the cursor is on (non-floating layers rendered in the NSView).
        // If on a floating layer or if cursor grid matches no non-floating layer,
        // the SwiftUI overlay handles it.
        let cursorOrigin: CGPoint
        if snapshot.drawBaseCursor {
            // No multigrid layers — cursor is on grid 1
            cursorOrigin = .zero
        } else if let layer = snapshot.layers.first(where: { $0.id == snapshot.cursorGridID && !$0.isFloating }) {
            cursorOrigin = CGPoint(
                x: CGFloat(layer.originCol) * cellSize.width,
                y: CGFloat(layer.originRow) * cellSize.height
            )
        } else {
            // Cursor is on a floating layer — SwiftUI overlay draws it
            return
        }

        let rect = CGRect(
            x: cursorOrigin.x + CGFloat(snapshot.cursorCol) * cellSize.width,
            y: cursorOrigin.y + CGFloat(snapshot.cursorRow) * cellSize.height,
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
                    lower.contains("symbols") ||
                    lower.contains("awesome")
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
        if lower.contains("awesome") { return 4 }
        return 10
    }

    private func styledVariant(of base: NSFont, traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
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

        let previous = lastReportedCellSize.map { "\($0.cols)x\($0.rows)" } ?? "nil"
        let cellWidth = String(format: "%.2f", cell.width)
        let cellHeight = String(format: "%.2f", cell.height)
        Self.resizeDebugLog("[NSView] bounds=\(Int(bounds.width))x\(Int(bounds.height)) cell=\(cellWidth)x\(cellHeight) reported=\(cols)x\(rows) previous=\(previous)")

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
        Self.mouseDebugLog("[NSView] action=\(button):\(action) point=\(Int(location.x)),\(Int(location.y)) grid=\(cell.gridID) row=\(cell.row) col=\(cell.col) mods=\(modifiers)")
        sendMouseInput?(button, action, modifiers, cell.row, cell.col, cell.gridID)
    }

    private func sendMouseMoveEvent(location: CGPoint, flags: NSEvent.ModifierFlags) {
        guard let cell = cellCoordinates(at: location) else {
            lastHoveredCell = nil
            return
        }

        if let lastHoveredCell,
           lastHoveredCell.row == cell.row,
           lastHoveredCell.col == cell.col,
           lastHoveredCell.gridID == cell.gridID {
            return
        }

        lastHoveredCell = cell
        let modifiers = mouseModifierString(flags: flags)
        Self.mouseDebugLog("[NSView] action=move point=\(Int(location.x)),\(Int(location.y)) grid=\(cell.gridID) row=\(cell.row) col=\(cell.col) mods=\(modifiers)")
        sendMouseInput?("move", "", modifiers, cell.row, cell.col, cell.gridID)
    }

    private func cellCoordinates(at location: CGPoint) -> (row: Int, col: Int, gridID: Int)? {
        let cell = measureCell()
        guard cell.width > 0, cell.height > 0 else { return nil }

        for layer in snapshot.layers.sorted(by: { lhs, rhs in
            if lhs.isFloating != rhs.isFloating {
                return lhs.isFloating && !rhs.isFloating
            }
            if lhs.zIndex != rhs.zIndex {
                return lhs.zIndex > rhs.zIndex
            }
            return lhs.id > rhs.id
        }) {
            let minX = CGFloat(layer.originCol) * cell.width
            let minY = CGFloat(layer.originRow) * cell.height
            let rect = CGRect(
                x: minX,
                y: minY,
                width: CGFloat(layer.cols) * cell.width,
                height: CGFloat(layer.rows) * cell.height
            )
            guard rect.contains(location) else { continue }
            if layer.isFloating && !layer.mouseEnabled {
                Self.mouseDebugLog("[HitTest] skipping non-mouse layer=\(layer.id) z=\(layer.zIndex)")
                continue
            }

            let col = Int(floor((location.x - rect.minX) / cell.width))
            let row = Int(floor((location.y - rect.minY) / cell.height))
            guard row >= 0, col >= 0 else { continue }
            Self.mouseDebugLog("[HitTest] layer=\(layer.id) floating=\(layer.isFloating) mouseEnabled=\(layer.mouseEnabled) z=\(layer.zIndex) rect=(\(Int(rect.minX)),\(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height)) point=\(Int(location.x)),\(Int(location.y)) local=\(row),\(col)")
            return (
                row: min(max(0, row), max(0, layer.rows - 1)),
                col: min(max(0, col), max(0, layer.cols - 1)),
                gridID: layer.id
            )
        }

        let col = Int(floor(location.x / cell.width))
        let row = Int(floor(location.y / cell.height))
        guard row >= 0, col >= 0 else { return nil }
        Self.mouseDebugLog("[HitTest] root point=\(Int(location.x)),\(Int(location.y)) local=\(row),\(col)")
        return (
            row: min(max(0, row), max(0, snapshot.rows - 1)),
            col: min(max(0, col), max(0, snapshot.cols - 1)),
            gridID: 0
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
            let alpha = CGFloat(blendAlpha(for: style))
            if style.reverse {
                let effectiveFG = style.foreground ?? snapshot.defaultForeground
                return nsColor(rgb: effectiveFG, alpha: alpha)
            }
            if let bg = style.background {
                return nsColor(rgb: bg, alpha: alpha)
            }
        }
        return nsColor(rgb: snapshot.defaultBackground)
    }

    private func nsColor(rgb: UInt32, alpha: CGFloat = 1.0) -> NSColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        return NSColor(red: r, green: g, blue: b, alpha: alpha)
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

    private func drawBoxDrawingCharactersInGrid(
        cells: [[GridCell]],
        rows: Int,
        cols: Int,
        origin: CGPoint,
        cellSize: CGSize,
        in cg: CGContext
    ) {
        let lineWidth: CGFloat = 1.0
        let heavyLineWidth: CGFloat = 2.0

        for row in 0..<rows {
            for col in 0..<cols {
                let cell = cells[row][col]
                guard let info = BoxDrawing.info(for: cell.text) else { continue }

                let fg = foregroundColor(for: cell.highlightID)
                let cellRect = CGRect(
                    x: origin.x + CGFloat(col) * cellSize.width,
                    y: origin.y + CGFloat(row) * cellSize.height,
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
                } else if info.dashed {
                    let dashLen: CGFloat = cellSize.width * 0.2
                    cg.setLineDash(phase: 0, lengths: [dashLen, dashLen])
                    drawStraightSegments(info: info, in: cg, cellRect: cellRect, cx: cx, cy: cy)
                    cg.setLineDash(phase: 0, lengths: [])
                } else if info.double {
                    let offset: CGFloat = 2.0
                    cg.setLineWidth(lineWidth)
                    if info.left || info.right {
                        if info.left {
                            cg.move(to: CGPoint(x: cellRect.minX, y: cy - offset))
                            cg.addLine(to: CGPoint(x: info.right ? cellRect.maxX : cx, y: cy - offset))
                            cg.strokePath()
                            cg.move(to: CGPoint(x: cellRect.minX, y: cy + offset))
                            cg.addLine(to: CGPoint(x: info.right ? cellRect.maxX : cx, y: cy + offset))
                            cg.strokePath()
                        }
                        if info.right && !info.left {
                            cg.move(to: CGPoint(x: cx, y: cy - offset))
                            cg.addLine(to: CGPoint(x: cellRect.maxX, y: cy - offset))
                            cg.strokePath()
                            cg.move(to: CGPoint(x: cx, y: cy + offset))
                            cg.addLine(to: CGPoint(x: cellRect.maxX, y: cy + offset))
                            cg.strokePath()
                        }
                    }
                    if info.up || info.down {
                        if info.up {
                            cg.move(to: CGPoint(x: cx - offset, y: cellRect.minY))
                            cg.addLine(to: CGPoint(x: cx - offset, y: info.down ? cellRect.maxY : cy))
                            cg.strokePath()
                            cg.move(to: CGPoint(x: cx + offset, y: cellRect.minY))
                            cg.addLine(to: CGPoint(x: cx + offset, y: info.down ? cellRect.maxY : cy))
                            cg.strokePath()
                        }
                        if info.down && !info.up {
                            cg.move(to: CGPoint(x: cx - offset, y: cy))
                            cg.addLine(to: CGPoint(x: cx - offset, y: cellRect.maxY))
                            cg.strokePath()
                            cg.move(to: CGPoint(x: cx + offset, y: cy))
                            cg.addLine(to: CGPoint(x: cx + offset, y: cellRect.maxY))
                            cg.strokePath()
                        }
                    }
                } else {
                    drawStraightSegments(info: info, in: cg, cellRect: cellRect, cx: cx, cy: cy)
                }

                cg.restoreGState()
            }
        }
    }

    private func drawStraightSegments(
        info: BoxDrawing.Info,
        in cg: CGContext,
        cellRect: CGRect,
        cx: CGFloat,
        cy: CGFloat
    ) {
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

    private func drawRoundedCorner(
        info: BoxDrawing.Info,
        in cg: CGContext,
        cellRect: CGRect,
        cx: CGFloat,
        cy: CGFloat
    ) {
        let halfW = cellRect.width / 2
        let halfH = cellRect.height / 2
        let radius = min(halfW, halfH)

        if info.right && info.down {
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

    // MARK: - Benchmark Stats

    /// Returns benchmark stats for the currently active renderer.
    var renderStats: (renderer: String, avgMs: Double, p95Ms: Double, samples: Int) {
        if useMetalRenderer {
            return ("Metal", metalBenchmark.averageMs, metalBenchmark.p95Ms, metalBenchmark.sampleCount)
        } else {
            return ("CoreText", coreTextBenchmark.averageMs, coreTextBenchmark.p95Ms, coreTextBenchmark.sampleCount)
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

enum BoxDrawing {

    struct Info {
        let left: Bool
        let right: Bool
        let up: Bool
        let down: Bool
        let rounded: Bool
        let heavy: Bool
        let double: Bool
        let dashed: Bool

        init(
            left: Bool = false, right: Bool = false,
            up: Bool = false, down: Bool = false,
            rounded: Bool = false, heavy: Bool = false,
            double: Bool = false, dashed: Bool = false
        ) {
            self.left = left; self.right = right
            self.up = up; self.down = down
            self.rounded = rounded; self.heavy = heavy
            self.double = double; self.dashed = dashed
        }
    }

    static func info(for text: String) -> Info? {
        guard let scalar = text.unicodeScalars.first,
              text.unicodeScalars.count == 1 else { return nil }
        return table[scalar]
    }

    private static let h   = Info(left: true, right: true)
    private static let v   = Info(up: true, down: true)
    private static let dr  = Info(right: true, down: true)
    private static let dl  = Info(left: true, down: true)
    private static let ur  = Info(right: true, up: true)
    private static let ul  = Info(left: true, up: true)
    private static let vr  = Info(right: true, up: true, down: true)
    private static let vl  = Info(left: true, up: true, down: true)
    private static let dh  = Info(left: true, right: true, down: true)
    private static let uh  = Info(left: true, right: true, up: true)
    private static let vh  = Info(left: true, right: true, up: true, down: true)
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
    private static let hD  = Info(left: true, right: true, double: true)
    private static let vD  = Info(up: true, down: true, double: true)
    private static let rDR = Info(right: true, down: true, rounded: true)
    private static let rDL = Info(left: true, down: true, rounded: true)
    private static let rUL = Info(left: true, up: true, rounded: true)
    private static let rUR = Info(right: true, up: true, rounded: true)
    private static let hDash = Info(left: true, right: true, dashed: true)
    private static let vDash = Info(up: true, down: true, dashed: true)
    private static let hDashH = Info(left: true, right: true, heavy: true, dashed: true)
    private static let vDashH = Info(up: true, down: true, heavy: true, dashed: true)

    private static let table: [Unicode.Scalar: Info] = [
        "\u{2500}": h, "\u{2502}": v, "\u{250C}": dr, "\u{2510}": dl,
        "\u{2514}": ur, "\u{2518}": ul, "\u{251C}": vr, "\u{2524}": vl,
        "\u{252C}": dh, "\u{2534}": uh, "\u{253C}": vh,
        "\u{2501}": hH, "\u{2503}": vH, "\u{250F}": drH, "\u{2513}": dlH,
        "\u{2517}": urH, "\u{251B}": ulH, "\u{2523}": vrH, "\u{252B}": vlH,
        "\u{2533}": dhH, "\u{253B}": uhH, "\u{254B}": vhH,
        "\u{2550}": hD, "\u{2551}": vD,
        "\u{256D}": rDR, "\u{256E}": rDL, "\u{256F}": rUL, "\u{2570}": rUR,
        "\u{2504}": hDash, "\u{2505}": hDashH, "\u{2506}": vDash, "\u{2507}": vDashH,
        "\u{2508}": hDash, "\u{2509}": hDashH, "\u{250A}": vDash, "\u{250B}": vDashH,
        "\u{250D}": Info(right: true, down: true), "\u{250E}": Info(right: true, down: true),
        "\u{2511}": Info(left: true, down: true), "\u{2512}": Info(left: true, down: true),
        "\u{2515}": Info(right: true, up: true), "\u{2516}": Info(right: true, up: true),
        "\u{2519}": Info(left: true, up: true), "\u{251A}": Info(left: true, up: true),
        "\u{251D}": Info(right: true, up: true, down: true),
        "\u{251E}": Info(right: true, up: true, down: true),
        "\u{251F}": Info(right: true, up: true, down: true),
        "\u{2520}": Info(right: true, up: true, down: true, heavy: true),
        "\u{2521}": Info(right: true, up: true, down: true),
        "\u{2522}": Info(right: true, up: true, down: true),
        "\u{2525}": Info(left: true, up: true, down: true),
        "\u{2526}": Info(left: true, up: true, down: true),
        "\u{2527}": Info(left: true, up: true, down: true),
        "\u{2528}": Info(left: true, up: true, down: true, heavy: true),
        "\u{2529}": Info(left: true, up: true, down: true),
        "\u{252A}": Info(left: true, up: true, down: true),
        "\u{252D}": Info(left: true, right: true, down: true),
        "\u{252E}": Info(left: true, right: true, down: true),
        "\u{252F}": Info(left: true, right: true, down: true),
        "\u{2530}": Info(left: true, right: true, down: true),
        "\u{2531}": Info(left: true, right: true, down: true),
        "\u{2532}": Info(left: true, right: true, down: true),
        "\u{2535}": Info(left: true, right: true, up: true),
        "\u{2536}": Info(left: true, right: true, up: true),
        "\u{2537}": Info(left: true, right: true, up: true),
        "\u{2538}": Info(left: true, right: true, up: true),
        "\u{2539}": Info(left: true, right: true, up: true),
        "\u{253A}": Info(left: true, right: true, up: true),
        "\u{253D}": Info(left: true, right: true, up: true, down: true),
        "\u{253E}": Info(left: true, right: true, up: true, down: true),
        "\u{253F}": Info(left: true, right: true, up: true, down: true),
        "\u{2540}": Info(left: true, right: true, up: true, down: true),
        "\u{2541}": Info(left: true, right: true, up: true, down: true),
        "\u{2542}": Info(left: true, right: true, up: true, down: true, heavy: true),
        "\u{2543}": Info(left: true, right: true, up: true, down: true),
        "\u{2544}": Info(left: true, right: true, up: true, down: true),
        "\u{2545}": Info(left: true, right: true, up: true, down: true),
        "\u{2546}": Info(left: true, right: true, up: true, down: true),
        "\u{2547}": Info(left: true, right: true, up: true, down: true),
        "\u{2548}": Info(left: true, right: true, up: true, down: true),
        "\u{2549}": Info(left: true, right: true, up: true, down: true),
        "\u{254A}": Info(left: true, right: true, up: true, down: true),
    ]
}

#endif
