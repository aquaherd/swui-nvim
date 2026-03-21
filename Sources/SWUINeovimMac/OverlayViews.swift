// OverlayViews.swift
// SWUINeovimMac
//
// SwiftUI overlay views for popup menu, command line, and messages.
// These render over the EditorGridNSView when Neovim sends ext_popupmenu,
// ext_cmdline, and ext_messages events.

import SwiftUI
import SWUINeovim
#if os(macOS)
import AppKit
import CoreText

// MARK: - Cell Size Helper

/// Computes the monospace cell size for a given font name and size,
/// using the same measurement logic as EditorGridNSView.
func computeCellSize(fontName: String, fontSize: CGFloat) -> CGSize {
    let font = NSFont(name: fontName, size: max(8, fontSize))
        ?? NSFont.monospacedSystemFont(ofSize: max(8, fontSize), weight: .regular)

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

// MARK: - Color Helpers

private func color(rgb: UInt32, opacity: Double = 1.0) -> Color {
    Color(
        red: Double((rgb >> 16) & 0xFF) / 255.0,
        green: Double((rgb >> 8) & 0xFF) / 255.0,
        blue: Double(rgb & 0xFF) / 255.0
    )
    .opacity(opacity)
}

private func blendOpacity(_ attrs: RawHighlightAttrs?) -> Double {
    guard let blend = attrs?.blend else { return 1.0 }
    let clamped = min(max(blend, 0), 100)
    return Double(100 - clamped) / 100.0
}

private func overlayFont(
    name: String? = nil,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    italic: Bool = false
) -> Font {
    let resolvedSize = max(8, size)
    var base = name.flatMap { NSFont(name: $0, size: resolvedSize) }
        ?? NSFont.monospacedSystemFont(ofSize: resolvedSize, weight: weight)

    let descriptor = base.fontDescriptor.withSymbolicTraits(symbolicTraits(weight: weight, italic: italic))
    if let styled = NSFont(descriptor: descriptor, size: resolvedSize) {
        base = styled
    }

    return Font(GlyphFallbackFonts.cascadedPlatformFont(base: base))
}

private func symbolicTraits(weight: NSFont.Weight, italic: Bool) -> NSFontDescriptor.SymbolicTraits {
    var traits: NSFontDescriptor.SymbolicTraits = []
    if weight >= .semibold {
        traits.insert(.bold)
    }
    if italic {
        traits.insert(.italic)
    }
    return traits
}

// MARK: - PopupMenuOverlayView

/// Displays the Neovim completion popup menu as a floating overlay.
struct PopupMenuOverlayView: View {
    let state: PopupMenuState
    let cellSize: CGSize
    let defaultFG: UInt32
    let defaultBG: UInt32
    var gridOrigins: [Int: CGPoint] = [:]
    var preferBottomAnchor: Bool = false

    /// Send input keys back to Neovim (for selecting items).
    var onSelect: ((Int) -> Void)?

    private let maxVisibleItems = 12
    private let itemHeight: CGFloat = 22
    private let maxWidth: CGFloat = 400

    var body: some View {
        if state.isVisible && !state.items.isEmpty {
            GeometryReader { geometry in
                let position = computePosition(in: geometry.size)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(state.items) { item in
                                popupItemRow(item: item, isSelected: item.id == state.selectedIndex)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        onSelect?(item.id)
                                    }
                            }
                        }
                    }
                    .onChange(of: state.selectedIndex) { _, newIndex in
                        if newIndex >= 0 && newIndex < state.items.count {
                            withAnimation(.easeInOut(duration: 0.08)) {
                                proxy.scrollTo(newIndex, anchor: .center)
                            }
                        }
                    }
                }
                .frame(maxWidth: maxWidth)
                .frame(height: menuHeight)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.ultraThickMaterial)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
                .position(x: position.x, y: position.y)
            }
            .allowsHitTesting(true)
        }
    }

    private var menuHeight: CGFloat {
        let count = min(state.items.count, maxVisibleItems)
        return CGFloat(count) * itemHeight + 8 // 4pt padding top + bottom
    }

    private func computePosition(in containerSize: CGSize) -> CGPoint {
        if preferBottomAnchor && state.row == 0 && state.col == 0 {
            let width = min(maxWidth, containerSize.width * 0.6)
            let height = menuHeight
            return CGPoint(
                x: width / 2 + 12,
                y: max(height / 2 + 12, containerSize.height - height / 2 - 56)
            )
        }

        let gridOrigin = gridOrigins[state.gridID] ?? .zero
        let anchorX = gridOrigin.x * cellSize.width + CGFloat(state.col) * cellSize.width
        let anchorY = gridOrigin.y * cellSize.height + CGFloat(state.row + 1) * cellSize.height // below the cursor row

        let width = min(maxWidth, containerSize.width * 0.6)
        let height = menuHeight

        var x = anchorX + width / 2
        var y = anchorY + height / 2

        // Keep within bounds
        if x + width / 2 > containerSize.width {
            x = containerSize.width - width / 2 - 4
        }
        if x - width / 2 < 0 {
            x = width / 2 + 4
        }
        // If popup would go below the view, show it above the cursor
        if y + height / 2 > containerSize.height {
            y = gridOrigin.y * cellSize.height + CGFloat(state.row) * cellSize.height - height / 2
        }

        return CGPoint(x: x, y: y)
    }

    @ViewBuilder
    private func popupItemRow(item: PopupMenuItem, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            // Kind indicator
            if !item.kind.isEmpty {
                Text(item.kind)
                    .font(overlayFont(size: 10, weight: .semibold))
                    .foregroundStyle(kindColor(item.kind))
                    .frame(width: 20, alignment: .center)
            }

            // Word
            Text(item.word)
                .font(overlayFont(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            // Menu detail (right-aligned, dimmed)
            if !item.menu.isEmpty {
                Text(item.menu)
                    .font(overlayFont(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: itemHeight)
        .background(isSelected ? Color.accentColor : Color.clear)
    }

    private func kindColor(_ kind: String) -> Color {
        switch kind.lowercased() {
        case "function", "f": return .blue
        case "variable", "v": return .cyan
        case "class", "c": return .purple
        case "module", "m": return .orange
        case "keyword", "k": return .pink
        case "snippet", "s": return .green
        case "text", "t": return .secondary
        default: return .secondary
        }
    }
}

// MARK: - MultigridOverlayView

struct MultigridOverlayView: View {
    let snapshot: MacSessionController.GridSnapshot
    let cellSize: CGSize
    let fontName: String
    let fontSize: Double

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                ForEach(snapshot.layers) { layer in
                    if layer.id != 1 && layer.isFloating {
                        MultigridLayerView(
                            layer: layer,
                            editorRows: snapshot.rows,
                            editorCols: snapshot.cols,
                            defaultFG: snapshot.defaultForeground,
                            defaultBG: snapshot.defaultBackground,
                            highlightTable: snapshot.highlights,
                            fontName: fontName,
                            fontSize: fontSize,
                            cellSize: cellSize
                        )
                        .frame(
                            width: CGFloat(layer.cols) * cellSize.width,
                            height: CGFloat(layer.rows) * cellSize.height,
                            alignment: .topLeading
                        )
                        .offset(
                            x: CGFloat(layer.originCol) * cellSize.width,
                            y: CGFloat(layer.originRow) * cellSize.height
                        )
                    }
                }

                if let cursorLayer = cursorLayer {
                    cursorOverlay(in: cursorLayer)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    private var cursorLayer: MacSessionController.GridSnapshot.Layer? {
        // Only draw cursor in overlay if it's on a floating layer
        snapshot.layers.first(where: { $0.id == snapshot.cursorGridID && $0.isFloating })
    }

    @ViewBuilder
    private func cursorOverlay(in layer: MacSessionController.GridSnapshot.Layer) -> some View {
        let rect = CGRect(
            x: (CGFloat(layer.originCol) + CGFloat(snapshot.cursorCol)) * cellSize.width,
            y: (CGFloat(layer.originRow) + CGFloat(snapshot.cursorRow)) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        )

        if snapshot.useIBeamCursor {
            Rectangle()
                .fill(Color(red: 0x7A / 255.0, green: 0xA2 / 255.0, blue: 0xF7 / 255.0))
                .frame(width: 2, height: max(1, rect.height - 2))
                .offset(x: rect.minX + 1, y: rect.minY + 1)
        } else {
            Rectangle()
                .fill(Color(red: 0x7A / 255.0, green: 0xA2 / 255.0, blue: 0xF7 / 255.0).opacity(0.45))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }
}

private struct MultigridLayerView: View {
    let layer: MacSessionController.GridSnapshot.Layer
    let editorRows: Int
    let editorCols: Int
    let defaultFG: UInt32
    let defaultBG: UInt32
    let highlightTable: [Int: RawHighlightAttrs]
    let fontName: String
    let fontSize: Double
    let cellSize: CGSize

    var body: some View {
        if isBackdropWindow {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.75)

                Rectangle()
                    .fill(backdropTint)
            }
        } else if layer.isFloating {
            let content = VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<layer.rows, id: \.self) { row in
                    MultigridRowView(
                        cells: layer.cells[row],
                        defaultFG: defaultFG,
                        defaultBG: defaultBG,
                        highlightTable: highlightTable,
                        fontName: fontName,
                        fontSize: fontSize,
                        cellSize: cellSize
                    )
                }
            }

            content
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        } else {
            let content = VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<layer.rows, id: \.self) { row in
                    MultigridRowView(
                        cells: layer.cells[row],
                        defaultFG: defaultFG,
                        defaultBG: defaultBG,
                        highlightTable: highlightTable,
                        fontName: fontName,
                        fontSize: fontSize,
                        cellSize: cellSize
                    )
                }
            }

            content
        }
    }

    private var isBackdropWindow: Bool {
        layer.isFloating
            && !layer.mouseEnabled
            && layer.originRow == 0
            && layer.originCol == 0
            && Double(layer.cols) >= Double(editorCols) * 0.6
            && Double(layer.rows) >= Double(editorRows) * 0.6
    }

    private var backdropColor: Color {
        let alpha = dominantBlend > 0 ? Double(100 - dominantBlend) / 100.0 : 0.35
        return color(rgb: dominantBackground, opacity: alpha)
    }

    private var backdropTint: Color {
        let alpha = dominantBlend > 0 ? Double(100 - dominantBlend) / 200.0 : 0.18
        return color(rgb: dominantBackground, opacity: alpha)
    }

    private var dominantBackground: UInt32 {
        var counts: [UInt32: Int] = [:]
        var winner = defaultBG
        for row in layer.cells {
            for cell in row {
                let bg = highlightTable[cell.highlightID]?.background ?? defaultBG
                counts[bg, default: 0] += 1
                if counts[bg, default: 0] > counts[winner, default: 0] {
                    winner = bg
                }
            }
        }
        return winner
    }

    private var dominantBlend: Int {
        var winner = 0
        for row in layer.cells {
            for cell in row {
                winner = max(winner, min(max(highlightTable[cell.highlightID]?.blend ?? 0, 0), 100))
            }
        }
        return winner
    }
}

