// CursorRenderer.swift
// SWUINeovim
//
// Draws the editor cursor (block, beam, underline) with blink animation.
// Integrates with GridState for position and HighlightTable for cursor colors.

import Foundation
import QuartzCore
import CoreGraphics

#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformColor = UIColor
#endif

// MARK: - Cursor Shape

/// The visual shape of the cursor, matching Neovim's `mode_info_set` cursor shapes.
public enum CursorShape: String, Sendable, Equatable {
    /// Full-cell block cursor (normal mode).
    case block
    /// Thin vertical bar on the left edge (insert mode).
    case vertical
    /// Thin horizontal bar at the bottom of the cell (replace mode).
    case horizontal

    /// Initialize from Neovim's `cursor_shape` string.
    public init(nvimShape: String) {
        switch nvimShape.lowercased() {
        case "block":
            self = .block
        case "vertical":
            self = .vertical
        case "horizontal":
            self = .horizontal
        default:
            self = .block
        }
    }
}

// MARK: - Cursor Style

/// Complete cursor style information, typically derived from Neovim's `mode_info_set`.
public struct CursorStyle: Sendable, Equatable {
    /// The shape of the cursor.
    public var shape: CursorShape

    /// Width percentage for beam cursors (1–100). Only meaningful for `.vertical`.
    public var cellPercentage: Int

    /// Highlight attribute ID for the cursor (from `hl_attr_define`).
    /// If 0, the cursor uses the default foreground/background swap.
    public var attrID: Int

    /// Blink wait time in milliseconds (time the cursor stays visible before first blink).
    public var blinkWait: Int

    /// Blink on time in milliseconds (time the cursor is visible during blink cycle).
    public var blinkOn: Int

    /// Blink off time in milliseconds (time the cursor is hidden during blink cycle).
    public var blinkOff: Int

    /// Whether blinking is enabled for this cursor style.
    public var blinksEnabled: Bool {
        blinkOn > 0 && blinkOff > 0
    }

    /// The default block cursor with no blinking.
    public static let `default` = CursorStyle(
        shape: .block,
        cellPercentage: 100,
        attrID: 0,
        blinkWait: 0,
        blinkOn: 0,
        blinkOff: 0
    )

    /// Typical insert-mode beam cursor.
    public static let insertBeam = CursorStyle(
        shape: .vertical,
        cellPercentage: 25,
        attrID: 0,
        blinkWait: 700,
        blinkOn: 400,
        blinkOff: 250
    )

    /// Typical replace-mode underline cursor.
    public static let replaceUnderline = CursorStyle(
        shape: .horizontal,
        cellPercentage: 20,
        attrID: 0,
        blinkWait: 700,
        blinkOn: 400,
        blinkOff: 250
    )

    public init(
        shape: CursorShape,
        cellPercentage: Int = 100,
        attrID: Int = 0,
        blinkWait: Int = 0,
        blinkOn: Int = 0,
        blinkOff: Int = 0
    ) {
        self.shape = shape
        self.cellPercentage = max(1, min(100, cellPercentage))
        self.attrID = attrID
        self.blinkWait = blinkWait
        self.blinkOn = blinkOn
        self.blinkOff = blinkOff
    }
}

// MARK: - Cursor State

/// Tracks the current cursor position and visibility for rendering.
public struct CursorState: Sendable, Equatable {
    /// Grid ID the cursor is on (for `ext_multigrid`).
    public var gridID: Int

    /// Row in the grid (0-based).
    public var row: Int

    /// Column in the grid (0-based).
    public var col: Int

    /// Current cursor style.
    public var style: CursorStyle

    /// Whether the cursor should be drawn (e.g., hidden in certain modes).
    public var visible: Bool

    public init(
        gridID: Int = 1,
        row: Int = 0,
        col: Int = 0,
        style: CursorStyle = .default,
        visible: Bool = true
    ) {
        self.gridID = gridID
        self.row = row
        self.col = col
        self.style = style
        self.visible = visible
    }
}

