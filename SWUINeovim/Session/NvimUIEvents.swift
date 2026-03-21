// NvimUIEvents.swift
// SWUINeovim
//
// Parsed redraw event types from Neovim's ext_linegrid / ext_multigrid UI protocol.
// These types represent the structured output of parsing the raw MsgPackValue
// arrays that arrive in "redraw" notifications.
//
// Reference: https://neovim.io/doc/user/ui.html

import Foundation
import MsgPack

// MARK: - Top-Level Redraw Batch

/// A batch of redraw events received in a single "redraw" notification.
/// Neovim sends these as `["redraw", [[event_name, args...], ...]]`.
/// The batch ends with a `flush` event that signals the UI should
/// commit all pending changes to the screen.
public struct RedrawBatch: Sendable {
    public let events: [RedrawEvent]

    public init(events: [RedrawEvent]) {
        self.events = events
    }
}

// MARK: - RedrawEvent Enum

/// A single redraw event parsed from a Neovim "redraw" notification.
public enum RedrawEvent: Sendable, Equatable {
    // MARK: Global Events
    case setTitle(String)
    case setIcon(String)
    case modeInfoSet(cursorStyleEnabled: Bool, modeInfo: [ModeInfo])
    case modeChange(modeName: String, modeIndex: Int)
    case optionSet(name: String, value: MsgPackValue)
    case defaultColorsSet(
        foreground: UInt32,
        background: UInt32,
        special: UInt32,
        termForeground: UInt32,
        termBackground: UInt32
    )
    case flush

    // MARK: ext_linegrid Events
    case gridResize(grid: Int, width: Int, height: Int)
    case gridClear(grid: Int)
    case gridCursorGoto(grid: Int, row: Int, col: Int)
    case gridLine(grid: Int, row: Int, colStart: Int, cells: [GridLineCellUpdate], wrap: Bool)
    case gridScroll(grid: Int, top: Int, bottom: Int, left: Int, right: Int, rows: Int, cols: Int)
    case gridDestroy(grid: Int)

    // MARK: Highlight Events
    case hlAttrDefine(id: Int, rgbAttrs: HlAttr, ctermAttrs: HlAttr, info: [HlInfo])
    case hlGroupSet(name: String, id: Int)

    // MARK: ext_multigrid Events
    case winPos(grid: Int, win: Int, startRow: Int, startCol: Int, width: Int, height: Int)
    case winFloatPos(
        grid: Int,
        win: Int,
        anchor: FloatAnchor,
        anchorGrid: Int,
        anchorRow: Double,
        anchorCol: Double,
        mouseEnabled: Bool,
        zindex: Int,
        compindex: Int?,
        screenRow: Int?,
        screenCol: Int?
    )
    case winExternalPos(grid: Int, win: Int)
    case winHide(grid: Int)
    case winClose(grid: Int)
    case msgSetPos(grid: Int, row: Int, scrolled: Bool, sepChar: String)
    case winViewport(
        grid: Int,
        win: Int,
        topLine: Int,
        bottomLine: Int,
        cursorLine: Int,
        cursorCol: Int,
        lineCount: Int,
        scrollDelta: Int
    )
    case winViewportMargins(
        grid: Int,
        win: Int,
        top: Int,
        bottom: Int,
        left: Int,
        right: Int
    )
    case winExtmark(grid: Int, win: Int, nsId: Int, markId: Int, row: Int, col: Int)

    // MARK: ext_popupmenu Events
    case popupmenuShow(items: [PopupMenuItem], selected: Int, row: Int, col: Int, grid: Int)
    case popupmenuSelect(selected: Int)
    case popupmenuHide

    // MARK: ext_cmdline Events
    case cmdlineShow(content: [CmdlineChunk], pos: Int, firstc: String, prompt: String, indent: Int, level: Int)
    case cmdlinePos(pos: Int, level: Int)
    case cmdlineSpecialChar(c: String, shift: Bool, level: Int)
    case cmdlineHide(level: Int)
    case cmdlineBlockShow(lines: [[CmdlineChunk]])
    case cmdlineBlockAppend(line: [CmdlineChunk])
    case cmdlineBlockHide

