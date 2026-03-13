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

private func color(rgb: UInt32) -> Color {
    Color(
        red: Double((rgb >> 16) & 0xFF) / 255.0,
        green: Double((rgb >> 8) & 0xFF) / 255.0,
        blue: Double(rgb & 0xFF) / 255.0
    )
}

// MARK: - PopupMenuOverlayView

/// Displays the Neovim completion popup menu as a floating overlay.
struct PopupMenuOverlayView: View {
    let state: PopupMenuState
    let cellSize: CGSize
    let defaultFG: UInt32
    let defaultBG: UInt32

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
        let anchorX = CGFloat(state.col) * cellSize.width
        let anchorY = CGFloat(state.row + 1) * cellSize.height // below the cursor row

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
            y = CGFloat(state.row) * cellSize.height - height / 2
        }

        return CGPoint(x: x, y: y)
    }

    @ViewBuilder
    private func popupItemRow(item: PopupMenuItem, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            // Kind indicator
            if !item.kind.isEmpty {
                Text(item.kind)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(kindColor(item.kind))
                    .frame(width: 20, alignment: .center)
            }

            // Word
            Text(item.word)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            // Menu detail (right-aligned, dimmed)
            if !item.menu.isEmpty {
                Text(item.menu)
                    .font(.system(size: 11, design: .monospaced))
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
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(firstCharColor)
                        .padding(.trailing, 2)
                }

                // Prompt
                if !state.prompt.isEmpty {
                    Text(state.prompt)
                        .font(.system(size: 14, design: .monospaced))
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
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(color(rgb: defaultFG))

            // Cursor
            Text(cursorChar)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(cursorVisible ? color(rgb: defaultBG) : color(rgb: defaultFG))
                .background(cursorVisible ? color(rgb: defaultFG) : Color.clear)

            if afterCursor.count > (pos < text.count ? 1 : 0) {
                let remaining = pos < text.count
                    ? String(afterCursor.dropFirst())
                    : afterCursor
                Text(remaining)
                    .font(.system(size: 14, design: .monospaced))
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
                .font(.system(size: 13, design: .monospaced))
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
