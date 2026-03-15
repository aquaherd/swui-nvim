// PopupMenuOverlay.swift
// SWUINeovim
//
// SwiftUI overlay view for the Neovim external popup menu (ext_popupmenu).
// Positioned relative to the grid cell where the completion was triggered,
// rendered as a floating list that follows Apple HIG for autocomplete.

import SwiftUI

// MARK: - PopupMenuOverlay

/// Renders the Neovim completion popup menu as a SwiftUI overlay.
///
/// This view is placed as an `.overlay` on the `EditorSurface` and positioned
/// using the grid coordinates from `popupmenu_show`. It displays completion
/// items in a scrollable list with kind icons, word text, and menu detail.
///
/// ## Usage
///
/// ```swift
/// EditorSurface(session: session)
///     .overlay {
///         PopupMenuOverlay(
///             state: session.popupMenu,
///             cellSize: renderer.cellSize,
///             gridOrigin: .zero,
///             onSelect: { index in
///                 Task { try await session.input("<C-n>") }
///             }
///         )
///     }
/// ```
public struct PopupMenuOverlay: View {

    // MARK: - Properties

    /// The current popup menu state from the Neovim session.
    let state: PopupMenuState

    /// The size of a single grid cell in points (used for positioning).
    let cellSize: CGSize

    /// The origin offset of the grid within the editor surface.
    let gridOrigin: CGPoint

    /// Maximum number of visible items before scrolling kicks in.
    var maxVisibleItems: Int = 12

    /// Maximum width of the popup menu in points.
    var maxWidth: CGFloat = 400

    /// Callback when the user clicks/taps an item.
    var onSelect: ((Int) -> Void)?

    // MARK: - Body

    public var body: some View {
        if state.isVisible && !state.items.isEmpty {
            GeometryReader { geometry in
                let position = computePosition(in: geometry.size)
                let menuHeight = computeMenuHeight()

                popupContent
                    .frame(maxWidth: maxWidth)
                    .frame(height: menuHeight)
                    .position(x: position.x, y: position.y)
            }
            .allowsHitTesting(true)
        }
    }

    // MARK: - Popup Content

    @ViewBuilder
    private var popupContent: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(state.items.enumerated()), id: \.offset) { index, item in
                            PopupMenuItemRow(
                                item: item,
                                isSelected: index == state.selectedIndex
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect?(index)
                            }
                        }
                    }
                }
                .onChange(of: state.selectedIndex) { _, newIndex in
                    if newIndex >= 0 && newIndex < state.items.count {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(.ultraThinMaterial)
        .background(popupBackgroundColor.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
    }

    // MARK: - Positioning

    /// Compute the position of the popup menu within the editor surface.
    ///
    /// The popup is anchored below the cursor row at the start column.
    /// If there isn't enough space below, it flips above the cursor row.
    private func computePosition(in viewSize: CGSize) -> CGPoint {
        let anchorX = gridOrigin.x + CGFloat(state.col) * cellSize.width
        let anchorYBelow = gridOrigin.y + CGFloat(state.row + 1) * cellSize.height
        let anchorYAbove = gridOrigin.y + CGFloat(state.row) * cellSize.height

        let menuHeight = computeMenuHeight()
        let halfWidth = min(maxWidth, viewSize.width * 0.8) / 2

        // Determine X position (left-aligned with the anchor column, clamped to view)
        var x = anchorX + halfWidth
        if x + halfWidth > viewSize.width {
            x = viewSize.width - halfWidth - 4
        }
        if x - halfWidth < 0 {
            x = halfWidth + 4
        }

        // Determine Y position (prefer below, flip above if not enough space)
        var y: CGFloat
        if anchorYBelow + menuHeight <= viewSize.height {
            y = anchorYBelow + menuHeight / 2
        } else if anchorYAbove - menuHeight >= 0 {
            y = anchorYAbove - menuHeight / 2
        } else {
            // Not enough space either way — show below and let it clip
            y = anchorYBelow + menuHeight / 2
        }

        return CGPoint(x: x, y: y)
    }

    /// Compute the height of the popup menu based on item count.
    private func computeMenuHeight() -> CGFloat {
        let itemHeight: CGFloat = 24
        let visibleCount = min(state.items.count, maxVisibleItems)
        return CGFloat(visibleCount) * itemHeight + 8 // 4pt padding top/bottom
    }

    // MARK: - Colors

    private var popupBackgroundColor: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    private var borderColor: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }
}