// MARK: - CursorRenderer

/// Renders the editor cursor and manages blink animation.
///
/// The renderer computes a `CGRect` for the cursor based on the cell dimensions
/// and cursor style, then draws it into the provided `CGContext`. Blink state
/// is driven by a display-link timer that toggles visibility at the intervals
/// specified by the current `CursorStyle`.
///
/// ## Usage
///
/// ```swift
/// let renderer = CursorRenderer()
/// renderer.cursorState = CursorState(row: 5, col: 10, style: .insertBeam)
/// renderer.cellSize = CGSize(width: 8.0, height: 16.0)
/// renderer.draw(in: context)
/// ```
public final class CursorRenderer: @unchecked Sendable {

    // MARK: - Public Properties

    /// The current cursor state (position, shape, visibility).
    public var cursorState: CursorState = CursorState() {
        didSet {
            if oldValue.style != cursorState.style {
                resetBlink()
            }
        }
    }

    /// The size of a single grid cell in points.
    public var cellSize: CGSize = CGSize(width: 8.0, height: 16.0)

    /// The cursor foreground color (drawn on top of the cell background).
    /// For a block cursor, this is typically the background color of the text.
    public var cursorColor: PlatformColor = {
        #if os(macOS)
        return .white
        #else
        return .white
        #endif
    }()

    /// The text color to use when drawing the character under a block cursor.
    public var cursorTextColor: PlatformColor = {
        #if os(macOS)
        return .black
        #else
        return .black
        #endif
    }()

    /// Alpha value for the cursor when visible (allows semi-transparent cursors).
    public var cursorAlpha: CGFloat = 1.0

    /// Callback invoked when the blink state changes and the cursor region
    /// needs to be redrawn. The view should call `setNeedsDisplay` (or
    /// equivalent) in this callback.
    public var onBlinkStateChanged: (() -> Void)?

    // MARK: - Blink State

    /// Whether the cursor is currently in the "on" (visible) phase of blinking.
    private var blinkVisible: Bool = true

    /// Timer for the blink animation cycle.
    private var blinkTimer: Timer?

    /// Whether we're in the initial wait phase before blinking starts.
    private var inBlinkWait: Bool = false

    /// Timestamp of the last cursor movement or keystroke (resets blink).
    private var lastActivityTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    // MARK: - Init

    public init() {}

    deinit {
        stopBlinkTimer()
    }

    // MARK: - Drawing

    /// Draw the cursor into the given graphics context.
    ///
    /// Call this from the editor surface's `draw(_:)` method. The context
    /// should already have the correct coordinate system set up (origin at
    /// top-left for the grid, or flipped as appropriate).
    ///
    /// - Parameters:
    ///   - context: The Core Graphics context to draw into.
    ///   - originOffset: An optional offset applied to the cursor rect (e.g.,
    ///     if the grid doesn't start at (0, 0) in the view).
    public func draw(in context: CGContext, originOffset: CGPoint = .zero) {
        guard cursorState.visible else { return }
        guard blinkVisible else { return }

        let rect = cursorRect(originOffset: originOffset)
        guard !rect.isEmpty else { return }

        context.saveGState()

        let color = cursorColor.cgColor
        context.setFillColor(color)
        context.setAlpha(cursorAlpha)

        switch cursorState.style.shape {
        case .block:
            // Draw a filled rectangle covering the entire cell.
            context.fill(rect)

        case .vertical:
            // Draw a thin vertical bar on the leading edge of the cell.
            context.fill(rect)

        case .horizontal:
            // Draw a thin horizontal bar at the bottom of the cell.
            context.fill(rect)
        }

        context.restoreGState()
    }

