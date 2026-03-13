// CoreTextRenderer.swift
// SWUINeovim
//
// Renders the Neovim editor grid using CoreText.
// Each row is shaped as a sequence of CTLine runs, one per contiguous
// span of identical highlight attributes. This gives us precise per-glyph
// control over positioning, ligatures, emoji, and wide characters.

import CoreText
import Foundation
import QuartzCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - RenderCell

/// A single cell in the Neovim grid.
public struct RenderCell: Equatable, Sendable {
    /// The character displayed in this cell. May be empty for trailing
    /// cells of a wide (double-width) character.
    public var character: String

    /// The highlight attribute ID assigned by `hl_attr_define`.
    public var highlightID: Int

    /// Whether this cell is the trailing cell of a double-width character.
    public var isDoubleWidthTrail: Bool

    public init(character: String = " ", highlightID: Int = 0, isDoubleWidthTrail: Bool = false) {
        self.character = character
        self.highlightID = highlightID
        self.isDoubleWidthTrail = isDoubleWidthTrail
    }
}

// MARK: - Highlight Attributes

/// Resolved highlight attributes from Neovim's `hl_attr_define` events.
public struct ResolvedHighlightAttrs: Equatable, Sendable {
    public var foreground: PlatformColor
    public var background: PlatformColor
    public var special: PlatformColor

    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var undercurl: Bool
    public var underdouble: Bool
    public var underdotted: Bool
    public var underdashed: Bool
    public var strikethrough: Bool
    public var reverse: Bool
    public var blend: Int

    public init(
        foreground: PlatformColor = .white,
        background: PlatformColor = .black,
        special: PlatformColor = .white,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        undercurl: Bool = false,
        underdouble: Bool = false,
        underdotted: Bool = false,
        underdashed: Bool = false,
        strikethrough: Bool = false,
        reverse: Bool = false,
        blend: Int = 0
    ) {
        self.foreground = foreground
        self.background = background
        self.special = special
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.undercurl = undercurl
        self.underdouble = underdouble
        self.underdotted = underdotted
        self.underdashed = underdashed
        self.strikethrough = strikethrough
        self.reverse = reverse
        self.blend = blend
    }

    /// Returns the effective foreground color, accounting for the `reverse` attribute.
    public var effectiveForeground: PlatformColor {
        reverse ? background : foreground
    }

    /// Returns the effective background color, accounting for the `reverse` attribute.
    public var effectiveBackground: PlatformColor {
        reverse ? foreground : background
    }
}

// MARK: - CoreTextRenderer

/// Renders a 2D grid of `RenderCell` values into a `CGContext` using CoreText.
///
/// The renderer maintains a font cascade and cell metrics. It draws one row
/// at a time, grouping consecutive cells with the same highlight ID into
/// attributed-string runs, then shaping and drawing each run as a `CTLine`.
///
/// ## Usage
///
/// ```swift
/// let renderer = CoreTextRenderer(font: .monospacedSystemFont(ofSize: 14, weight: .regular))
/// renderer.draw(row: cells, rowIndex: 3, highlights: table, in: context)
/// ```
public final class CoreTextRenderer: @unchecked Sendable {

    // MARK: - Properties

    /// The primary monospace font used for grid rendering.
    public private(set) var font: PlatformFont

    /// The cell width in points (equal to the advance of a single ASCII glyph).
    public private(set) var cellWidth: CGFloat

    /// The cell height in points (line height including leading).
    public private(set) var cellHeight: CGFloat

    /// The baseline offset from the bottom of the cell.
    public private(set) var baselineOffset: CGFloat

    /// The descent of the font (positive value below the baseline).
    public private(set) var descent: CGFloat

    /// Optional line spacing multiplier. 1.0 = default.
    public var lineSpacing: CGFloat = 1.0 {
        didSet { recalculateMetrics() }
    }

    /// Cached CTFont for CoreText operations.
    private var ctFont: CTFont

    /// Bold variant of the font (synthesized or looked up).
    private var ctFontBold: CTFont

    /// Italic variant of the font.
    private var ctFontItalic: CTFont

    /// Bold-italic variant of the font.
    private var ctFontBoldItalic: CTFont

    // MARK: - Init

