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
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
#else
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
#endif

// MARK: - GridCell

/// A single cell in the Neovim grid.
public struct GridCell: Equatable, Sendable {
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
public struct HighlightAttributes: Equatable, Sendable {
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

/// Renders a 2D grid of `GridCell` values into a `CGContext` using CoreText.
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
        _ row: [GridCell],
        rowIndex: Int,
        highlights: [Int: HighlightAttributes],
        defaultAttrs: HighlightAttributes,
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

        // 2. Draw text runs
        drawTextRuns(
            row: row,
            rowY: rowY,
            highlights: highlights,
            defaultAttrs: defaultAttrs,
            in: context
        )

        // 3. Draw decorations (underline, strikethrough, undercurl, etc.)
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
        _ grid: [[GridCell]],
        highlights: [Int: HighlightAttributes],
        defaultAttrs: HighlightAttributes,
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
        row: [GridCell],
        rowIndex: Int,
        rowY: CGFloat,
        highlights: [Int: HighlightAttributes],
        defaultAttrs: HighlightAttributes,
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

    private func buildTextRuns(from row: [GridCell]) -> [TextRun] {
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
                currentText = cell.character
                startCol = i
                currentHL = cell.highlightID
                colCount = 1
            } else {
                currentText += cell.character
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
        row: [GridCell],
        rowY: CGFloat,
        highlights: [Int: HighlightAttributes],
        defaultAttrs: HighlightAttributes,
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
            let y = rowY + baselineOffset

            context.saveGState()
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }

    // MARK: - Decoration Drawing

    private func drawDecorations(
        row: [GridCell],
        rowY: CGFloat,
        highlights: [Int: HighlightAttributes],
        defaultAttrs: HighlightAttributes,
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

    // MARK: - Font Resolution

    private func resolveFont(for attrs: HighlightAttributes) -> PlatformFont {
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
        style: CursorStyle,
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

// MARK: - CursorStyle

/// The visual style of the cursor.
public enum CursorStyle: Sendable, Equatable, Hashable {
    /// A solid block covering the entire cell.
    case block
    /// A thin vertical bar at the left edge of the cell.
    case beam
    /// A thin horizontal bar at the bottom of the cell.
    case underline
}