    /// Compute the cursor rectangle in the grid's coordinate space.
    ///
    /// - Parameter originOffset: Offset from the grid origin (e.g., for
    ///   scroll or padding).
    /// - Returns: The rectangle where the cursor should be drawn.
    public func cursorRect(originOffset: CGPoint = .zero) -> CGRect {
        let x = CGFloat(cursorState.col) * cellSize.width + originOffset.x
        let y = CGFloat(cursorState.row) * cellSize.height + originOffset.y

        switch cursorState.style.shape {
        case .block:
            return CGRect(x: x, y: y, width: cellSize.width, height: cellSize.height)

        case .vertical:
            let widthFraction = CGFloat(cursorState.style.cellPercentage) / 100.0
            let beamWidth = max(1.0, cellSize.width * widthFraction)
            return CGRect(x: x, y: y, width: beamWidth, height: cellSize.height)

        case .horizontal:
            let heightFraction = CGFloat(cursorState.style.cellPercentage) / 100.0
            let barHeight = max(1.0, cellSize.height * heightFraction)
            let barY = y + cellSize.height - barHeight
            return CGRect(x: x, y: barY, width: cellSize.width, height: barHeight)
        }
    }

    /// Returns the cell-sized rectangle for the cursor's current position,
    /// useful for determining the dirty region to invalidate.
    public func dirtyCellRect(originOffset: CGPoint = .zero) -> CGRect {
        let x = CGFloat(cursorState.col) * cellSize.width + originOffset.x
        let y = CGFloat(cursorState.row) * cellSize.height + originOffset.y
        return CGRect(x: x, y: y, width: cellSize.width, height: cellSize.height)
    }

    // MARK: - Blink Control

    /// Notify the renderer that user activity occurred (keystroke, mouse click).
    /// This resets the blink cycle so the cursor stays visible.
    public func notifyActivity() {
        lastActivityTime = CFAbsoluteTimeGetCurrent()
        resetBlink()
    }

    /// Start the blink animation if the current style supports it.
    public func startBlinking() {
        guard cursorState.style.blinksEnabled else {
            blinkVisible = true
            return
        }
        resetBlink()
    }

    /// Stop blinking and make the cursor permanently visible.
    public func stopBlinking() {
        stopBlinkTimer()
        blinkVisible = true
        onBlinkStateChanged?()
    }

    /// Reset the blink cycle: cursor becomes visible, then waits before starting to blink.
    private func resetBlink() {
        stopBlinkTimer()
        blinkVisible = true
        onBlinkStateChanged?()

        guard cursorState.style.blinksEnabled else { return }

        let waitInterval = TimeInterval(cursorState.style.blinkWait) / 1000.0

        if waitInterval > 0 {
            inBlinkWait = true
            blinkTimer = Timer.scheduledTimer(
                withTimeInterval: waitInterval,
                repeats: false
            ) { [weak self] _ in
                self?.inBlinkWait = false
                self?.startBlinkCycle()
            }
        } else {
            startBlinkCycle()
        }
    }

    /// Begin the on/off blink cycle after the initial wait.
    private func startBlinkCycle() {
        blinkVisible = true
        onBlinkStateChanged?()

        let onInterval = TimeInterval(cursorState.style.blinkOn) / 1000.0

        blinkTimer = Timer.scheduledTimer(
            withTimeInterval: onInterval,
            repeats: false
        ) { [weak self] _ in
            self?.blinkOff()
        }
    }

    /// Transition to the "off" (hidden) phase of the blink cycle.
    private func blinkOff() {
        blinkVisible = false
        onBlinkStateChanged?()

        let offInterval = TimeInterval(cursorState.style.blinkOff) / 1000.0

        blinkTimer = Timer.scheduledTimer(
            withTimeInterval: offInterval,
            repeats: false
        ) { [weak self] _ in
            self?.blinkOn()
        }
    }

    /// Transition to the "on" (visible) phase of the blink cycle.
    private func blinkOn() {
        blinkVisible = true
        onBlinkStateChanged?()

        let onInterval = TimeInterval(cursorState.style.blinkOn) / 1000.0

        blinkTimer = Timer.scheduledTimer(
            withTimeInterval: onInterval,
            repeats: false
        ) { [weak self] _ in
            self?.blinkOff()
        }
    }