    // MARK: ext_messages Events
    case msgShow(kind: String, content: [MessageChunk], replaceLast: Bool)
    case msgClear
    case msgShowMode(content: [MessageChunk])
    case msgShowCmd(content: [MessageChunk])
    case msgRuler(content: [MessageChunk])
    case msgHistory(entries: [HistoryEntry])

    // MARK: ext_tabline Events
    case tablineUpdate(currentTab: MsgPackValue, tabs: [TabInfo], currentBuf: MsgPackValue, bufs: [BufInfo])

    // MARK: Mouse Events
    case mouseOn
    case mouseOff
    case busyStart
    case busyStop
    case suspend
    case bell
    case visualBell

    // MARK: Unknown / Unrecognized
    case unknown(name: String, args: [MsgPackValue])
}

// MARK: - Supporting Types

/// A single cell update within a `grid_line` event.
public struct GridLineCellUpdate: Sendable, Equatable {
    /// The character(s) to display in this cell. May be empty for repeat cells.
    public let text: String

    /// Highlight attribute ID. If `nil`, reuse the previous cell's highlight.
    public let hlID: Int?

    /// Number of times to repeat this cell. Defaults to 1.
    public let repeat_: Int

    public init(text: String, hlID: Int? = nil, repeat_: Int = 1) {
        self.text = text
        self.hlID = hlID
        self.repeat_ = repeat_
    }
}

/// Highlight attributes from `hl_attr_define`.
public struct HlAttr: Sendable, Equatable {
    public var foreground: UInt32?
    public var background: UInt32?
    public var special: UInt32?
    public var reverse: Bool
    public var italic: Bool
    public var bold: Bool
    public var strikethrough: Bool
    public var underline: Bool
    public var undercurl: Bool
    public var underdouble: Bool
    public var underdotted: Bool
    public var underdashed: Bool
    public var blend: Int
    public var altfont: Bool
    public var nocombine: Bool

    public init(
        foreground: UInt32? = nil,
        background: UInt32? = nil,
        special: UInt32? = nil,
        reverse: Bool = false,
        italic: Bool = false,
        bold: Bool = false,
        strikethrough: Bool = false,
        underline: Bool = false,
        undercurl: Bool = false,
        underdouble: Bool = false,
        underdotted: Bool = false,
        underdashed: Bool = false,
        blend: Int = 0,
        altfont: Bool = false,
        nocombine: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.special = special
        self.reverse = reverse
        self.italic = italic
        self.bold = bold
        self.strikethrough = strikethrough
        self.underline = underline
        self.undercurl = undercurl
        self.underdouble = underdouble
        self.underdotted = underdotted
        self.underdashed = underdashed
        self.blend = blend
        self.altfont = altfont
        self.nocombine = nocombine
    }
}

/// Semantic highlight information from `ext_hlstate`.
public struct HlInfo: Sendable, Equatable {
    public var kind: String
    public var hiName: String?
    public var uiName: String?
    public var id: Int?

    public init(kind: String = "", hiName: String? = nil, uiName: String? = nil, id: Int? = nil) {
        self.kind = kind
        self.hiName = hiName
        self.uiName = uiName
        self.id = id
    }
}

/// Cursor style information from `mode_info_set`.
public struct ModeInfo: Sendable, Equatable {
    public var cursorShape: CursorShape
    public var cellPercentage: Int
    public var blinkwait: Int
    public var blinkon: Int
    public var blinkoff: Int
    public var attrID: Int
    public var attrIDLm: Int
    public var shortName: String
    public var name: String
    public var mouseShape: Int

    public init(
        cursorShape: CursorShape = .block,
        cellPercentage: Int = 0,
        blinkwait: Int = 0,
        blinkon: Int = 0,
        blinkoff: Int = 0,
        attrID: Int = 0,
        attrIDLm: Int = 0,
        shortName: String = "",
        name: String = "",
        mouseShape: Int = 0
    ) {
        self.cursorShape = cursorShape
        self.cellPercentage = cellPercentage
        self.blinkwait = blinkwait
        self.blinkon = blinkon
        self.blinkoff = blinkoff
        self.attrID = attrID
        self.attrIDLm = attrIDLm
        self.shortName = shortName
        self.name = name
        self.mouseShape = mouseShape
    }
}

/// Cursor shapes used in `mode_info_set`.
public enum CursorShape: String, Sendable, Equatable {
    case block = "block"
    case horizontal = "horizontal"
    case vertical = "vertical"

