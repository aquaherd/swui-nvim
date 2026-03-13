// HighlightTable.swift
// SWUINeovim
//
// Maps Neovim hl_attr_define highlight IDs to resolved colors, font traits,
// and decoration styles. Updated incrementally as `hl_attr_define` and
// `default_colors_set` redraw events arrive from the RPC channel.

import Foundation
import CoreGraphics

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - HighlightAttributes

/// Resolved visual attributes for a single highlight group.
public struct HighlightAttributes: Equatable, Sendable {
    /// Foreground color. `nil` means use the default foreground.
    public var foreground: PlatformColor?

    /// Background color. `nil` means use the default background.
    public var background: PlatformColor?

    /// Special color (used for underline, undercurl, strikethrough).
    /// `nil` means use the foreground color.
    public var special: PlatformColor?

    /// Whether the text should be rendered in bold.
    public var bold: Bool = false

    /// Whether the text should be rendered in italic.
    public var italic: Bool = false

    /// Whether the text should have an underline.
    public var underline: Bool = false

    /// Whether the text should have an undercurl (wavy underline).
    public var undercurl: Bool = false

    /// Whether the text should have a strikethrough.
    public var strikethrough: Bool = false

    /// Whether the text should have a double underline.
    public var underdouble: Bool = false

    /// Whether the text should have a dotted underline.
    public var underdotted: Bool = false

    /// Whether the text should have a dashed underline.
    public var underdashed: Bool = false

    /// Whether foreground and background should be swapped (reverse video).
    public var reverse: Bool = false

    /// Blend level (0–100) for transparent floating windows.
    public var blend: Int = 0

    /// The semantic highlight group name, if provided by `ext_hlstate`.
    public var hiName: String?

    /// Creates default (empty) highlight attributes.
    public init() {}

    /// Returns attributes with reverse video applied if `reverse` is set.
    /// Swaps foreground/background using the provided defaults when the
    /// attribute's own colors are nil.
    public func resolved(
        defaultForeground: PlatformColor,
        defaultBackground: PlatformColor
    ) -> HighlightAttributes {
        var result = self
        if reverse {
            let fg = result.foreground ?? defaultForeground
            let bg = result.background ?? defaultBackground
            result.foreground = bg
            result.background = fg
        }
        return result
    }
}

// MARK: - DecorationStyle

/// The decoration style to apply under/over text.
public enum DecorationStyle: Equatable, Sendable {
    case none
    case underline
    case undercurl
    case underdouble
    case underdotted
    case underdashed
    case strikethrough
}

extension HighlightAttributes {
    /// Returns the primary decoration style for this highlight.
    /// Priority order matches Neovim's rendering precedence.
    public var decorationStyle: DecorationStyle {
        if undercurl { return .undercurl }
        if underdouble { return .underdouble }
        if underdotted { return .underdotted }
        if underdashed { return .underdashed }
        if underline { return .underline }
        if strikethrough { return .strikethrough }
        return .none
    }

    /// Returns all active decoration styles (some highlights apply multiple).
    public var allDecorations: [DecorationStyle] {
        var result: [DecorationStyle] = []
        if undercurl { result.append(.undercurl) }
        if underdouble { result.append(.underdouble) }
        if underdotted { result.append(.underdotted) }
        if underdashed { result.append(.underdashed) }
        if underline { result.append(.underline) }
        if strikethrough { result.append(.strikethrough) }
        return result
    }
}

// MARK: - HighlightTable

/// A table that maps Neovim highlight IDs to resolved `HighlightAttributes`.
///
/// Highlight ID 0 is the default highlight group. Its foreground, background,
/// and special colors are set via `default_colors_set`.
///
/// All other IDs are populated by `hl_attr_define` redraw events.
///
/// Thread safety: This type is designed to be mutated on the main actor
/// (as part of the UI redraw pipeline) and read from the rendering layer.
@MainActor
public final class HighlightTable {

    // MARK: - Storage

    /// Sparse storage of highlight attributes keyed by highlight ID.
    /// ID 0 is the default highlight.
    private var attributes: [Int: HighlightAttributes] = [:]

    /// Default foreground color (set by `default_colors_set`).
    public private(set) var defaultForeground: PlatformColor = .white

    /// Default background color (set by `default_colors_set`).
    public private(set) var defaultBackground: PlatformColor = .black

