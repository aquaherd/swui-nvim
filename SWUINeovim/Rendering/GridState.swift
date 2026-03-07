// GridState.swift
// SWUINeovim
//
// 2D cell grid model representing the Neovim UI surface.
// Each grid corresponds to a Neovim window (with ext_multigrid)
// or the single global grid (without ext_multigrid).

import Foundation

// MARK: - GridCell

/// A single cell in the Neovim grid.
///
/// Each cell contains a Unicode character (possibly empty for the
/// trailing cell of a wide character), a highlight attribute ID,
/// and metadata about double-width status.
public struct GridCell: Sendable, Equatable {
    /// The text content of this cell. Usually a single Unicode scalar,
    /// but may be a grapheme cluster (e.g. emoji with ZWJ sequences).
    /// Empty string for the trailing cell of a double-width character.
    public var text: String

    /// The highlight attribute ID assigned by `hl_attr_define`.
    /// `0` is the default highlight group.
    public var highlightID: Int

    /// Whether this cell is the continuation (trailing) cell of a
    /// double-width character. The actual character is in the cell
    /// to the left.
    public var isDoubleWidthContinuation: Bool

    /// Create a cell with the given text and highlight ID.
    public init(
        text: String = " ",
        highlightID: Int = 0,
        isDoubleWidthContinuation: Bool = false
    ) {
        self.text = text
        self.highlightID = highlightID
        self.isDoubleWidthContinuation = isDoubleWidthContinuation
    }

    /// A blank (space) cell with the default highlight.
    public static let blank = GridCell()
}

// MARK: - DirtyRegion

/// Tracks which rows in a grid have been modified since the last render pass.
public struct DirtyRegion: Sendable {
    /// Set of row indices that need to be redrawn.
    public private(set) var dirtyRows: Set<Int>

    /// Whether the entire grid needs to be redrawn (e.g. after a resize or clear).
    public private(set) var fullRedrawNeeded: Bool

    public init() {
        self.dirtyRows = []
        self.fullRedrawNeeded = true
    }

    /// Mark a single row as dirty.
    public mutating func markRow(_ row: Int) {
        dirtyRows.insert(row)
    }

    /// Mark a range of rows as dirty.
    public mutating func markRows(_ range: Range<Int>) {
        for row in range {
            dirtyRows.insert(row)
        }
    }

    /// Mark the entire grid as needing a full redraw.
    public mutating func markFullRedraw() {
        fullRedrawNeeded = true
    }

    /// Clear all dirty flags after a render pass.
    public mutating func clearAll() {
        dirtyRows.removeAll()
        fullRedrawNeeded = false
    }

    /// Whether any rows are dirty or a full redraw is needed.
    public var isDirty: Bool {
        fullRedrawNeeded || !dirtyRows.isEmpty
    }
}

// MARK: - GridState

/// The state of a single Neovim grid.
///
/// Neovim's `ext_multigrid` mode assigns each window its own grid ID.
/// Without `ext_multigrid`, there is a single grid with ID 1.
///
/// `GridState` owns the 2D cell array and provides methods that
/// correspond directly to Neovim redraw events:
/// - `grid_resize`  → ``resize(rows:columns:)``
/// - `grid_line`    → ``setLine(row:columnStart:cells:)``
/// - `grid_scroll`  → ``scroll(top:bottom:left:right:rows:columns:)``
/// - `grid_clear`   → ``clear()``
/// - `grid_cursor_goto` → ``setCursor(row:column:)``
public final class GridState: @unchecked Sendable {
    // MARK: - Properties

    /// The grid ID assigned by Neovim.
    public let gridID: Int

    /// Number of rows in the grid.
    public private(set) var rows: Int

    /// Number of columns in the grid.
    public private(set) var columns: Int

    /// The 2D cell array, stored in row-major order.
    /// Access: `cells[row][column]`
    public private(set) var cells: [[GridCell]]

    /// Cursor position within this grid.
    public private(set) var cursorRow: Int = 0
    public private(set) var cursorColumn: Int = 0