private struct MultigridRowView: View {
    let cells: [GridCell]
    let defaultFG: UInt32
    let defaultBG: UInt32
    let highlightTable: [Int: RawHighlightAttrs]
    let fontName: String
    let fontSize: Double
    let cellSize: CGSize

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(textRuns.enumerated()), id: \.offset) { _, run in
                Text(run.text)
                    .font(overlayFont(
                        name: fontName,
                        size: fontSize,
                        weight: run.bold ? .bold : .regular,
                        italic: run.italic
                    ))
                    .foregroundStyle(run.foreground)
                    .frame(width: CGFloat(run.cellCount) * cellSize.width, height: cellSize.height, alignment: .leading)
                    .background(run.background)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var textRuns: [MultigridTextRun] {
        guard !cells.isEmpty else { return [] }

        var runs: [MultigridTextRun] = []
        var currentText = ""
        var currentHL = cells[0].highlightID
        var currentCount = 0

        for cell in cells {
            if cell.highlightID == currentHL {
                currentText += cell.text
                currentCount += 1
            } else {
                if !currentText.isEmpty {
                    runs.append(makeRun(text: currentText, hlID: currentHL, cellCount: currentCount))
                }
                currentText = cell.text
                currentHL = cell.highlightID
                currentCount = 1
            }
        }

        if !currentText.isEmpty {
            runs.append(makeRun(text: currentText, hlID: currentHL, cellCount: currentCount))
        }

        return runs
    }

    private func makeRun(text: String, hlID: Int, cellCount: Int) -> MultigridTextRun {
        let attrs = highlightTable[hlID]
        var fg = color(rgb: attrs?.foreground ?? defaultFG)
        var bg = color(rgb: attrs?.background ?? defaultBG, opacity: blendOpacity(attrs))

        if attrs?.reverse == true {
            swap(&fg, &bg)
        }

        return MultigridTextRun(
            text: text,
            cellCount: cellCount,
            foreground: fg,
            background: bg,
            bold: attrs?.bold ?? false,
            italic: attrs?.italic ?? false
        )
    }
}

