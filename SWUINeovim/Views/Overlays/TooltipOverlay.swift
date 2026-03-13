// TooltipOverlay.swift
// SWUINeovim
//
// SwiftUI overlay for displaying LSP hover information and tooltips.
// Positioned near the cursor or a specified grid cell, rendered as a
// compact card with styled content.

import SwiftUI

// MARK: - TooltipState

/// State for the tooltip overlay, populated from LSP hover responses
/// or diagnostic floating windows.
public struct TooltipState: Sendable, Equatable {
    /// Whether the tooltip is currently visible.
    public var isVisible: Bool

    /// The styled content chunks of the tooltip.
    public var content: [(highlightID: Int, text: String)]

    /// The grid row where the tooltip should be anchored.
    public var row: Int

    /// The grid column where the tooltip should be anchored.
    public var col: Int

    /// The grid ID the tooltip belongs to.
    public var gridID: Int

    public static func == (lhs: TooltipState, rhs: TooltipState) -> Bool {
        lhs.isVisible == rhs.isVisible &&
        lhs.row == rhs.row &&
        lhs.col == rhs.col &&
        lhs.gridID == rhs.gridID &&
        lhs.content.count == rhs.content.count &&
        zip(lhs.content, rhs.content).allSatisfy { $0.highlightID == $1.highlightID && $0.text == $1.text }
    }

    public init(
        isVisible: Bool = false,
        content: [(highlightID: Int, text: String)] = [],
        row: Int = 0,
        col: Int = 0,
        gridID: Int = 1
    ) {
        self.isVisible = isVisible
        self.content = content
        self.row = row
        self.col = col
        self.gridID = gridID
    }

    /// Concatenated plain text of the tooltip content.
    public var text: String {
        content.map(\.text).joined()
    }
}

// MARK: - TooltipOverlay

/// Displays LSP hover information as a compact tooltip card near the cursor.
///
/// The tooltip appears above or below the anchor position depending on
/// available space, styled with the editor's color scheme.
struct TooltipOverlay: View {
    /// The current tooltip state.
    let state: TooltipState

    /// Size of a single grid cell in points.
    let cellSize: CGSize

    /// Highlight table for resolving highlight IDs to colors.
    let highlightTable: [Int: RawHighlightAttrs]

    /// Default foreground/background colors.
    let defaultColors: DefaultColors

    /// Maximum width of the tooltip in points.
    var maxWidth: CGFloat = 500

    /// Maximum height of the tooltip in points.
    var maxHeight: CGFloat = 300

    var body: some View {
        if state.isVisible && !state.content.isEmpty {
            GeometryReader { geometry in
                let position = computePosition(in: geometry.size)

                tooltipContent
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .position(x: position.x, y: position.y)
            }
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .animation(.easeOut(duration: 0.12), value: state.isVisible)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var tooltipContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 0) {
                        ForEach(Array(line.enumerated()), id: \.offset) { _, chunk in
                            Text(chunk.text)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(foregroundColor(for: chunk.highlightID))
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(tooltipBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
    }

    // MARK: - Line Splitting

    /// Split content into lines for proper rendering.
    private var lines: [[(highlightID: Int, text: String)]] {
        var result: [[(highlightID: Int, text: String)]] = [[]]

        for chunk in state.content {
            let parts = chunk.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, part) in parts.enumerated() {
                if i > 0 {
                    result.append([])
                }
                if !part.isEmpty {
                    result[result.count - 1].append(
                        (highlightID: chunk.highlightID, text: String(part))
                    )
                }
            }
        }

        return result
    }

    // MARK: - Positioning

    private func computePosition(in viewSize: CGSize) -> CGPoint {
        let anchorX = CGFloat(state.col) * cellSize.width
        let anchorYAbove = CGFloat(state.row) * cellSize.height
        let anchorYBelow = CGFloat(state.row + 1) * cellSize.height

        // Estimate content height
        let lineCount = CGFloat(max(lines.count, 1))
        let estimatedHeight = min(lineCount * 18 + 16, maxHeight)
        let halfWidth = min(maxWidth, viewSize.width * 0.8) / 2

        // X position: left-aligned with anchor, clamped to view
        var x = anchorX + halfWidth
        if x + halfWidth > viewSize.width {
            x = viewSize.width - halfWidth - 4
        }
        if x - halfWidth < 0 {
            x = halfWidth + 4
        }

        // Y position: prefer above the anchor, flip below if not enough space
        var y: CGFloat
        if anchorYAbove - estimatedHeight >= 0 {
            y = anchorYAbove - estimatedHeight / 2
        } else if anchorYBelow + estimatedHeight <= viewSize.height {
            y = anchorYBelow + estimatedHeight / 2
        } else {
            y = anchorYAbove - estimatedHeight / 2
        }

        return CGPoint(x: x, y: y)
    }

    // MARK: - Styling

    private func foregroundColor(for highlightID: Int) -> Color {
        guard let attrs = highlightTable[highlightID],
              let fg = attrs.foreground else {
            return Color(rgb: defaultColors.foreground)
        }
        return Color(rgb: fg)
    }

    private var tooltipBackground: some ShapeStyle {
        .ultraThinMaterial
    }

    private var borderColor: Color {
        Color.primary.opacity(0.15)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Tooltip - LSP Hover") {
    ZStack {
        Color.black
            .ignoresSafeArea()

        TooltipOverlay(
            state: TooltipState(
                isVisible: true,
                content: [
                    (highlightID: 0, text: "func "),
                    (highlightID: 1, text: "nvim_buf_get_lines"),
                    (highlightID: 0, text: "(buffer: Int, start: Int, end: Int, strict: Bool) -> [String]\n\n"),
                    (highlightID: 0, text: "Gets a line-range from the buffer.\n"),
                    (highlightID: 0, text: "Indexing is zero-based, end-exclusive."),
                ],
                row: 5,
                col: 10,
                gridID: 1
            ),
            cellSize: CGSize(width: 8.4, height: 17),
            highlightTable: [:],
            defaultColors: DefaultColors()
        )
    }
    .frame(width: 600, height: 400)
}
#endif