    public init(from string: String) {
        switch string.lowercased() {
        case "block": self = .block
        case "horizontal": self = .horizontal
        case "vertical": self = .vertical
        default: self = .block
        }
    }
}

/// Anchor position for floating windows.
public enum FloatAnchor: String, Sendable, Equatable {
    case northWest = "NW"
    case northEast = "NE"
    case southWest = "SW"
    case southEast = "SE"

    public init(from string: String) {
        switch string.uppercased() {
        case "NW": self = .northWest
        case "NE": self = .northEast
        case "SW": self = .southWest
        case "SE": self = .southEast
        default: self = .northWest
        }
    }
}

// NOTE: PopupMenuItem is defined in NvimSession.swift (with Identifiable)

/// A styled chunk of text for command-line display.
public struct CmdlineChunk: Sendable, Equatable {
    public let hlID: Int
    public let text: String

    public init(hlID: Int, text: String) {
        self.hlID = hlID
        self.text = text
    }
}

/// A styled chunk of text for message display.
public struct MessageChunk: Sendable, Equatable {
    public let hlID: Int
    public let text: String

    public init(hlID: Int, text: String) {
        self.hlID = hlID
        self.text = text
    }
}

/// A history entry from `msg_history_show`.
public struct HistoryEntry: Sendable, Equatable {
    public let kind: String
    public let content: [MessageChunk]

    public init(kind: String, content: [MessageChunk]) {
        self.kind = kind
        self.content = content
    }
}

/// Tab page info from `tabline_update`.
/// The `handle` is the raw MsgPackValue (an ext type on real Neovim connections)
/// so it can be round-tripped back to `nvim_set_current_tabpage`.
public struct TabInfo: Sendable, Equatable {
    public let handle: MsgPackValue
    public let name: String

    public init(handle: MsgPackValue, name: String) {
        self.handle = handle
        self.name = name
    }
}

/// Buffer info from `tabline_update`.
public struct BufInfo: Sendable, Equatable {
    public let handle: MsgPackValue
    public let name: String

    public init(handle: MsgPackValue, name: String) {
        self.handle = handle
        self.name = name
    }
}

// MARK: - Parsing from MsgPackValue

extension RedrawBatch {
    /// Parse a complete redraw notification's parameters into a `RedrawBatch`.
    ///
    /// The params array from the "redraw" notification is a list of event groups,
    /// where each group is `[event_name, args_call_1, args_call_2, ...]`.
    /// A single event name may have multiple argument sets (calls) in one group.
    public static func parse(from params: [MsgPackValue]) -> RedrawBatch {
        var events: [RedrawEvent] = []
        events.reserveCapacity(params.count * 2)

        for param in params {
            guard case .array(let group) = param, !group.isEmpty else { continue }
            guard case .string(let eventName) = group[0] else { continue }

            // Each subsequent element in the group is one "call" of this event
            for i in 1..<group.count {
                guard case .array(let args) = group[i] else { continue }
                if let event = parseEvent(name: eventName, args: args) {
                    events.append(event)
                }
            }

            // Some events like flush have no argument arrays
            if group.count == 1 {
                if let event = parseEvent(name: eventName, args: []) {
                    events.append(event)
                }
            }
        }

        return RedrawBatch(events: events)
    }

    // MARK: - Event Dispatcher