private struct MultigridTextRun {
    let text: String
    let cellCount: Int
    let foreground: Color
    let background: Color
    let bold: Bool
    let italic: Bool
}

// MARK: - CmdlineOverlayView

/// Displays the Neovim command line as a bar at the bottom of the editor.
struct CmdlineOverlayView: View {
    let state: CmdlineState
    let defaultFG: UInt32
    let defaultBG: UInt32

    @State private var cursorVisible: Bool = true

    var body: some View {
        if state.isVisible {
            HStack(spacing: 0) {
                // First character (: / ? !)
                if !state.firstCharacter.isEmpty {
                    Text(state.firstCharacter)
                        .font(overlayFont(size: 14, weight: .bold))
                        .foregroundStyle(firstCharColor)
                        .padding(.trailing, 2)
                }

                // Prompt
                if !state.prompt.isEmpty {
                    Text(state.prompt)
                        .font(overlayFont(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }

                // Content with cursor
                cmdlineContent

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThickMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 6, y: -2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear { startBlinking() }
            .onDisappear { cursorVisible = true }
        }
    }

    @ViewBuilder
    private var cmdlineContent: some View {
        let text = state.text
        let pos = min(state.position, text.count)
        let beforeCursor = String(text.prefix(pos))
        let afterCursor = String(text.dropFirst(pos))
        let cursorChar = pos < text.count
            ? String(text[text.index(text.startIndex, offsetBy: pos)])
            : " "

        HStack(spacing: 0) {
            Text(beforeCursor)
                .font(overlayFont(size: 14))
                .foregroundStyle(color(rgb: defaultFG))

            // Cursor
            Text(cursorChar)
                .font(overlayFont(size: 14))
                .foregroundStyle(cursorVisible ? color(rgb: defaultBG) : color(rgb: defaultFG))
                .background(cursorVisible ? color(rgb: defaultFG) : Color.clear)

            if afterCursor.count > (pos < text.count ? 1 : 0) {
                let remaining = pos < text.count
                    ? String(afterCursor.dropFirst())
                    : afterCursor
                Text(remaining)
                    .font(overlayFont(size: 14))
                    .foregroundStyle(color(rgb: defaultFG))
            }
        }
    }

    private var firstCharColor: Color {
        switch state.firstCharacter {
        case ":": return .blue
        case "/", "?": return .orange
        default: return color(rgb: defaultFG)
        }
    }

    private func startBlinking() {
        cursorVisible = true
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(530))
                await MainActor.run {
                    cursorVisible.toggle()
                }
            }
        }
    }
}