    /// Default special color (set by `default_colors_set`).
    public private(set) var defaultSpecial: PlatformColor = .white

    /// The number of defined highlight groups (excluding the default).
    public var count: Int { attributes.count }

    // MARK: - Init

    public init() {
        // ID 0: default highlight with no overrides
        attributes[0] = HighlightAttributes()
    }

    // MARK: - Access

    /// Look up attributes for a highlight ID.
    ///
    /// Returns the default attributes (ID 0) if the ID is not defined.
    /// The returned attributes have `reverse` already applied.
    public func attributes(for hlID: Int) -> HighlightAttributes {
        let raw = attributes[hlID] ?? attributes[0] ?? HighlightAttributes()
        return raw.resolved(
            defaultForeground: defaultForeground,
            defaultBackground: defaultBackground
        )
    }

    /// Look up the raw (un-resolved) attributes for a highlight ID.
    /// Returns `nil` if the ID is not defined.
    public func rawAttributes(for hlID: Int) -> HighlightAttributes? {
        attributes[hlID]
    }

    /// Returns the effective foreground color for a highlight ID.
    public func foreground(for hlID: Int) -> PlatformColor {
        attributes(for: hlID).foreground ?? defaultForeground
    }

    /// Returns the effective background color for a highlight ID.
    public func background(for hlID: Int) -> PlatformColor {
        attributes(for: hlID).background ?? defaultBackground
    }

    /// Returns the effective special color for a highlight ID.
    public func special(for hlID: Int) -> PlatformColor {
        attributes(for: hlID).special ?? defaultSpecial
    }

    // MARK: - Update from Redraw Events

    /// Process a `default_colors_set` redraw event.
    ///
    /// - Parameters:
    ///   - fg: The default foreground RGB value (24-bit, or -1 for unchanged).
    ///   - bg: The default background RGB value (24-bit, or -1 for unchanged).
    ///   - sp: The default special RGB value (24-bit, or -1 for unchanged).
    public func setDefaultColors(fg: Int64, bg: Int64, sp: Int64) {
        if fg >= 0 {
            defaultForeground = Self.color(fromRGB: UInt32(fg))
        }
        if bg >= 0 {
            defaultBackground = Self.color(fromRGB: UInt32(bg))
        }
        if sp >= 0 {
            defaultSpecial = Self.color(fromRGB: UInt32(sp))
        }
    }

    /// Process an `hl_attr_define` redraw event.
    ///
    /// - Parameters:
    ///   - id: The highlight ID being defined.
    ///   - rgbAttrs: A dictionary of RGB attribute key-value pairs from Neovim.
    ///   - info: Optional semantic highlight info (from `ext_hlstate`).
    public func define(
        id: Int,
        rgbAttrs: [String: Any],
        info: [[String: Any]]? = nil
    ) {
        var attrs = HighlightAttributes()

        if let fg = rgbAttrs["foreground"] as? Int64 {
            attrs.foreground = Self.color(fromRGB: UInt32(fg))
        } else if let fg = rgbAttrs["foreground"] as? UInt64 {
            attrs.foreground = Self.color(fromRGB: UInt32(fg))
        }

        if let bg = rgbAttrs["background"] as? Int64 {
            attrs.background = Self.color(fromRGB: UInt32(bg))
        } else if let bg = rgbAttrs["background"] as? UInt64 {
            attrs.background = Self.color(fromRGB: UInt32(bg))
        }

        if let sp = rgbAttrs["special"] as? Int64 {
            attrs.special = Self.color(fromRGB: UInt32(sp))
        } else if let sp = rgbAttrs["special"] as? UInt64 {
            attrs.special = Self.color(fromRGB: UInt32(sp))
        }

        if let v = rgbAttrs["bold"] as? Bool { attrs.bold = v }
        if let v = rgbAttrs["italic"] as? Bool { attrs.italic = v }
        if let v = rgbAttrs["underline"] as? Bool { attrs.underline = v }
        if let v = rgbAttrs["undercurl"] as? Bool { attrs.undercurl = v }
        if let v = rgbAttrs["strikethrough"] as? Bool { attrs.strikethrough = v }
        if let v = rgbAttrs["underdouble"] as? Bool { attrs.underdouble = v }
        if let v = rgbAttrs["underdotted"] as? Bool { attrs.underdotted = v }
        if let v = rgbAttrs["underdashed"] as? Bool { attrs.underdashed = v }
        if let v = rgbAttrs["reverse"] as? Bool { attrs.reverse = v }

        if let blend = rgbAttrs["blend"] as? Int64 {
            attrs.blend = Int(blend)
        } else if let blend = rgbAttrs["blend"] as? Int {
            attrs.blend = blend
        }

        // Extract semantic name from hlstate info
        if let infoArray = info, let first = infoArray.first {
            if let name = first["hi_name"] as? String {
                attrs.hiName = name
            }
        }

        attributes[id] = attrs
    }