    private static func parseEvent(name: String, args: [MsgPackValue]) -> RedrawEvent? {
        switch name {
        // Global
        case "set_title":
            return parseSetTitle(args)
        case "set_icon":
            return parseSetIcon(args)
        case "mode_info_set":
            return parseModeInfoSet(args)
        case "mode_change":
            return parseModeChange(args)
        case "option_set":
            return parseOptionSet(args)
        case "default_colors_set":
            return parseDefaultColorsSet(args)
        case "flush":
            return .flush
        case "mouse_on":
            return .mouseOn
        case "mouse_off":
            return .mouseOff
        case "busy_start":
            return .busyStart
        case "busy_stop":
            return .busyStop
        case "suspend":
            return .suspend
        case "bell":
            return .bell
        case "visual_bell":
            return .visualBell

        // Grid
        case "grid_resize":
            return parseGridResize(args)
        case "grid_clear":
            return parseGridClear(args)
        case "grid_cursor_goto":
            return parseGridCursorGoto(args)
        case "grid_line":
            return parseGridLine(args)
        case "grid_scroll":
            return parseGridScroll(args)
        case "grid_destroy":
            return parseGridDestroy(args)

        // Highlights
        case "hl_attr_define":
            return parseHlAttrDefine(args)
        case "hl_group_set":
            return parseHlGroupSet(args)

        // Multigrid
        case "win_pos":
            return parseWinPos(args)
        case "win_float_pos":
            return parseWinFloatPos(args)
        case "win_external_pos":
            return parseWinExternalPos(args)
        case "win_hide":
            return parseWinHide(args)
        case "win_close":
            return parseWinClose(args)
        case "msg_set_pos":
            return parseMsgSetPos(args)
        case "win_viewport":
            return parseWinViewport(args)
        case "win_viewport_margins":
            return parseWinViewportMargins(args)
        case "win_extmark":
            return parseWinExtmark(args)

        // Popupmenu
        case "popupmenu_show":
            return parsePopupmenuShow(args)
        case "popupmenu_select":
            return parsePopupmenuSelect(args)
        case "popupmenu_hide":
            return .popupmenuHide

        // Cmdline
        case "cmdline_show":
            return parseCmdlineShow(args)
        case "cmdline_pos":
            return parseCmdlinePos(args)
        case "cmdline_special_char":
            return parseCmdlineSpecialChar(args)
        case "cmdline_hide":
            return parseCmdlineHide(args)
        case "cmdline_block_show":
            return parseCmdlineBlockShow(args)
        case "cmdline_block_append":
            return parseCmdlineBlockAppend(args)
        case "cmdline_block_hide":
            return .cmdlineBlockHide

        // Messages
        case "msg_show":
            return parseMsgShow(args)
        case "msg_clear":
            return .msgClear
        case "msg_showmode":
            return parseMsgShowMode(args)
        case "msg_showcmd":
            return parseMsgShowCmd(args)
        case "msg_ruler":
            return parseMsgRuler(args)
        case "msg_history_show":
            return parseMsgHistoryShow(args)

        // Tabline
        case "tabline_update":
            return parseTablineUpdate(args)

        default:
            return .unknown(name: name, args: args)
        }
    }

    // MARK: - Global Event Parsers

    private static func parseSetTitle(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 1, let title = args[0].stringValue else { return nil }
        return .setTitle(title)
    }

    private static func parseSetIcon(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 1, let icon = args[0].stringValue else { return nil }
        return .setIcon(icon)
    }

    private static func parseModeInfoSet(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 2,
              let cursorStyleEnabled = args[0].boolValue,
              case .array(let modeList) = args[1]
        else { return nil }

        let modes = modeList.map { parseModeInfoEntry($0) }
        return .modeInfoSet(cursorStyleEnabled: cursorStyleEnabled, modeInfo: modes)
    }

    private static func parseModeInfoEntry(_ value: MsgPackValue) -> ModeInfo {
        var info = ModeInfo()
        guard case .map(let dict) = value else { return info }

        for (k, v) in dict {
            guard let key = k.stringValue else { continue }
            switch key {
            case "cursor_shape":
                if let s = v.stringValue { info.cursorShape = CursorShape(from: s) }
            case "cell_percentage":
                if let i = v.intValue { info.cellPercentage = Int(i) }
            case "blinkwait":
                if let i = v.intValue { info.blinkwait = Int(i) }
            case "blinkon":
                if let i = v.intValue { info.blinkon = Int(i) }
            case "blinkoff":
                if let i = v.intValue { info.blinkoff = Int(i) }
            case "attr_id":
                if let i = v.intValue { info.attrID = Int(i) }
            case "attr_id_lm":
                if let i = v.intValue { info.attrIDLm = Int(i) }
            case "short_name":
                if let s = v.stringValue { info.shortName = s }
            case "name":
                if let s = v.stringValue { info.name = s }
            case "mouse_shape":
                if let i = v.intValue { info.mouseShape = Int(i) }
            default:
                break
            }
        }
        return info
    }

    private static func parseModeChange(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 2,
              let name = args[0].stringValue,
              let index = args[1].intValue
        else { return nil }
        return .modeChange(modeName: name, modeIndex: Int(index))
    }