// MARK: - MessageOverlayView

/// Displays Neovim messages as notification banners at the bottom of the editor.
struct MessageOverlayView: View {
    let messages: [MessageEntry]
    let defaultFG: UInt32
    let defaultBG: UInt32

    private let maxVisible = 5

    var body: some View {
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(visibleMessages) { msg in
                    messageBanner(msg)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .animation(.easeInOut(duration: 0.2), value: messages.count)
        }
    }

    private var visibleMessages: [MessageEntry] {
        if messages.count <= maxVisible {
            return messages
        }
        return Array(messages.suffix(maxVisible))
    }

    @ViewBuilder
    private func messageBanner(_ msg: MessageEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let icon = iconForKind(msg.kind) {
                Image(systemName: icon)
                    .foregroundStyle(colorForKind(msg.kind))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16, alignment: .center)
                    .padding(.top, 2)
            }

            Text(msg.content.map(\.text).joined())
                .font(overlayFont(size: 13))
                .foregroundStyle(color(rgb: defaultFG))
                .lineLimit(6)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundForKind(msg.kind))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(borderForKind(msg.kind), lineWidth: 0.5)
        )
    }

    private func iconForKind(_ kind: String) -> String? {
        switch kind {
        case "emsg", "echoerr":
            return "exclamationmark.triangle.fill"
        case "wmsg":
            return "exclamationmark.circle.fill"
        case "search_count":
            return "magnifyingglass"
        case "quickfix":
            return "list.bullet"
        case "return_prompt", "confirm":
            return "arrow.turn.down.left"
        default:
            return "info.circle.fill"
        }
    }

    private func colorForKind(_ kind: String) -> Color {
        switch kind {
        case "emsg", "echoerr": return .red
        case "wmsg": return .yellow
        case "search_count": return .blue
        default: return .secondary
        }
    }

    private func backgroundForKind(_ kind: String) -> some ShapeStyle {
        switch kind {
        case "emsg", "echoerr":
            return AnyShapeStyle(.red.opacity(0.12))
        case "wmsg":
            return AnyShapeStyle(.yellow.opacity(0.12))
        default:
            return AnyShapeStyle(.ultraThickMaterial)
        }
    }

    private func borderForKind(_ kind: String) -> Color {
        switch kind {
        case "emsg", "echoerr": return .red.opacity(0.3)
        case "wmsg": return .yellow.opacity(0.3)
        default: return Color.primary.opacity(0.15)
        }
    }
}

#endif