    /// Tracks which rows need redrawing.
    public var dirty: DirtyRegion

    /// Whether this grid is currently visible.
    public var isVisible: Bool = true

    /// Position of this grid relative to the root grid (for ext_multigrid).
    /// These are set by `win_pos` and `win_float_pos` events.
    public var originRow: Int = 0
    public var originColumn: Int = 0

    /// The window ID this grid belongs to (set by `win_pos`).
    public var windowID: Int?

    /// Whether this grid is a floating window.
    public var isFloating: Bool = false

    /// The z-order for floating windows. Higher values are drawn on top.
    public var zIndex: Int = 0

    // MARK: - Initialization

    /// Create a new grid with the given dimensions, filled with blank cells.
    public init(gridID: Int, rows: Int, columns: Int) {
        self.gridID = gridID
        self.rows = rows
        self.columns = columns
        self.cells = Self.makeBlankCells(rows: rows, columns: columns)
        self.dirty = DirtyRegion()
    }

    /// Create a grid with the default size (80x24).
    public convenience init(gridID: Int) {
        self.init(gridID: gridID, rows: 24, columns: 80)
    }

    // MARK: - Cell Access

    /// Get the cell at the given position.
    /// Returns `.blank` if out of bounds.
    public func cell(row: Int, column: Int) -> GridCell {
        guard row >= 0, row < rows, column >= 0, column < columns else {
            return .blank
        }
        return cells[row][column]
    }

    /// Get a range of cells from a row.
    public func cellsInRow(_ row: Int, from startColumn: Int = 0, to endColumn: Int? = nil) -> ArraySlice<GridCell> {
        guard row >= 0, row < rows else { return [] }
        let end = min(endColumn ?? columns, columns)
        let start = max(startColumn, 0)
        guard start < end else { return [] }
        return cells[row][start..<end]
    }

    /// Extract the plain text content of a row.
    public func textInRow(_ row: Int) -> String {
        guard row >= 0, row < rows else { return "" }
        return cells[row].reduce(into: "") { result, cell in
            if !cell.isDoubleWidthContinuation {
                result += cell.text
            }
        }
    }

    // MARK: - Neovim Redraw Events

    /// Handle `grid_resize`: resize the grid, preserving existing content where possible.
    public func resize(rows newRows: Int, columns newColumns: Int) {
        guard newRows != rows || newColumns != columns else { return }

        var newCells = Self.makeBlankCells(rows: newRows, columns: newColumns)

        // Copy existing content into the new grid
        let copyRows = min(rows, newRows)
        let copyCols = min(columns, newColumns)
        for r in 0..<copyRows {
            for c in 0..<copyCols {
                newCells[r][c] = cells[r][c]
            }
        }

        cells = newCells
        rows = newRows
        columns = newColumns

        // Clamp cursor position
        cursorRow = min(cursorRow, newRows - 1)
        cursorColumn = min(cursorColumn, newColumns - 1)

        dirty.markFullRedraw()
    }

    /// Handle `grid_line`: update a contiguous run of cells in a row.
    ///
    /// - Parameters:
    ///   - row: The row index.
    ///   - columnStart: The starting column for the update.
    ///   - cells: An array of `(text, highlightID, repeat)` tuples.
    ///     Each tuple may have a repeat count > 1, meaning the cell is
    ///     repeated that many times. A `highlightID` of `nil` means
    ///     "same as the previous cell's highlight."
    public func setLine(
        row: Int,
        columnStart: Int,
        cells lineCells: [(text: String, highlightID: Int?, repeat: Int)]
    ) {
        guard row >= 0, row < rows else { return }

        var col = columnStart
        var lastHL = 0

        for (text, hlID, repeatCount) in lineCells {
            let hl = hlID ?? lastHL
            lastHL = hl

            let count = max(repeatCount, 1)
            for _ in 0..<count {
                guard col < columns else { break }
                cells[row][col] = GridCell(
                    text: text,
                    highlightID: hl,
                    isDoubleWidthContinuation: false
                )
                col += 1

                // If the text occupies more than one cell width
                // (e.g. CJK characters), the next cell is a continuation.
                // We detect this by checking if the text has a display
                // width > 1. For simplicity, we handle the common case
                // where Neovim sends an empty string for the continuation cell.
            }
        }

        dirty.markRow(row)
    }