    /// Creates a renderer with the given monospace font.
    ///
    /// - Parameter font: A monospace font. If a proportional font is provided,
    ///   character alignment will be approximate.
    public init(font: PlatformFont) {
        self.font = font
        self.ctFont = font as CTFont

        let size = font.pointSize

        // Derive bold/italic variants
        #if os(macOS)
        let boldDescriptor = font.fontDescriptor.withSymbolicTraits(.bold)
        let italicDescriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        let boldItalicDescriptor = font.fontDescriptor.withSymbolicTraits([.bold, .italic])
        self.ctFontBold = CTFontCreateWithFontDescriptor(boldDescriptor as CTFontDescriptor, size, nil)
        self.ctFontItalic = CTFontCreateWithFontDescriptor(italicDescriptor as CTFontDescriptor, size, nil)
        self.ctFontBoldItalic = CTFontCreateWithFontDescriptor(boldItalicDescriptor as CTFontDescriptor, size, nil)
        #else
        let boldDescriptor = font.fontDescriptor.withSymbolicTraits(.traitBold)
        let italicDescriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic)
        let boldItalicDescriptor = font.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic])
        self.ctFontBold = CTFontCreateWithFontDescriptor(
            (boldDescriptor ?? font.fontDescriptor) as CTFontDescriptor, size, nil
        )
        self.ctFontItalic = CTFontCreateWithFontDescriptor(
            (italicDescriptor ?? font.fontDescriptor) as CTFontDescriptor, size, nil
        )
        self.ctFontBoldItalic = CTFontCreateWithFontDescriptor(
            (boldItalicDescriptor ?? font.fontDescriptor) as CTFontDescriptor, size, nil
        )
        #endif

        // Temporary values; recalculated below
        self.cellWidth = 0
        self.cellHeight = 0
        self.baselineOffset = 0
        self.descent = 0

        recalculateMetrics()
    }

    // MARK: - Font Updates

    /// Change the rendering font and recalculate all metrics.
    public func setFont(_ newFont: PlatformFont) {
        self.font = newFont
        self.ctFont = newFont as CTFont

        let size = newFont.pointSize

        #if os(macOS)
        let boldDesc = newFont.fontDescriptor.withSymbolicTraits(.bold)
        let italicDesc = newFont.fontDescriptor.withSymbolicTraits(.italic)
        let biDesc = newFont.fontDescriptor.withSymbolicTraits([.bold, .italic])
        self.ctFontBold = CTFontCreateWithFontDescriptor(boldDesc as CTFontDescriptor, size, nil)
        self.ctFontItalic = CTFontCreateWithFontDescriptor(italicDesc as CTFontDescriptor, size, nil)
        self.ctFontBoldItalic = CTFontCreateWithFontDescriptor(biDesc as CTFontDescriptor, size, nil)
        #else
        let boldDesc = newFont.fontDescriptor.withSymbolicTraits(.traitBold)
        let italicDesc = newFont.fontDescriptor.withSymbolicTraits(.traitItalic)
        let biDesc = newFont.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic])
        self.ctFontBold = CTFontCreateWithFontDescriptor(
            (boldDesc ?? newFont.fontDescriptor) as CTFontDescriptor, size, nil
        )
        self.ctFontItalic = CTFontCreateWithFontDescriptor(
            (italicDesc ?? newFont.fontDescriptor) as CTFontDescriptor, size, nil
        )
        self.ctFontBoldItalic = CTFontCreateWithFontDescriptor(
            (biDesc ?? newFont.fontDescriptor) as CTFontDescriptor, size, nil
        )
        #endif

        recalculateMetrics()
    }

    // MARK: - Metrics

    private func recalculateMetrics() {
        let ascent = CTFontGetAscent(ctFont)
        let desc = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)

        self.descent = desc
        self.cellHeight = ceil((ascent + desc + leading) * lineSpacing)
        self.baselineOffset = ceil(desc + leading * 0.5)

        // Measure the advance of "M" to get the monospace cell width
        let mString = NSAttributedString(
            string: "M",
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(mString)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        self.cellWidth = ceil(width)
    }

    // MARK: - Grid Size Calculation

    /// Calculate the grid dimensions (columns × rows) for a given view size.
    ///
    /// - Parameter size: The view size in points.
    /// - Returns: A tuple of (columns, rows).
    public func gridSize(for size: CGSize) -> (columns: Int, rows: Int) {
        let cols = max(1, Int(floor(size.width / cellWidth)))
        let rows = max(1, Int(floor(size.height / cellHeight)))
        return (cols, rows)
    }

    /// Calculate the point-size needed to display the given grid dimensions.
    ///
    /// - Parameters:
    ///   - columns: Number of columns.
    ///   - rows: Number of rows.
    /// - Returns: The required view size in points.
    public func viewSize(columns: Int, rows: Int) -> CGSize {
        CGSize(
            width: CGFloat(columns) * cellWidth,
            height: CGFloat(rows) * cellHeight
        )
    }

    // MARK: - Drawing

    /// Draw a single row of grid cells into the given context.
    ///
    /// Cells are grouped into runs of consecutive identical highlight IDs.
    /// Each run is shaped as a `CTLine` and drawn at the correct position.
    ///
    /// - Parameters:
    ///   - row: The array of cells for this row.
    ///   - rowIndex: The zero-based row index (0 = top of grid).
    ///   - highlights: A lookup from highlight ID to resolved attributes.
    ///   - defaultAttrs: Default highlight attributes (for hlID 0).
    ///   - context: The Core Graphics context to draw into.
    ///   - viewHeight: The total height of the view (needed for coordinate flipping).
    public func drawRow(
        _ row: [RenderCell],
        rowIndex: Int,
        highlights: [Int: ResolvedHighlightAttrs],
        defaultAttrs: ResolvedHighlightAttrs,
        in context: CGContext,
        viewHeight: CGFloat
    ) {
        guard !row.isEmpty else { return }

        // CoreGraphics uses bottom-left origin; convert from top-left row index
        let rowY = viewHeight - CGFloat(rowIndex + 1) * cellHeight

        // 1. Draw background fills
        drawBackgrounds(
            row: row,
            rowIndex: rowIndex,
            rowY: rowY,
            highlights: highlights,
            defaultAttrs: defaultAttrs,
            in: context
        )

        // 2. Draw text runs (skipping box-drawing characters)
        drawTextRuns(
            row: row,
            rowY: rowY,
            highlights: highlights,
            defaultAttrs: defaultAttrs,
            in: context
        )

        // 3. Owner-draw box-drawing / line-drawing characters as CGContext paths
        drawBoxDrawingCells(
            row: row,
            rowY: rowY,
            highlights: highlights,
            defaultAttrs: defaultAttrs,
            in: context
        )

        // 4. Draw decorations (underline, strikethrough, undercurl, etc.)
        drawDecorations(
            row: row,
            rowY: rowY,
            highlights: highlights,
            defaultAttrs: defaultAttrs,
            in: context
        )
    }

    /// Draw all rows of a grid into the context.
    ///
    /// - Parameters:
    ///   - grid: A 2D array of cells (rows × columns).
    ///   - highlights: Highlight attribute lookup table.
    ///   - defaultAttrs: Default attributes for hlID 0.
    ///   - dirtyRows: Optional set of row indices to redraw. If `nil`, all rows are drawn.
    ///   - context: The Core Graphics context.
    ///   - viewHeight: The total height of the view.
    public func drawGrid(
        _ grid: [[RenderCell]],
        highlights: [Int: ResolvedHighlightAttrs],
        defaultAttrs: ResolvedHighlightAttrs,
        dirtyRows: Set<Int>? = nil,
        in context: CGContext,
        viewHeight: CGFloat
    ) {
        for (rowIndex, row) in grid.enumerated() {
            if let dirty = dirtyRows, !dirty.contains(rowIndex) {
                continue
            }
            drawRow(
                row,
                rowIndex: rowIndex,
                highlights: highlights,
                defaultAttrs: defaultAttrs,
                in: context,
                viewHeight: viewHeight
            )
        }
    }

    // MARK: - Background Drawing

    private func drawBackgrounds(
        row: [RenderCell],
        rowIndex: Int,
        rowY: CGFloat,
        highlights: [Int: ResolvedHighlightAttrs],
        defaultAttrs: ResolvedHighlightAttrs,
        in context: CGContext
    ) {
        var colIndex = 0
        while colIndex < row.count {
            let hlID = row[colIndex].highlightID
            let attrs = highlights[hlID] ?? defaultAttrs

            // Find the extent of consecutive cells with the same background
            var endCol = colIndex + 1
            while endCol < row.count {
                let nextHlID = row[endCol].highlightID
                let nextAttrs = highlights[nextHlID] ?? defaultAttrs
                if nextAttrs.effectiveBackground != attrs.effectiveBackground {
                    break
                }
                endCol += 1
            }

            let bgColor = attrs.effectiveBackground
            let rect = CGRect(
                x: CGFloat(colIndex) * cellWidth,
                y: rowY,
                width: CGFloat(endCol - colIndex) * cellWidth,
                height: cellHeight
            )

            context.setFillColor(bgColor.cgColor)
            context.fill(rect)

            colIndex = endCol
        }
    }

    // MARK: - Text Run Drawing

    /// A span of consecutive cells with identical highlight attributes.
    private struct TextRun {
        let text: String
        let startColumn: Int
        let columnCount: Int
        let highlightID: Int
    }

    private func buildTextRuns(from row: [RenderCell]) -> [TextRun] {
        var runs: [TextRun] = []
        var currentText = ""
        var startCol = 0
        var currentHL = row[0].highlightID
        var colCount = 0

        for (i, cell) in row.enumerated() {
            if cell.isDoubleWidthTrail {
                // Trailing half of a wide char — skip but count the column
                colCount += 1
                continue
            }

            // Replace box-drawing characters with a space so they are
            // owner-drawn in a separate pass while keeping CTLine positioning.
            let ch = BoxDrawingLookup.info(for: cell.character) != nil ? " " : cell.character

            if cell.highlightID != currentHL {
                // Commit the current run
                if !currentText.isEmpty {
                    runs.append(TextRun(
                        text: currentText,
                        startColumn: startCol,
                        columnCount: colCount,
                        highlightID: currentHL
                    ))
                }
                currentText = ch
                startCol = i
                currentHL = cell.highlightID
                colCount = 1
            } else {
                currentText += ch
                colCount += 1
            }
        }

        // Commit final run
        if !currentText.isEmpty {
            runs.append(TextRun(
                text: currentText,
                startColumn: startCol,
                columnCount: colCount,
                highlightID: currentHL
            ))
        }

        return runs
    }

    private func drawTextRuns(
        row: [RenderCell],
        rowY: CGFloat,
        highlights: [Int: ResolvedHighlightAttrs],
        defaultAttrs: ResolvedHighlightAttrs,
        in context: CGContext
    ) {
        let runs = buildTextRuns(from: row)

        for run in runs {
            let attrs = highlights[run.highlightID] ?? defaultAttrs
            let fgColor = attrs.effectiveForeground
            let runFont = resolveFont(for: attrs)

            let attributes: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: fgColor,
                kCTFontAttributeName as NSAttributedString.Key: runFont as CTFont,
            ]

            let attrString = NSAttributedString(string: run.text, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attrString)

            let x = CGFloat(run.startColumn) * cellWidth
            let runWidth = CGFloat(run.columnCount) * cellWidth
            let y = rowY + baselineOffset

            context.saveGState()
            context.clip(to: CGRect(x: x, y: rowY, width: runWidth, height: cellHeight))
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }

    // MARK: - Decoration Drawing

    private func drawDecorations(
        row: [RenderCell],
        rowY: CGFloat,
        highlights: [Int: ResolvedHighlightAttrs],
        defaultAttrs: ResolvedHighlightAttrs,
        in context: CGContext
    ) {
        var colIndex = 0
        while colIndex < row.count {
            let hlID = row[colIndex].highlightID
            let attrs = highlights[hlID] ?? defaultAttrs

            // Skip cells without decorations
            let hasDecoration = attrs.underline || attrs.undercurl || attrs.underdouble
                || attrs.underdotted || attrs.underdashed || attrs.strikethrough

            if !hasDecoration {
                colIndex += 1
                continue
            }

            // Find extent of consecutive cells with same decorations & hlID
            var endCol = colIndex + 1
            while endCol < row.count && row[endCol].highlightID == hlID {
                endCol += 1
            }

            let startX = CGFloat(colIndex) * cellWidth
            let spanWidth = CGFloat(endCol - colIndex) * cellWidth
            let specialColor = attrs.special

            context.saveGState()
            context.setStrokeColor(specialColor.cgColor)

            // Underline
            if attrs.underline {
                let underlineY = rowY + 1.5
                context.setLineWidth(1.0)
                context.move(to: CGPoint(x: startX, y: underlineY))
                context.addLine(to: CGPoint(x: startX + spanWidth, y: underlineY))
                context.strokePath()
            }

            // Double underline
            if attrs.underdouble {
                let y1 = rowY + 1.0
                let y2 = rowY + 3.5
                context.setLineWidth(1.0)
                context.move(to: CGPoint(x: startX, y: y1))
                context.addLine(to: CGPoint(x: startX + spanWidth, y: y1))
                context.strokePath()
                context.move(to: CGPoint(x: startX, y: y2))
                context.addLine(to: CGPoint(x: startX + spanWidth, y: y2))
                context.strokePath()
            }

            // Undercurl (wavy underline)
            if attrs.undercurl {
                let curlyY = rowY + 2.0
                let amplitude: CGFloat = 1.5
                let wavelength: CGFloat = cellWidth * 0.5
                context.setLineWidth(1.0)
                context.move(to: CGPoint(x: startX, y: curlyY))

                var x = startX
                while x < startX + spanWidth {
                    let mid = x + wavelength / 2
                    let end = min(x + wavelength, startX + spanWidth)
                    context.addQuadCurve(
                        to: CGPoint(x: mid, y: curlyY),
                        control: CGPoint(x: x + wavelength / 4, y: curlyY - amplitude)
                    )
                    if end > mid {
                        context.addQuadCurve(
                            to: CGPoint(x: end, y: curlyY),
                            control: CGPoint(x: mid + wavelength / 4, y: curlyY + amplitude)
                        )
                    }
                    x += wavelength
                }
                context.strokePath()
            }

            // Dotted underline
            if attrs.underdotted {
                let dotY = rowY + 1.5
                context.setLineWidth(1.0)
                context.setLineDash(phase: 0, lengths: [1.0, 2.0])
                context.move(to: CGPoint(x: startX, y: dotY))
                context.addLine(to: CGPoint(x: startX + spanWidth, y: dotY))
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
            }

            // Dashed underline
            if attrs.underdashed {
                let dashY = rowY + 1.5
                context.setLineWidth(1.0)
                context.setLineDash(phase: 0, lengths: [4.0, 2.0])
                context.move(to: CGPoint(x: startX, y: dashY))
                context.addLine(to: CGPoint(x: startX + spanWidth, y: dashY))
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
            }

            // Strikethrough
            if attrs.strikethrough {
                let strikeY = rowY + baselineOffset + descent * 0.4
                context.setStrokeColor(attrs.effectiveForeground.cgColor)
                context.setLineWidth(1.0)
                context.move(to: CGPoint(x: startX, y: strikeY))
                context.addLine(to: CGPoint(x: startX + spanWidth, y: strikeY))
                context.strokePath()
            }

            context.restoreGState()
            colIndex = endCol
        }
    }

    // MARK: - Box-Drawing / Line-Drawing Owner Draw

    /// Owner-draw any box-drawing characters in the row using CGContext paths.
    /// This is called after text runs so backgrounds are already filled.
    /// CoreGraphics uses bottom-left origin so `rowY` is the bottom of the row.
    private func drawBoxDrawingCells(
        row: [RenderCell],
        rowY: CGFloat,
        highlights: [Int: ResolvedHighlightAttrs],
        defaultAttrs: ResolvedHighlightAttrs,
        in context: CGContext
    ) {
        let lightWidth: CGFloat = 1.0
        let heavyWidth: CGFloat = 2.0

        for (colIndex, cell) in row.enumerated() {
            guard let info = BoxDrawingLookup.info(for: cell.character) else { continue }

            let attrs = highlights[cell.highlightID] ?? defaultAttrs
            let fgColor = attrs.effectiveForeground

            let cellRect = CGRect(
                x: CGFloat(colIndex) * cellWidth,
                y: rowY,
                width: cellWidth,
                height: cellHeight
            )
            let cx = cellRect.midX
            let cy = cellRect.midY

            context.saveGState()
            context.setStrokeColor(fgColor.cgColor)
            context.setLineCap(.square)
            context.setLineJoin(.miter)

            let w = info.heavy ? heavyWidth : lightWidth
            context.setLineWidth(w)

            if info.rounded {
                drawRoundedCorner(info: info, in: context, cellRect: cellRect, cx: cx, cy: cy)
            } else if info.dashed {
                let dashLen = cellWidth * 0.2
                context.setLineDash(phase: 0, lengths: [dashLen, dashLen])
                drawStraightSegments(info: info, in: context, cellRect: cellRect, cx: cx, cy: cy)
                context.setLineDash(phase: 0, lengths: [])
            } else if info.double {
                let offset: CGFloat = 2.0
                context.setLineWidth(lightWidth)
                if info.left || info.right {
                    if info.left {
                        context.move(to: CGPoint(x: cellRect.minX, y: cy - offset))
                        context.addLine(to: CGPoint(x: info.right ? cellRect.maxX : cx, y: cy - offset))
                        context.strokePath()
                        context.move(to: CGPoint(x: cellRect.minX, y: cy + offset))
                        context.addLine(to: CGPoint(x: info.right ? cellRect.maxX : cx, y: cy + offset))
                        context.strokePath()
                    }
                    if info.right && !info.left {
                        context.move(to: CGPoint(x: cx, y: cy - offset))
                        context.addLine(to: CGPoint(x: cellRect.maxX, y: cy - offset))
                        context.strokePath()
                        context.move(to: CGPoint(x: cx, y: cy + offset))
                        context.addLine(to: CGPoint(x: cellRect.maxX, y: cy + offset))
                        context.strokePath()
                    }
                }
                if info.up || info.down {
                    // Non-flipped CG: up = maxY, down = minY
                    if info.up {
                        context.move(to: CGPoint(x: cx - offset, y: info.down ? cellRect.minY : cy))
                        context.addLine(to: CGPoint(x: cx - offset, y: cellRect.maxY))
                        context.strokePath()
                        context.move(to: CGPoint(x: cx + offset, y: info.down ? cellRect.minY : cy))
                        context.addLine(to: CGPoint(x: cx + offset, y: cellRect.maxY))
                        context.strokePath()
                    }
                    if info.down && !info.up {
                        context.move(to: CGPoint(x: cx - offset, y: cy))
                        context.addLine(to: CGPoint(x: cx - offset, y: cellRect.minY))
                        context.strokePath()
                        context.move(to: CGPoint(x: cx + offset, y: cy))
                        context.addLine(to: CGPoint(x: cx + offset, y: cellRect.minY))
                        context.strokePath()
                    }
                }
            } else {
                drawStraightSegments(info: info, in: context, cellRect: cellRect, cx: cx, cy: cy)
            }

            context.restoreGState()
        }
    }

    private func drawStraightSegments(
        info: BoxDrawingLookup.Info,
        in context: CGContext,
        cellRect: CGRect,
        cx: CGFloat,
        cy: CGFloat
    ) {
        // CoreGraphics non-flipped: Y increases upward.
        // Grid "up" (smaller row index) = higher Y = maxY.
        // Grid "down" (larger row index) = lower Y = minY.
        if info.left {
            context.move(to: CGPoint(x: cellRect.minX, y: cy))
            context.addLine(to: CGPoint(x: cx, y: cy))
            context.strokePath()
        }
        if info.right {
            context.move(to: CGPoint(x: cx, y: cy))
            context.addLine(to: CGPoint(x: cellRect.maxX, y: cy))
            context.strokePath()
        }
        if info.up {
            context.move(to: CGPoint(x: cx, y: cy))
            context.addLine(to: CGPoint(x: cx, y: cellRect.maxY))
            context.strokePath()
        }
        if info.down {
            context.move(to: CGPoint(x: cx, y: cellRect.minY))
            context.addLine(to: CGPoint(x: cx, y: cy))
            context.strokePath()
        }
    }

    /// Draw a rounded corner arc connecting two segments.
    /// The radius is capped at the smaller of half-cell-width and half-cell-height.
    /// Uses non-flipped CG coordinates: Y increases upward, so grid "down" = minY.
    private func drawRoundedCorner(
        info: BoxDrawingLookup.Info,
        in context: CGContext,
        cellRect: CGRect,
        cx: CGFloat,
        cy: CGFloat
    ) {
        let halfW = cellRect.width / 2
        let halfH = cellRect.height / 2
        let radius = min(halfW, halfH)

        if info.right && info.down {
            // ╭ — grid down (minY) sweeping to grid right (maxX)
            context.move(to: CGPoint(x: cx, y: cellRect.minY))
            context.addLine(to: CGPoint(x: cx, y: cy - radius))
            context.addArc(center: CGPoint(x: cx + radius, y: cy - radius),
                           radius: radius,
                           startAngle: .pi,
                           endAngle: .pi * 0.5,
                           clockwise: true)
            context.addLine(to: CGPoint(x: cellRect.maxX, y: cy))
            context.strokePath()
        } else if info.left && info.down {
            // ╮ — grid left (minX) sweeping to grid down (minY)
            context.move(to: CGPoint(x: cellRect.minX, y: cy))
            context.addLine(to: CGPoint(x: cx - radius, y: cy))
            context.addArc(center: CGPoint(x: cx - radius, y: cy - radius),
                           radius: radius,
                           startAngle: .pi * 0.5,
                           endAngle: 0,
                           clockwise: true)
            context.addLine(to: CGPoint(x: cx, y: cellRect.minY))
            context.strokePath()
        } else if info.left && info.up {
            // ╯ — grid up (maxY) sweeping to grid left (minX)
            context.move(to: CGPoint(x: cx, y: cellRect.maxY))
            context.addLine(to: CGPoint(x: cx, y: cy + radius))
            context.addArc(center: CGPoint(x: cx - radius, y: cy + radius),
                           radius: radius,
                           startAngle: 0,
                           endAngle: .pi * 1.5,
                           clockwise: true)
            context.addLine(to: CGPoint(x: cellRect.minX, y: cy))
            context.strokePath()
        } else if info.right && info.up {
            // ╰ — grid right (maxX) sweeping to grid up (maxY)
            context.move(to: CGPoint(x: cellRect.maxX, y: cy))
            context.addLine(to: CGPoint(x: cx + radius, y: cy))
            context.addArc(center: CGPoint(x: cx + radius, y: cy + radius),
                           radius: radius,
                           startAngle: .pi * 1.5,
                           endAngle: .pi,
                           clockwise: true)
            context.addLine(to: CGPoint(x: cx, y: cellRect.maxY))
            context.strokePath()
        }
    }

    // MARK: - Font Resolution

    private func resolveFont(for attrs: ResolvedHighlightAttrs) -> PlatformFont {
        switch (attrs.bold, attrs.italic) {
        case (true, true):
            return ctFontBoldItalic as PlatformFont
        case (true, false):
            return ctFontBold as PlatformFont
        case (false, true):
            return ctFontItalic as PlatformFont
        case (false, false):
            return font
        }
    }

    // MARK: - Cursor Drawing

    /// Draw the cursor at the given grid position.
    ///
    /// - Parameters:
    ///   - column: Zero-based column index.
    ///   - row: Zero-based row index.
    ///   - style: The cursor style to draw.
    ///   - color: The cursor color.
    ///   - context: The Core Graphics context.
    ///   - viewHeight: The total view height for coordinate flipping.
    public func drawCursor(
        column: Int,
        row: Int,
        style: CursorVisualStyle,
        color: PlatformColor,
        context: CGContext,
        viewHeight: CGFloat
    ) {
        let x = CGFloat(column) * cellWidth
        let y = viewHeight - CGFloat(row + 1) * cellHeight

        context.saveGState()
        context.setFillColor(color.cgColor)

        switch style {
        case .block:
            let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
            context.fill(rect)

        case .beam:
            let beamWidth: CGFloat = 2.0
            let rect = CGRect(x: x, y: y, width: beamWidth, height: cellHeight)
            context.fill(rect)

        case .underline:
            let underlineHeight: CGFloat = 2.0
            let rect = CGRect(x: x, y: y, width: cellWidth, height: underlineHeight)
            context.fill(rect)
        }

        context.restoreGState()
    }

    // MARK: - Hit Testing

    /// Convert a point in view coordinates to a grid position.
    ///
    /// - Parameters:
    ///   - point: The point in the view's coordinate system.
    ///   - viewHeight: The total view height.
    /// - Returns: A tuple of (column, row) in grid coordinates, or `nil`
    ///   if the point is outside the grid.
    public func gridPosition(
        at point: CGPoint,
        viewHeight: CGFloat
    ) -> (column: Int, row: Int)? {
        let col = Int(floor(point.x / cellWidth))
        let row = Int(floor((viewHeight - point.y) / cellHeight))
        guard col >= 0, row >= 0 else { return nil }
        return (col, row)
    }
}