// MARK: - PopupMenuItemRow

/// A single row in the popup menu, showing the completion kind, word, and menu detail.
struct PopupMenuItemRow: View {

    let item: PopupMenuItem
    let isSelected: Bool

    private let itemHeight: CGFloat = 24

    var body: some View {
        HStack(spacing: 6) {
            // Kind badge
            if !item.kind.isEmpty {
                Text(item.kind)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(kindColor)
                    .frame(width: 20, alignment: .center)
            }

            // Completion word
            Text(item.word)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(isSelected ? Color.white : textColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            // Menu detail (source/type info)
            if !item.menu.isEmpty {
                Text(item.menu)
                    .font(.system(size: 10, weight: .regular, design: .default))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : detailColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: itemHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? selectionColor : Color.clear)
        .contentShape(Rectangle())
    }

    // MARK: - Colors

    private var selectionColor: Color {
        Color.accentColor
    }

    private var textColor: Color {
        #if os(macOS)
        Color(nsColor: .labelColor)
        #else
        Color(uiColor: .label)
        #endif
    }

    private var detailColor: Color {
        #if os(macOS)
        Color(nsColor: .secondaryLabelColor)
        #else
        Color(uiColor: .secondaryLabel)
        #endif
    }

    /// Color for the kind badge, mapped from common LSP completion kinds.
    private var kindColor: Color {
        switch item.kind.lowercased() {
        case "f", "function", "method":
            return .purple
        case "v", "variable":
            return .blue
        case "t", "type", "class", "struct", "enum", "interface":
            return .orange
        case "m", "module", "package":
            return .green
        case "k", "keyword":
            return .red
        case "s", "snippet":
            return .pink
        case "p", "property", "field":
            return .cyan
        case "c", "constant":
            return .yellow
        case "d", "define":
            return .mint
        default:
            return .secondary
        }
    }
}

// PopupMenuState and PopupMenuItem are defined in NvimSession.swift.

// MARK: - Preview

#if DEBUG
#Preview("Popup Menu") {
    let sampleItems = (0..<15).map { i in
        PopupMenuItem(
            id: i,
            word: ["nvim_buf_get_lines", "nvim_input", "nvim_command", "nvim_eval",
                   "nvim_set_var", "nvim_get_option", "nvim_create_autocmd",
                   "nvim_buf_set_text", "nvim_win_get_cursor", "nvim_feedkeys",
                   "nvim_replace_termcodes", "nvim_open_win", "nvim_set_hl",
                   "nvim_buf_attach", "nvim_list_bufs"][i],
            kind: ["f", "f", "f", "f", "f", "f", "f", "f", "f", "f", "f", "f", "f", "f", "f"][i],
            menu: ["[API]", "[API]", "[API]", "[API]", "[API]", "[API]", "[API]",
                   "[API]", "[API]", "[API]", "[API]", "[API]", "[API]", "[API]", "[API]"][i],
            info: ""
        )
    }

    let state = PopupMenuState(
        isVisible: true,
        items: sampleItems,
        selectedIndex: 3,
        row: 5,
        col: 10,
        gridID: 1
    )

    ZStack {
        Color.black.ignoresSafeArea()

        PopupMenuOverlay(
            state: state,
            cellSize: CGSize(width: 8, height: 16),
            gridOrigin: .zero
        )
    }
    .frame(width: 600, height: 400)
}

#Preview("Popup Menu - Empty Selection") {
    let items = [
        PopupMenuItem(id: 0, word: "hello", kind: "v", menu: "[Buffer]"),
        PopupMenuItem(id: 1, word: "help", kind: "f", menu: "[LSP]"),
        PopupMenuItem(id: 2, word: "height", kind: "p", menu: "[LSP]"),
    ]

    let state = PopupMenuState(
        isVisible: true,
        items: items,
        selectedIndex: -1,
        row: 10,
        col: 5,
        gridID: 1
    )

    ZStack {
        Color.black.ignoresSafeArea()

        PopupMenuOverlay(
            state: state,
            cellSize: CGSize(width: 8, height: 16),
            gridOrigin: .zero
        )
    }
    .frame(width: 400, height: 300)
}
#endif