    /// Stop and invalidate the blink timer.
    private func stopBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        inBlinkWait = false
    }

    // MARK: - Mode Change

    /// Update the cursor style from Neovim's `mode_info_set` data.
    ///
    /// Call this when a `mode_change` event is received. The `modeInfo` array
    /// is the list of mode property maps from `mode_info_set`, and `modeIndex`
    /// is the index into that array for the current mode.
    ///
    /// - Parameters:
    ///   - modeInfoList: Array of mode info dictionaries (each is a map of
    ///     string keys to values).
    ///   - modeIndex: Index of the current mode in `modeInfoList`.
    public func updateModeInfo(
        modeInfoList: [[String: Any]],
        modeIndex: Int
    ) {
        guard modeIndex >= 0 && modeIndex < modeInfoList.count else { return }

        let info = modeInfoList[modeIndex]

        let shapeStr = info["cursor_shape"] as? String ?? "block"
        let shape = CursorShape(nvimShape: shapeStr)
        let cellPercentage = info["cell_percentage"] as? Int ?? (shape == .block ? 100 : 25)
        let attrID = info["attr_id"] as? Int ?? 0
        let blinkWait = info["blinkwait"] as? Int ?? 0
        let blinkOn = info["blinkon"] as? Int ?? 0
        let blinkOff = info["blinkoff"] as? Int ?? 0

        let newStyle = CursorStyle(
            shape: shape,
            cellPercentage: cellPercentage,
            attrID: attrID,
            blinkWait: blinkWait,
            blinkOn: blinkOn,
            blinkOff: blinkOff
        )

        cursorState.style = newStyle

        if newStyle.blinksEnabled {
            startBlinking()
        } else {
            stopBlinking()
        }
    }

    /// Update the cursor position from a `grid_cursor_goto` event.
    ///
    /// - Parameters:
    ///   - gridID: The grid the cursor moved to.
    ///   - row: The new row (0-based).
    ///   - col: The new column (0-based).
    public func updatePosition(gridID: Int, row: Int, col: Int) {
        let oldRow = cursorState.row
        let oldCol = cursorState.col
        let oldGrid = cursorState.gridID

        cursorState.gridID = gridID
        cursorState.row = row
        cursorState.col = col

        // If the cursor actually moved, reset the blink cycle
        if oldRow != row || oldCol != col || oldGrid != gridID {
            notifyActivity()
        }
    }
}

// MARK: - Display Link Integration

#if os(macOS)
/// A CVDisplayLink wrapper for smooth cursor blink on macOS.
///
/// This is an alternative to `Timer`-based blinking that synchronizes with
/// the display refresh rate for smoother animation. Enable this for
/// production use when cursor animation fidelity matters.
public final class DisplayLinkCursorAnimator: @unchecked Sendable {
    private var displayLink: CVDisplayLink?
    private let callback: () -> Void

    public init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    public func start() {
        guard displayLink == nil else { return }

        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)

        guard let displayLink else { return }

        let callbackPointer = Unmanaged.passRetained(CallbackBox(callback)).toOpaque()

        CVDisplayLinkSetOutputCallback(
            displayLink,
            { _, _, _, _, _, userInfo -> CVReturn in
                guard let userInfo else { return kCVReturnError }
                let box = Unmanaged<CallbackBox>.fromOpaque(userInfo).takeUnretainedValue()
                DispatchQueue.main.async {
                    box.callback()
                }
                return kCVReturnSuccess
            },
            callbackPointer
        )

        CVDisplayLinkStart(displayLink)
    }

    public func stop() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    deinit {
        stop()
    }

    private final class CallbackBox {
        let callback: () -> Void
        init(_ callback: @escaping () -> Void) {
            self.callback = callback
        }
    }
}
#endif