    private static func parseOptionSet(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 2, let name = args[0].stringValue else { return nil }
        return .optionSet(name: name, value: args[1])
    }

    private static func parseDefaultColorsSet(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 5 else { return nil }
        let fg = args[0].uintValue.flatMap { UInt32(exactly: $0) } ?? 0xFFFFFF
        let bg = args[1].uintValue.flatMap { UInt32(exactly: $0) } ?? 0x000000
        let sp = args[2].uintValue.flatMap { UInt32(exactly: $0) } ?? 0xFF0000
        let tfg = args[3].uintValue.flatMap { UInt32(exactly: $0) } ?? 0
        let tbg = args[4].uintValue.flatMap { UInt32(exactly: $0) } ?? 0
        return .defaultColorsSet(foreground: fg, background: bg, special: sp, termForeground: tfg, termBackground: tbg)
    }

    // MARK: - Grid Event Parsers

    private static func parseGridResize(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 3,
              let grid = args[0].intValue,
              let width = args[1].intValue,
              let height = args[2].intValue
        else { return nil }
        return .gridResize(grid: Int(grid), width: Int(width), height: Int(height))
    }

    private static func parseGridClear(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 1, let grid = args[0].intValue else { return nil }
        return .gridClear(grid: Int(grid))
    }

    private static func parseGridCursorGoto(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 3,
              let grid = args[0].intValue,
              let row = args[1].intValue,
              let col = args[2].intValue
        else { return nil }
        return .gridCursorGoto(grid: Int(grid), row: Int(row), col: Int(col))
    }

    private static func parseGridLine(_ args: [MsgPackValue]) -> RedrawEvent? {
        // grid_line: [grid, row, col_start, cells, ..., wrap]
        // cells is a variable-length list of cell arrays, not wrapped in an outer array
        // Actually the format is: [grid, row, col_start, [[text, hl_id?, repeat?], ...]]
        // With an optional trailing wrap boolean
        guard args.count >= 4,
              let grid = args[0].intValue,
              let row = args[1].intValue,
              let colStart = args[2].intValue,
              case .array(let cellArrays) = args[3]
        else { return nil }

        var cells: [GridLineCellUpdate] = []
        cells.reserveCapacity(cellArrays.count)

        for cellValue in cellArrays {
            guard case .array(let cellParts) = cellValue, !cellParts.isEmpty else { continue }

            let text = cellParts[0].stringValue ?? ""
            let hlID: Int? = cellParts.count > 1 ? cellParts[1].intValue.map { Int($0) } : nil
            let repeatCount: Int = cellParts.count > 2 ? (cellParts[2].intValue.map { Int($0) } ?? 1) : 1

            cells.append(GridLineCellUpdate(text: text, hlID: hlID, repeat_: repeatCount))
        }

        // Optional wrap boolean at position 4
        let wrap = args.count > 4 ? (args[4].boolValue ?? false) : false

        return .gridLine(grid: Int(grid), row: Int(row), colStart: Int(colStart), cells: cells, wrap: wrap)
    }

    private static func parseGridScroll(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 7,
              let grid = args[0].intValue,
              let top = args[1].intValue,
              let bot = args[2].intValue,
              let left = args[3].intValue,
              let right = args[4].intValue,
              let rows = args[5].intValue,
              let cols = args[6].intValue
        else { return nil }
        return .gridScroll(
            grid: Int(grid), top: Int(top), bottom: Int(bot),
            left: Int(left), right: Int(right),
            rows: Int(rows), cols: Int(cols)
        )
    }

    private static func parseGridDestroy(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 1, let grid = args[0].intValue else { return nil }
        return .gridDestroy(grid: Int(grid))
    }

    // MARK: - Highlight Event Parsers

    private static func parseHlAttrDefine(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 4, let id = args[0].intValue else { return nil }

        let rgbAttrs = parseHlAttr(args[1])
        let ctermAttrs = parseHlAttr(args[2])

        var infoList: [HlInfo] = []
        if case .array(let infoArray) = args[3] {
            infoList = infoArray.map { parseHlInfo($0) }
        }

        return .hlAttrDefine(id: Int(id), rgbAttrs: rgbAttrs, ctermAttrs: ctermAttrs, info: infoList)
    }

