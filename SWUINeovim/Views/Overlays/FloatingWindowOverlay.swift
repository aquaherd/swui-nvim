// FloatingWindowOverlay.swift
// SWUINeovim
//
// SwiftUI overlay that renders Neovim floating windows (win_float_pos)
// above the main editor surface.

import Foundation
import SwiftUI

// MARK: - FloatingWindowOverlay

struct FloatingWindowOverlay: View {
    let grids: [Int: Grid]
    let windowPositions: [Int: WindowPosition]
    let highlightTable: [Int: RawHighlightAttrs]
    let defaultColors: DefaultColors
    let cellSize: CGSize

    var body: some View {
        ForEach(floatingWindows, id: \.gridID) { floatInfo in
            FloatingWindowCard(
                grids: grids,
                grid: floatInfo.grid,
                position: floatInfo.position,
                highlightTable: highlightTable,
                defaultColors: defaultColors,
                cellSize: cellSize
            )
            .offset(x: floatInfo.pixelX, y: floatInfo.pixelY)
        }
    }

    private struct FloatingWindowInfo: Identifiable {
        let gridID: Int
        let grid: Grid
        let position: WindowPosition
        let pixelX: CGFloat
        let pixelY: CGFloat

        var id: Int { gridID }
    }

    private var floatingWindows: [FloatingWindowInfo] {
        windowPositions
            .filter { $0.value.isFloating }
            .compactMap { gridID, position -> FloatingWindowInfo? in
                guard let grid = grids[gridID] else { return nil }

                let anchorRow = position.anchorRow ?? 0
                let anchorCol = position.anchorCol ?? 0
                let floatWidth = CGFloat(grid.cols) * cellSize.width
                let floatHeight = CGFloat(grid.rows) * cellSize.height

                var pixelX = CGFloat(position.screenCol ?? Int(anchorCol.rounded(.down))) * cellSize.width
                var pixelY = CGFloat(position.screenRow ?? Int(anchorRow.rounded(.down))) * cellSize.height

                if position.screenRow == nil || position.screenCol == nil {
                    switch position.anchor {
                    case .northWest:
                        break
                    case .northEast:
                        pixelX -= floatWidth
                    case .southWest:
                        pixelY -= floatHeight
                    case .southEast:
                        pixelX -= floatWidth
                        pixelY -= floatHeight
                    }
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

private struct FloatingWindowCard: View {
    let grids: [Int: Grid]
    let grid: Grid
    let position: WindowPosition
    let highlightTable: [Int: RawHighlightAttrs]
    let defaultColors: DefaultColors
    let cellSize: CGSize

    var body: some View {
        Group {
            if isBackdropWindow {
                Rectangle()
                    .fill(backdropColor)
                    .frame(width: pixelWidth, height: pixelHeight)
            } else {
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
                .frame(width: pixelWidth, height: pixelHeight)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
            }
        }
    }

    private var pixelWidth: CGFloat {
        CGFloat(grid.cols) * cellSize.width
    }

    private var pixelHeight: CGFloat {
        CGFloat(grid.rows) * cellSize.height
    }

    private var isBackdropWindow: Bool {
        let mainGrid = grids[position.anchorGridID ?? 1] ?? grids[1]
        let coversMostOfEditor: Bool
        if let mainGrid {
            coversMostOfEditor = Double(grid.cols) >= Double(mainGrid.cols) * 0.6
                && Double(grid.rows) >= Double(mainGrid.rows) * 0.6
        } else {
            coversMostOfEditor = grid.cols >= 40 && grid.rows >= 12
        }

        let isRootAnchoredBackdrop = !position.mouseEnabled
            && position.anchorGridID == 1
            && (position.anchorRow ?? 0) == 0
            && (position.anchorCol ?? 0) == 0
            && coversMostOfEditor

        if isRootAnchoredBackdrop {
            return true
        }

        var sampledCells = 0
        var blankCells = 0
        var hasBackdropSemantic = false
        var hasBlend = false

        for row in 0..<grid.rows {
            guard let cells = grid.getRow(row) else { continue }
            for cell in cells {
                sampledCells += 1
                if cell.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blankCells += 1
                }

                guard let attrs = highlightTable[cell.highlightID] else { continue }
                hasBlend = hasBlend || attrs.blend > 0
                let semanticNames = [attrs.hiName, attrs.uiName].compactMap { $0?.lowercased() }
                if semanticNames.contains(where: { $0.contains("shadow") || $0.contains("backdrop") }) {
                    hasBackdropSemantic = true
                }
            }
        }

        let blankRatio = sampledCells > 0 ? Double(blankCells) / Double(sampledCells) : 0
        return coversMostOfEditor && (blankRatio > 0.85 || hasBackdropSemantic || hasBlend)
    }

    private var backdropColor: Color {
        let alpha = dominantBackdropBlend > 0
            ? Double(100 - min(max(dominantBackdropBlend, 0), 100)) / 100.0
            : 0.35
        return Color(rgb: dominantBackdropBackground).opacity(alpha)
    }

    private var dominantBackdropBackground: UInt32 {
        var counts: [UInt32: Int] = [:]
        var winner = defaultColors.background

        for row in 0..<grid.rows {
            guard let cells = grid.getRow(row) else { continue }
            for cell in cells {
                guard let bg = highlightTable[cell.highlightID]?.background else { continue }
                counts[bg, default: 0] += 1
                if counts[bg, default: 0] > counts[winner, default: 0] {
                    winner = bg
                }
            }
        }

        return winner
    }

    private var dominantBackdropBlend: Int {
        var winner = 0
        for row in 0..<grid.rows {
            guard let cells = grid.getRow(row) else { continue }
            for cell in cells {
                winner = max(winner, highlightTable[cell.highlightID]?.blend ?? 0)
            }
        }
        return winner
    }

    private var borderColor: Color {
        Color.primary.opacity(0.2)
    }
}

// MARK: - FloatingWindowRow

private struct FloatingWindowRow: View {
    let cells: [GridCell]
    let highlightTable: [Int: RawHighlightAttrs]
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
        .background(Color.clear)
    }

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
        var foregroundValue = attrs?.foreground ?? defaultColors.foreground
        var backgroundValue = attrs?.background

        if attrs?.reverse == true {
            foregroundValue = attrs?.background ?? defaultColors.background
            backgroundValue = attrs?.foreground
        }

        let blend = min(max(attrs?.blend ?? 0, 0), 100)
        let backgroundOpacity = Double(100 - blend) / 100.0

        return TextRun(
            text: text,
            foreground: Color(rgb: foregroundValue),
            background: backgroundValue.map { Color(rgb: $0).opacity(backgroundOpacity) } ?? Color.clear,
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