    /// Process an `hl_attr_define` event using `MsgPackValue`-typed arguments
    /// (the more common path when data comes directly from the RPC decoder).
    public func define(
        id: Int,
        rgbAttrs: [String: MsgPackValueConvertible],
        info: [[String: MsgPackValueConvertible]]? = nil
    ) {
        // Delegate to the `Any`-typed overload by converting
        var anyDict: [String: Any] = [:]
        for (key, value) in rgbAttrs {
            anyDict[key] = value.toAny()
        }
        var anyInfo: [[String: Any]]?
        if let info {
            anyInfo = info.map { dict in
                var anyInner: [String: Any] = [:]
                for (key, value) in dict {
                    anyInner[key] = value.toAny()
                }
                return anyInner
            }
        }
        define(id: id, rgbAttrs: anyDict, info: anyInfo)
    }

    /// Clear all highlight definitions.
    /// Called when the UI is detached or reattached.
    public func reset() {
        attributes.removeAll()
        attributes[0] = HighlightAttributes()
        defaultForeground = .white
        defaultBackground = .black
        defaultSpecial = .white
    }

    // MARK: - Color Conversion

    /// Convert a 24-bit RGB integer (0xRRGGBB) to a platform color.
    public static func color(fromRGB rgb: UInt32) -> PlatformColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return PlatformColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// Convert a platform color to a 24-bit RGB integer.
    public static func rgb(from color: PlatformColor) -> UInt32 {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        #if canImport(AppKit)
        let converted = color.usingColorSpace(.sRGB) ?? color
        converted.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif

        let ri = UInt32(max(0, min(1, r)) * 255)
        let gi = UInt32(max(0, min(1, g)) * 255)
        let bi = UInt32(max(0, min(1, b)) * 255)
        return (ri << 16) | (gi << 8) | bi
    }
}

// MARK: - MsgPackValueConvertible

/// Protocol for values that can be converted to `Any` for highlight parsing.
/// This allows the HighlightTable to work with both raw dictionaries and
/// MsgPack-decoded values.
public protocol MsgPackValueConvertible {
    func toAny() -> Any
}

extension Bool: MsgPackValueConvertible {
    public func toAny() -> Any { self }
}

extension Int: MsgPackValueConvertible {
    public func toAny() -> Any { self }
}

extension Int64: MsgPackValueConvertible {
    public func toAny() -> Any { self }
}

extension UInt64: MsgPackValueConvertible {
    public func toAny() -> Any { self }
}

extension String: MsgPackValueConvertible {
    public func toAny() -> Any { self }
}

extension Double: MsgPackValueConvertible {
    public func toAny() -> Any { self }
}

// MARK: - Font Trait Helpers

#if canImport(AppKit)
extension HighlightAttributes {
    /// Returns the `NSFontDescriptor.SymbolicTraits` for this highlight.
    public var fontTraits: NSFontDescriptor.SymbolicTraits {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return traits
    }

    /// Returns a modified font with bold/italic applied.
    public func applyTraits(to font: NSFont) -> NSFont {
        let manager = NSFontManager.shared
        var result = font
        if bold {
            result = manager.convert(result, toHaveTrait: .boldFontMask)
        }
        if italic {
            result = manager.convert(result, toHaveTrait: .italicFontMask)
        }
        return result
    }
}
#elseif canImport(UIKit)
extension HighlightAttributes {
    /// Returns the `UIFontDescriptor.SymbolicTraits` for this highlight.
    public var fontTraits: UIFontDescriptor.SymbolicTraits {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        return traits
    }

    /// Returns a modified font with bold/italic applied.
    public func applyTraits(to font: UIFont) -> UIFont {
        let descriptor = font.fontDescriptor
        guard let modified = descriptor.withSymbolicTraits(fontTraits) else {
            return font
        }
        return UIFont(descriptor: modified, size: font.pointSize)
    }
}
#endif