    private static func parseHlAttr(_ value: MsgPackValue) -> HlAttr {
        var attr = HlAttr()
        guard case .map(let dict) = value else { return attr }

        for (k, v) in dict {
            guard let key = k.stringValue else { continue }
            switch key {
            case "foreground":
                attr.foreground = v.uintValue.flatMap { UInt32(exactly: $0) }
            case "background":
                attr.background = v.uintValue.flatMap { UInt32(exactly: $0) }
            case "special":
                attr.special = v.uintValue.flatMap { UInt32(exactly: $0) }
            case "reverse":
                attr.reverse = v.boolValue ?? false
            case "italic":
                attr.italic = v.boolValue ?? false
            case "bold":
                attr.bold = v.boolValue ?? false
            case "strikethrough":
                attr.strikethrough = v.boolValue ?? false
            case "underline":
                attr.underline = v.boolValue ?? false
            case "undercurl":
                attr.undercurl = v.boolValue ?? false
            case "underdouble":
                attr.underdouble = v.boolValue ?? false
            case "underdotted":
                attr.underdotted = v.boolValue ?? false
            case "underdashed":
                attr.underdashed = v.boolValue ?? false
            case "blend":
                if let i = v.intValue { attr.blend = Int(i) }
            case "altfont":
                attr.altfont = v.boolValue ?? false
            case "nocombine":
                attr.nocombine = v.boolValue ?? false
            default:
                break
            }
        }
        return attr
    }

    private static func parseHlInfo(_ value: MsgPackValue) -> HlInfo {
        var info = HlInfo()
        guard case .map(let dict) = value else { return info }

        for (k, v) in dict {
            guard let key = k.stringValue else { continue }
            switch key {
            case "kind":
                info.kind = v.stringValue ?? ""
            case "hi_name":
                info.hiName = v.stringValue
            case "ui_name":
                info.uiName = v.stringValue
            case "id":
                info.id = v.intValue.map { Int($0) }
            default:
                break
            }
        }
        return info
    }

    private static func parseHlGroupSet(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 2,
              let name = args[0].stringValue,
              let id = args[1].intValue
        else { return nil }
        return .hlGroupSet(name: name, id: Int(id))
    }

    // MARK: - Multigrid Event Parsers

    private static func parseWinPos(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 6,
              let grid = args[0].intValue,
              let win = args[1].intValue,
              let startRow = args[2].intValue,
              let startCol = args[3].intValue,
              let width = args[4].intValue,
              let height = args[5].intValue
        else { return nil }
        return .winPos(
            grid: Int(grid), win: Int(win),
            startRow: Int(startRow), startCol: Int(startCol),
            width: Int(width), height: Int(height)
        )
    }

    private static func parseWinFloatPos(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 7,
              let grid = args[0].intValue,
              let win = args[1].intValue,
              let anchorStr = args[2].stringValue,
              let anchorGrid = args[3].intValue,
              let anchorRow = args[4].doubleValue ?? args[4].intValue.map({ Double($0) }),
              let anchorCol = args[5].doubleValue ?? args[5].intValue.map({ Double($0) }),
              let mouseEnabled = args[6].boolValue
        else { return nil }

        let zindex = args.count > 7 ? (args[7].intValue.map { Int($0) } ?? 50) : 50
        let compindex = args.count > 8 ? args[8].intValue.map { Int($0) } : nil
        let screenRow = args.count > 9 ? args[9].intValue.map { Int($0) } : nil
        let screenCol = args.count > 10 ? args[10].intValue.map { Int($0) } : nil

        return .winFloatPos(
            grid: Int(grid), win: Int(win),
            anchor: FloatAnchor(from: anchorStr),
            anchorGrid: Int(anchorGrid),
            anchorRow: anchorRow, anchorCol: anchorCol,
            mouseEnabled: mouseEnabled,
            zindex: zindex,
            compindex: compindex,
            screenRow: screenRow,
            screenCol: screenCol
        )
    }

    private static func parseWinExternalPos(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 2,
              let grid = args[0].intValue,
              let win = args[1].intValue
        else { return nil }
        return .winExternalPos(grid: Int(grid), win: Int(win))
    }

    private static func parseWinHide(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 1, let grid = args[0].intValue else { return nil }
        return .winHide(grid: Int(grid))
    }

    private static func parseWinClose(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 1, let grid = args[0].intValue else { return nil }
        return .winClose(grid: Int(grid))
    }