// MARK: - CursorVisualStyle

/// The visual style of the cursor.
public enum CursorVisualStyle: Sendable, Equatable, Hashable {
    /// A solid block covering the entire cell.
    case block
    /// A thin vertical bar at the left edge of the cell.
    case beam
    /// A thin horizontal bar at the bottom of the cell.
    case underline
}

// MARK: - Box-Drawing Character Lookup

/// Maps Unicode box-drawing characters (U+2500–U+257F) and rounded-corner
/// characters (U+256D–U+2570) to their segment connectivity so the grid
/// renderer can owner-draw them as CGContext paths instead of font glyphs.
enum BoxDrawingLookup {

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

    static func info(for text: String) -> Info? {
        guard let scalar = text.unicodeScalars.first,
              text.unicodeScalars.count == 1 else { return nil }
        return table[scalar]
    }

    // Light lines
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
    private static let rDR = Info(right: true, down: true, rounded: true)
    private static let rDL = Info(left: true, down: true, rounded: true)
    private static let rUL = Info(left: true, up: true, rounded: true)
    private static let rUR = Info(right: true, up: true, rounded: true)

    // Dashed lines
    private static let hDash  = Info(left: true, right: true, dashed: true)
    private static let vDash  = Info(up: true, down: true, dashed: true)
    private static let hDashH = Info(left: true, right: true, heavy: true, dashed: true)
    private static let vDashH = Info(up: true, down: true, heavy: true, dashed: true)

