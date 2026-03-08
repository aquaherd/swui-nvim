// FloatingWindowOverlay.swift
// SWUINeovim
//
// SwiftUI overlay that renders Neovim floating windows (win_float_pos)
// as positioned cards above the editor surface. Used for LSP hover info,
// diagnostic floats, and any other floating windows from plugins.

import SwiftUI

// MARK: - FloatingWindowOverlay

/// Renders all visible floating windows as overlaid cards positioned
/// relative to their anchor grid coordinates.
///
/// Each floating window is a separate Neovim grid that has been positioned
/// via `win_float_pos`. This view renders the grid content using styled
/// text and positions it at the anchor point in the editor surface.
struct FloatingWindowOverlay: View {
    /// All grids, keyed by grid ID.
    let grids: [Int: Grid]

    /// Window position metadata (includes floating window anchor info).
    let windowPositions: [Int: WindowPosition]

    /// Highlight table for resolving highlight IDs to colors.
    let highlightTable: [Int: HighlightAttributes]

    /// Default foreground/background colors.
    let defaultColors: DefaultColors

    /// Size of a single grid cell in points.
    let cellSize: CGSize

    var body: some View {
        ForEach(floatingWindows, id: \.gridID) { floatInfo in
            FloatingWindowCard(
                grid: floatInfo.grid,
                position: floatInfo.position,
                highlightTable: highlightTable,
                defaultColors: defaultColors,
                cellSize: cellSize
            )
            .offset(
                x: floatInfo.pixelX,
                y: floatInfo.pixelY
            )
        }
    }

    // MARK: - Floating Window Info

    private struct FloatingWindowInfo: Identifiable {
        let gridID: Int
        let grid: Grid
        let position: WindowPosition
        let pixelX: CGFloat
        let pixelY: CGFloat

        var id: Int { gridID }
    }

    /// Collect and sort floating windows by z-index.
    private var floatingWindows: [FloatingWindowInfo] {
        windowPositions
            .filter { $0.value.isFloating }
            .compactMap { gridID, position -> FloatingWindowInfo? in
                guard let grid = grids[gridID] else { return nil }

                // Calculate pixel position from anchor coordinates,
                // adjusting for the anchor corner (NW/NE/SW/SE).
                let anchorRow = position.anchorRow ?? 0
                let anchorCol = position.anchorCol ?? 0
                let floatWidth = CGFloat(grid.cols) * cellSize.width
                let floatHeight = CGFloat(grid.rows) * cellSize.height

                var pixelX = CGFloat(anchorCol) * cellSize.width
                var pixelY = CGFloat(anchorRow) * cellSize.height

                // The anchor specifies which corner of the float is placed
                // at the anchor position. NW = top-left (default), NE = top-right, etc.
                switch position.anchor {
                case .northWest:
                    break // top-left corner at anchor — no adjustment
                case .northEast:
                    pixelX -= floatWidth
                case .southWest:
                    pixelY -= floatHeight
                case .southEast:
                    pixelX -= floatWidth
                    pixelY -= floatHeight
                }

                return FloatingWindowInfo(
                    gridID: gridID,
                    grid: grid,
                    position: position,
                    pixelX: pixelX,
                    pixelY: pixelY
                )
            }
            .sorted { $0.position.zIndex < $1.position.zIndex }
    }
}

// MARK: - FloatingWindowCard

/// Renders a single floating window as a styled card.
private struct FloatingWindowCard: View {
    let grid: Grid
    let position: WindowPosition
    let highlightTable: [Int: HighlightAttributes]
    let defaultColors: DefaultColors
    let cellSize: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<grid.rows, id: \.self) { row in
                if let rowCells = grid.getRow(row) {
                    FloatingWindowRow(
                        cells: rowCells,
                        highlightTable: highlightTable,
                        defaultColors: defaultColors
                    )
                }
            }
        }
        .frame(
            width: CGFloat(grid.cols) * cellSize.width,
            height: CGFloat(grid.rows) * cellSize.height
        )
        .background(windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
    }

    private var windowBackground: Color {
        Color(rgb: defaultColors.background)
    }

    private var borderColor: Color {
        Color.primary.opacity(0.2)
    }
}

// MARK: - FloatingWindowRow

/// Renders a single row of a floating window as styled text runs.
private struct FloatingWindowRow: View {
    let cells: [GridCell]
    let highlightTable: [Int: HighlightAttributes]
    let defaultColors: DefaultColors

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(textRuns.enumerated()), id: \.offset) { _, run in
                Text(run.text)
                    .font(.system(size: 13, weight: run.bold ? .bold : .regular, design: .monospaced))
                    .italic(run.italic)
                    .foregroundStyle(run.foreground)
                    .background(run.background)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Group consecutive cells by highlight ID into text runs for efficient rendering.
    private var textRuns: [TextRun] {
        guard !cells.isEmpty else { return [] }

        var runs: [TextRun] = []
        var currentText = ""
        var currentHL = cells[0].highlightID

        for cell in cells {
            if cell.highlightID == currentHL {
                currentText += cell.text
            } else {
                if !currentText.isEmpty {
                    runs.append(makeRun(text: currentText, hlID: currentHL))
                }
                currentText = cell.text
                currentHL = cell.highlightID
            }
        }

        if !currentText.isEmpty {
            runs.append(makeRun(text: currentText, hlID: currentHL))
        }

        return runs
    }

    private func makeRun(text: String, hlID: Int) -> TextRun {
        let attrs = highlightTable[hlID]
        var fg = Color(rgb: attrs?.foreground ?? defaultColors.foreground)
        var bg = Color(rgb: attrs?.background ?? defaultColors.background)

        if attrs?.reverse == true {
            swap(&fg, &bg)
        }

        return TextRun(
            text: text,
            foreground: fg,
            background: bg,
            bold: attrs?.bold ?? false,
            italic: attrs?.italic ?? false
        )
    }
}

private struct TextRun {
    let text: String
    let foreground: Color
    let background: Color
    let bold: Bool
    let italic: Bool
}

// MARK: - Preview

#if DEBUG
#Preview("Floating Window") {
    ZStack(alignment: .topLeading) {
        Color.black
            .ignoresSafeArea()

        // Simulate a floating window with some content
        VStack(alignment: .leading, spacing: 0) {
            Text("fn main() -> Result<(), Error> {")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
            Text("    println!(\"Hello, world!\");")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
            Text("    Ok(())")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
            Text("}")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(8)
        .background(Color(white: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
        .offset(x: 100, y: 50)
    }
    .frame(width: 600, height: 400)
}
#endif