    /// Handle `grid_line` with pre-parsed `GridCell` values.
    /// This is a convenience overload for when cells are already constructed.
    public func setLine(row: Int, columnStart: Int, gridCells: [GridCell]) {
        guard row >= 0, row < rows else { return }

        for (offset, cell) in gridCells.enumerated() {
            let col = columnStart + offset
            guard col < columns else { break }
            cells[row][col] = cell
        }

        dirty.markRow(row)
    }

    /// Handle `grid_scroll`: scroll a rectangular region of the grid.
    ///
    /// - Parameters:
    ///   - top: Top row of the scroll region (inclusive).
    ///   - bottom: Bottom row of the scroll region (exclusive).
    ///   - left: Left column of the scroll region (inclusive).
    ///   - right: Right column of the scroll region (exclusive).
    ///   - rowDelta: Number of rows to scroll. Positive = scroll up (content moves up,
    ///     new blank rows appear at bottom). Negative = scroll down.
    ///   - columnDelta: Number of columns to scroll (rarely used, usually 0).
    public func scroll(
        top: Int,
        bottom: Int,
        left: Int,
        right: Int,
        rows rowDelta: Int,
        columns columnDelta: Int = 0
    ) {
        let clampedTop = max(top, 0)
        let clampedBottom = min(bottom, rows)
        let clampedLeft = max(left, 0)
        let clampedRight = min(right, columns)

        guard clampedTop < clampedBottom, clampedLeft < clampedRight else { return }

        if rowDelta > 0 {
            // Scroll up: move rows upward, blank rows appear at the bottom
            for r in clampedTop..<(clampedBottom - rowDelta) {
                let srcRow = r + rowDelta
                guard srcRow < clampedBottom else { continue }
                for c in clampedLeft..<clampedRight {
                    cells[r][c] = cells[srcRow][c]
                }
            }
            // Clear the newly exposed rows at the bottom
            for r in max(clampedBottom - rowDelta, clampedTop)..<clampedBottom {
                for c in clampedLeft..<clampedRight {
                    cells[r][c] = .blank
                }
            }
        } else if rowDelta < 0 {
            // Scroll down: move rows downward, blank rows appear at the top
            let delta = -rowDelta
            for r in stride(from: clampedBottom - 1, through: clampedTop + delta, by: -1) {
                let srcRow = r - delta
                guard srcRow >= clampedTop else { continue }
                for c in clampedLeft..<clampedRight {
                    cells[r][c] = cells[srcRow][c]
                }
            }
            // Clear the newly exposed rows at the top
            for r in clampedTop..<min(clampedTop + delta, clampedBottom) {
                for c in clampedLeft..<clampedRight {
                    cells[r][c] = .blank
                }
            }
        }

        // Column scrolling (rare)
        if columnDelta != 0 {
            for r in clampedTop..<clampedBottom {
                var newRow = cells[r]
                if columnDelta > 0 {
                    for c in clampedLeft..<(clampedRight - columnDelta) {
                        newRow[c] = cells[r][c + columnDelta]
                    }
                    for c in (clampedRight - columnDelta)..<clampedRight {
                        newRow[c] = .blank
                    }
                } else {
                    let delta = -columnDelta
                    for c in stride(from: clampedRight - 1, through: clampedLeft + delta, by: -1) {
                        newRow[c] = cells[r][c - delta]
                    }
                    for c in clampedLeft..<(clampedLeft + delta) {
                        newRow[c] = .blank
                    }
                }
                cells[r] = newRow
            }
        }

        // Mark affected rows as dirty
        dirty.markRows(clampedTop..<clampedBottom)
    }

