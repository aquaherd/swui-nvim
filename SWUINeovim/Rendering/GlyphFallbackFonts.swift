import CoreText
import Foundation

public enum GlyphFallbackFonts {
    private static let fallbackPostScriptNames: [String] = {
        let availableNames = CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []
        var ranked: [(rank: Int, name: String)] = []
        var seen = Set<String>()

        for name in availableNames {
            let rank = fallbackRank(for: name)
            guard rank < Int.max, seen.insert(name).inserted else { continue }
            ranked.append((rank, name))
        }

        return ranked
            .sorted { lhs, rhs in
                if lhs.rank == rhs.rank {
                    return lhs.name < rhs.name
                }
                return lhs.rank < rhs.rank
            }
            .map(\.name)
    }()

    public static func cascadedPlatformFont(base: PlatformFont) -> PlatformFont {
        cascadedCTFont(base: base as CTFont) as PlatformFont
    }

    public static func cascadedCTFont(base: CTFont) -> CTFont {
        let baseDescriptor = CTFontCopyFontDescriptor(base)
        let baseName = CTFontCopyPostScriptName(base) as String
        let fallbackDescriptors = fallbackPostScriptNames
            .filter { $0 != baseName }
            .map { name in
                CTFontDescriptorCreateWithAttributes([
                    kCTFontNameAttribute: name,
                    kCTFontSizeAttribute: CTFontGetSize(base)
                ] as CFDictionary)
            }

        guard !fallbackDescriptors.isEmpty else {
            return base
        }

        let cascadedDescriptor = CTFontDescriptorCreateCopyWithAttributes(
            baseDescriptor,
            [kCTFontCascadeListAttribute: fallbackDescriptors] as CFDictionary
        )

        return CTFontCreateWithFontDescriptor(cascadedDescriptor, CTFontGetSize(base), nil)
    }

    private static func fallbackRank(for name: String) -> Int {
        let lower = name.lowercased()

        if lower.contains("symbols") && lower.contains("nerd") && lower.contains("mono") {
            return 0
        }
        if lower.contains("symbols") && (lower.contains("nerd") || lower.contains("nfm")) {
            return 1
        }
        if lower.contains("symbols") {
            return 2
        }
        if (lower.contains("nerd") || lower.contains("nfm")) && lower.contains("mono") {
            return 3
        }
        if lower.contains("nerd") || lower.contains("nfm") {
            return 4
        }
        if lower.contains("fontawesome") || lower.contains("font awesome") || lower.contains("awesome") {
            return 5
        }

        return Int.max
    }
}