    private static func parseMsgSetPos(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 4,
              let grid = args[0].intValue,
              let row = args[1].intValue,
              let scrolled = args[2].boolValue,
              let sep = args[3].stringValue
        else { return nil }
        return .msgSetPos(grid: Int(grid), row: Int(row), scrolled: scrolled, sepChar: sep)
    }

    private static func parseWinViewport(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 6,
              let grid = args[0].intValue,
              let win = args[1].intValue,
              let topLine = args[2].intValue,
              let botLine = args[3].intValue,
              let curLine = args[4].intValue,
              let curCol = args[5].intValue
        else { return nil }

        let lineCount = args.count > 6 ? (args[6].intValue.map { Int($0) } ?? 0) : 0
        let scrollDelta = args.count > 7 ? (args[7].intValue.map { Int($0) } ?? 0) : 0

        return .winViewport(
            grid: Int(grid), win: Int(win),
            topLine: Int(topLine), bottomLine: Int(botLine),
            cursorLine: Int(curLine), cursorCol: Int(curCol),
            lineCount: lineCount, scrollDelta: scrollDelta
        )
    }

    private static func parseWinViewportMargins(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 6,
              let grid = args[0].intValue,
              let win = args[1].intValue,
              let top = args[2].intValue,
              let bottom = args[3].intValue,
              let left = args[4].intValue,
              let right = args[5].intValue
        else { return nil }
        return .winViewportMargins(
            grid: Int(grid), win: Int(win),
            top: Int(top), bottom: Int(bottom),
            left: Int(left), right: Int(right)
        )
    }

    private static func parseWinExtmark(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 6,
              let grid = args[0].intValue,
              let win = args[1].intValue,
              let nsId = args[2].intValue,
              let markId = args[3].intValue,
              let row = args[4].intValue,
              let col = args[5].intValue
        else { return nil }
        return .winExtmark(
            grid: Int(grid), win: Int(win),
            nsId: Int(nsId), markId: Int(markId),
            row: Int(row), col: Int(col)
        )
    }

    // MARK: - Popupmenu Event Parsers

    private static func parsePopupmenuShow(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 4,
              case .array(let itemsArray) = args[0],
              let selected = args[1].intValue,
              let row = args[2].intValue,
              let col = args[3].intValue
        else { return nil }

        let grid = args.count > 4 ? (args[4].intValue.map { Int($0) } ?? -1) : -1

        let items: [PopupMenuItem] = itemsArray.compactMap { item in
            guard case .array(let parts) = item, parts.count >= 4 else { return nil }
            return PopupMenuItem(
                word: parts[0].stringValue ?? "",
                kind: parts[1].stringValue ?? "",
                menu: parts[2].stringValue ?? "",
                info: parts[3].stringValue ?? ""
            )
        }

        return .popupmenuShow(items: items, selected: Int(selected), row: Int(row), col: Int(col), grid: grid)
    }

    private static func parsePopupmenuSelect(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 1, let selected = args[0].intValue else { return nil }
        return .popupmenuSelect(selected: Int(selected))
    }

    // MARK: - Cmdline Event Parsers

    private static func parseCmdlineShow(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 6,
              case .array(let contentArray) = args[0],
              let pos = args[1].intValue,
              let firstc = args[2].stringValue,
              let prompt = args[3].stringValue,
              let indent = args[4].intValue,
              let level = args[5].intValue
        else { return nil }

        let content = parseCmdlineChunks(contentArray)
        return .cmdlineShow(
            content: content, pos: Int(pos),
            firstc: firstc, prompt: prompt,
            indent: Int(indent), level: Int(level)
        )
    }

    private static func parseCmdlinePos(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 2,
              let pos = args[0].intValue,
              let level = args[1].intValue
        else { return nil }
        return .cmdlinePos(pos: Int(pos), level: Int(level))
    }

    private static func parseCmdlineSpecialChar(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 3,
              let c = args[0].stringValue,
              let shift = args[1].boolValue,
              let level = args[2].intValue
        else { return nil }
        return .cmdlineSpecialChar(c: c, shift: shift, level: Int(level))
    }

    private static func parseCmdlineHide(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 1, let level = args[0].intValue else { return nil }
        return .cmdlineHide(level: Int(level))
    }