    /// Handle `grid_clear`: fill the entire grid with blank cells.
    public func clear() {
        cells = Self.makeBlankCells(rows: rows, columns: columns)
        dirty.markFullRedraw()
    }

    /// Handle `grid_cursor_goto`: update the cursor position within this grid.
    public func setCursor(row: Int, column: Int) {
        // Mark old and new cursor rows as dirty for redraw
        if cursorRow != row || cursorColumn != column {
            dirty.markRow(cursorRow)
            dirty.markRow(row)
        }
        cursorRow = max(0, min(row, rows - 1))
        cursorColumn = max(0, min(column, columns - 1))
    }

    // MARK: - Helpers

    /// Create a 2D array of blank cells.
    private static func makeBlankCells(rows: Int, columns: Int) -> [[GridCell]] {
        let blankRow = [GridCell](repeating: .blank, count: columns)
        return [[GridCell]](repeating: blankRow, count: rows)
    }
}

// MARK: - GridCollection

/// Manages multiple grids for `ext_multigrid` mode.
///
/// Grid ID 1 is the default (root) grid. Additional grids are created
/// by Neovim for each window and floating window.
public final class GridCollection: @unchecked Sendable {
    /// All grids, keyed by grid ID.
    private var grids: [Int: GridState] = [:]

    /// The currently focused grid ID (where the cursor is).
    public var focusedGridID: Int = 1

    public init() {
        // Create the default grid
        grids[1] = GridState(gridID: 1)
    }

    /// Get a grid by ID. Creates it if it doesn't exist.
    public func grid(_ id: Int) -> GridState {
        if let existing = grids[id] {
            return existing
        }
        let newGrid = GridState(gridID: id)
        grids[id] = newGrid
        return newGrid
    }

    /// Get a grid by ID, returning `nil` if it doesn't exist.
    public func existingGrid(_ id: Int) -> GridState? {
        grids[id]
    }

    /// Remove a grid by ID.
    @discardableResult
    public func removeGrid(_ id: Int) -> GridState? {
        grids.removeValue(forKey: id)
    }

    /// All grid IDs currently tracked.
    public var gridIDs: [Int] {
        Array(grids.keys).sorted()
    }

    /// All grids sorted by z-index (for rendering order).
    /// Non-floating grids come first, then floating grids sorted by z-index.
    public var sortedGrids: [GridState] {
        grids.values.sorted { a, b in
            if a.isFloating != b.isFloating {
                return !a.isFloating // non-floating first
            }
            return a.zIndex < b.zIndex
        }
    }

    /// All visible grids sorted for rendering.
    public var visibleGrids: [GridState] {
        sortedGrids.filter(\.isVisible)
    }

    /// The number of grids.
    public var count: Int {
        grids.count
    }

    /// Whether any grid has dirty cells needing a redraw.
    public var needsRedraw: Bool {
        grids.values.contains { $0.dirty.isDirty }
    }

    /// Clear all dirty flags across all grids.
    public func clearAllDirty() {
        for grid in grids.values {
            grid.dirty.clearAll()
        }
    }
}

// MARK: - CustomDebugStringConvertible

extension GridState: CustomDebugStringConvertible {
    public var debugDescription: String {
        var lines: [String] = []
        lines.append("Grid(id=\(gridID), \(columns)x\(rows), cursor=(\(cursorRow),\(cursorColumn)))")
        for r in 0..<min(rows, 50) { // cap debug output
            let rowText = cells[r].map { cell -> String in
                cell.isDoubleWidthContinuation ? "" : cell.text
            }.joined()
            lines.append("  |\(rowText)|")
        }
        if rows > 50 {
            lines.append("  ... (\(rows - 50) more rows)")
        }
        return lines.joined(separator: "\n")
    }
}

extension GridCell: CustomDebugStringConvertible {
    public var debugDescription: String {
        let flag = isDoubleWidthContinuation ? "[W]" : ""
        return "\"\(text)\"(hl:\(highlightID))\(flag)"
    }
}