    private static let table: [Unicode.Scalar: Info] = [
        // Light box drawing
        "\u{2500}": h,    // ─
        "\u{2502}": v,    // │
        "\u{250C}": dr,   // ┌
        "\u{2510}": dl,   // ┐
        "\u{2514}": ur,   // └
        "\u{2518}": ul,   // ┘
        "\u{251C}": vr,   // ├
        "\u{2524}": vl,   // ┤
        "\u{252C}": dh,   // ┬
        "\u{2534}": uh,   // ┴
        "\u{253C}": vh,   // ┼

        // Heavy box drawing
        "\u{2501}": hH,   // ━
        "\u{2503}": vH,   // ┃
        "\u{250F}": drH,  // ┏
        "\u{2513}": dlH,  // ┓
        "\u{2517}": urH,  // ┗
        "\u{251B}": ulH,  // ┛
        "\u{2523}": vrH,  // ┣
        "\u{252B}": vlH,  // ┫
        "\u{2533}": dhH,  // ┳
        "\u{253B}": uhH,  // ┻
        "\u{254B}": vhH,  // ╋

        // Double box drawing
        "\u{2550}": hD,   // ═
        "\u{2551}": vD,   // ║

        // Rounded corners
        "\u{256D}": rDR,  // ╭
        "\u{256E}": rDL,  // ╮
        "\u{256F}": rUL,  // ╯
        "\u{2570}": rUR,  // ╰

        // Dashed lines
        "\u{2504}": hDash,  // ┄
        "\u{2505}": hDashH, // ┅
        "\u{2506}": vDash,  // ┆
        "\u{2507}": vDashH, // ┇
        "\u{2508}": hDash,  // ┈
        "\u{2509}": hDashH, // ┉
        "\u{250A}": vDash,  // ┊
        "\u{250B}": vDashH, // ┋

        // Mixed light/heavy (common subset)
        "\u{250D}": Info(right: true, down: true),
        "\u{250E}": Info(right: true, down: true),
        "\u{2511}": Info(left: true, down: true),
        "\u{2512}": Info(left: true, down: true),
        "\u{2515}": Info(right: true, up: true),
        "\u{2516}": Info(right: true, up: true),
        "\u{2519}": Info(left: true, up: true),
        "\u{251A}": Info(left: true, up: true),
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