    private static func parseCmdlineBlockShow(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 1, case .array(let linesArray) = args[0] else { return nil }
        let lines = linesArray.compactMap { line -> [CmdlineChunk]? in
            guard case .array(let chunks) = line else { return nil }
            return parseCmdlineChunks(chunks)
        }
        return .cmdlineBlockShow(lines: lines)
    }

    private static func parseCmdlineBlockAppend(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 1, case .array(let chunks) = args[0] else { return nil }
        return .cmdlineBlockAppend(line: parseCmdlineChunks(chunks))
    }

    private static func parseCmdlineChunks(_ array: [MsgPackValue]) -> [CmdlineChunk] {
        return array.compactMap { chunk in
            guard case .array(let parts) = chunk, parts.count >= 2,
                  let hlID = parts[0].intValue,
                  let text = parts[1].stringValue
            else { return nil }
            return CmdlineChunk(hlID: Int(hlID), text: text)
        }
    }

    // MARK: - Message Event Parsers

    private static func parseMsgShow(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 3,
              let kind = args[0].stringValue,
              case .array(let contentArray) = args[1],
              let replaceLast = args[2].boolValue
        else { return nil }

        let content = parseMessageChunks(contentArray)
        return .msgShow(kind: kind, content: content, replaceLast: replaceLast)
    }

    private static func parseMsgShowMode(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 1, case .array(let contentArray) = args[0] else {
            return .msgShowMode(content: [])
        }
        return .msgShowMode(content: parseMessageChunks(contentArray))
    }

    private static func parseMsgShowCmd(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 1, case .array(let contentArray) = args[0] else {
            return .msgShowCmd(content: [])
        }
        return .msgShowCmd(content: parseMessageChunks(contentArray))
    }

    private static func parseMsgRuler(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 1, case .array(let contentArray) = args[0] else {
            return .msgRuler(content: [])
        }
        return .msgRuler(content: parseMessageChunks(contentArray))
    }

    private static func parseMsgHistoryShow(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 1, case .array(let entriesArray) = args[0] else { return nil }
        let entries = entriesArray.compactMap { entry -> HistoryEntry? in
            guard case .array(let parts) = entry, parts.count >= 2,
                  let kind = parts[0].stringValue,
                  case .array(let contentArray) = parts[1]
            else { return nil }
            return HistoryEntry(kind: kind, content: parseMessageChunks(contentArray))
        }
        return .msgHistory(entries: entries)
    }

    private static func parseMessageChunks(_ array: [MsgPackValue]) -> [MessageChunk] {
        return array.compactMap { chunk in
            guard case .array(let parts) = chunk, parts.count >= 2,
                  let hlID = parts[0].intValue,
                  let text = parts[1].stringValue
            else { return nil }
            return MessageChunk(hlID: Int(hlID), text: text)
        }
    }

    // MARK: - Tabline Event Parsers

    private static func parseTablineUpdate(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 4,
              case .array(let tabsArray) = args[1],
              case .array(let bufsArray) = args[3]
        else { return nil }

        let currentTab = args[0]  // raw tabpage ext handle
        let currentBuf = args[2]  // raw buffer ext handle

        let tabs = tabsArray.compactMap { tab -> TabInfo? in
            guard case .map(let dict) = tab else { return nil }
            let handle = dict[.string("tab")] ?? dict[.string("handle")] ?? .nil
            let name = dict[.string("name")]?.stringValue ?? ""
            return TabInfo(handle: handle, name: name)
        }

        let bufs = bufsArray.compactMap { buf -> BufInfo? in
            guard case .map(let dict) = buf else { return nil }
            let handle = dict[.string("buffer")] ?? dict[.string("handle")] ?? .nil
            let name = dict[.string("name")]?.stringValue ?? ""
            return BufInfo(handle: handle, name: name)
        }

        return .tablineUpdate(
            currentTab: currentTab, tabs: tabs,
            currentBuf: currentBuf, bufs: bufs
        )
    }
}

// MARK: - Optional Double Coalescing Helper

/// Helper to unwrap optional Double values from MsgPackValue,
/// handling both float and integer sources.
private extension Optional where Wrapped == Double {
    static func ?? (lhs: Double?, rhs: @autoclosure () -> Double?) -> Double? {
        if let value = lhs { return value }
        return rhs()
    }
}