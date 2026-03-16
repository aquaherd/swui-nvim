// MetalGlyphAtlas.swift
// SWUINeovim
//
// GPU-accelerated glyph atlas for high-performance grid rendering.
// Rasterises unique glyphs into a Metal texture atlas and draws the
// entire editor grid in a single instanced draw call.
//
// This is activated when the grid exceeds a size threshold or the user
// opts in. Falls back to CoreTextRenderer on unsupported hardware.

import Foundation
import Metal
import MetalKit
import CoreText
import CoreGraphics

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Glyph Key

/// Identifies a unique glyph in the atlas by its character content and style.
public struct GlyphKey: Hashable, Sendable {
    /// The character(s) to render — may be a single Unicode scalar or a grapheme cluster.
    public let characters: String

    /// Whether the glyph is bold.
    public let bold: Bool

    /// Whether the glyph is italic.
    public let italic: Bool

    /// Font size in points.
    public let fontSize: CGFloat

    public init(characters: String, bold: Bool, italic: Bool, fontSize: CGFloat) {
        self.characters = characters
        self.bold = bold
        self.italic = italic
        self.fontSize = fontSize
    }
}

// MARK: - Atlas Entry

/// Location of a rasterised glyph within the texture atlas.
public struct GlyphAtlasEntry: Sendable {
    /// Position in the atlas texture (pixels).
    public let x: UInt16
    public let y: UInt16

    /// Size of the glyph region in the atlas (pixels).
    public let width: UInt16
    public let height: UInt16

    /// Offset from the cell origin to the glyph origin (pixels).
    public let bearingX: Float
    public let bearingY: Float

    /// The advance width of the glyph (pixels).
    public let advance: Float
}

// MARK: - Cell Instance (GPU buffer element)

/// Per-cell data uploaded to the GPU for instanced rendering.
/// Matches the layout expected by `GlyphShader.metal`.
public struct CellInstance {
    /// Position of this cell in the grid (column, row) — used to compute screen position.
    public var gridX: UInt16
    public var gridY: UInt16

    /// UV coordinates in the glyph atlas texture (normalised 0–1).
    public var uvX: Float
    public var uvY: Float
    public var uvWidth: Float
    public var uvHeight: Float

    /// Foreground color (linear RGB, premultiplied alpha).
    public var fgR: Float
    public var fgG: Float
    public var fgB: Float
    public var fgA: Float

    /// Background color (linear RGB, premultiplied alpha).
    public var bgR: Float
    public var bgG: Float
    public var bgB: Float
    public var bgA: Float
}

// MARK: - Atlas Configuration

/// Configuration for the glyph atlas.
public struct GlyphAtlasConfig: Sendable {
    /// Width and height of the atlas texture in pixels.
    /// Must be a power of two for best GPU compatibility.
    public var atlasSize: Int = 2048

    /// Maximum number of unique glyphs cached in the atlas.
    /// When exceeded, the atlas is rebuilt from scratch with only
    /// the glyphs visible in the current grid.
    public var maxGlyphs: Int = 4096

    /// Grid cell size threshold (columns × rows) above which
    /// the Metal renderer is preferred over CoreText.
    public var cellCountThreshold: Int = 12_000 // ~200×60

    /// Whether to enable the Metal renderer regardless of grid size.
    public var forceEnabled: Bool = false

    public init(
        atlasSize: Int = 2048,
        maxGlyphs: Int = 4096,
        cellCountThreshold: Int = 12_000,
        forceEnabled: Bool = false
    ) {
        self.atlasSize = atlasSize
        self.maxGlyphs = maxGlyphs
        self.cellCountThreshold = cellCountThreshold
        self.forceEnabled = forceEnabled
    }
}

// MARK: - MetalGlyphAtlas

/// Manages a texture atlas of rasterised glyphs and provides instanced
/// draw calls for rendering the entire editor grid on the GPU.
///
/// ## Usage
///
/// 1. Create an instance with a `MTLDevice`.
/// 2. Call ``rasterise(_:font:fontSize:)`` for each unique glyph.
/// 3. Build a `CellInstance` buffer from the grid state.
/// 4. Call ``draw(instances:in:renderEncoder:)`` each frame.
///
/// ## Lifecycle
///
/// The atlas is lazily populated. When it runs out of space, it is
/// cleared and repopulated with only the currently visible glyphs.
public final class MetalGlyphAtlas {

    // MARK: - Properties

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var atlasTexture: MTLTexture?
    private var config: GlyphAtlasConfig

    /// Maps glyph keys to their locations in the atlas texture.
    private var glyphCache: [GlyphKey: GlyphAtlasEntry] = [:]

    /// Current packing cursor in the atlas (simple row-based bin packing).
    private var cursorX: Int = 0
    private var cursorY: Int = 0
    private var rowHeight: Int = 0

    /// Whether the atlas has been set up and is ready for rendering.
    public private(set) var isAvailable: Bool = false

    /// The cell size in points (set after the first font measurement).
    public private(set) var cellWidth: CGFloat = 0
    public private(set) var cellHeight: CGFloat = 0

    // MARK: - Init

    /// Create a glyph atlas backed by the given Metal device.
    ///
    /// - Parameters:
    ///   - device: The `MTLDevice` to use for texture and pipeline creation.
    ///   - config: Atlas configuration (texture size, thresholds, etc.).
    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), config: GlyphAtlasConfig = .init()) {
        guard let device else {
            return nil
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        self.config = config

        guard commandQueue != nil else {
            return nil
        }

        do {
            try createAtlasTexture()
            try loadPipeline()
            isAvailable = pipelineState != nil && atlasTexture != nil
        } catch {
            NSLog("[MetalGlyphAtlas] Failed to initialise: \(error)")
            isAvailable = false
        }
    }

    /// Whether the Metal renderer can be used (hardware is capable).
    public var canUseMetalRenderer: Bool { isAvailable && pipelineState != nil && atlasTexture != nil }

    // MARK: - Atlas Texture

    private func createAtlasTexture() throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: config.atlasSize,
            height: config.atlasSize,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .managed

        #if os(iOS) || os(visionOS)
        descriptor.storageMode = .shared
        #endif

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalGlyphAtlasError.textureCreationFailed
        }
        self.atlasTexture = texture
    }

    // MARK: - Pipeline

    private func loadPipeline() throws {
        let library: MTLLibrary
        if let defaultLibrary = device.makeDefaultLibrary() {
            library = defaultLibrary
        } else if let source = loadBundledShaderSource() {
            library = try device.makeLibrary(source: source, options: nil)
            NSLog("[MetalGlyphAtlas] Loaded Metal shader source from app resources.")
        } else {
            NSLog("[MetalGlyphAtlas] No Metal library found and no bundled shader source was available.")
            return
        }

        guard let vertexFunction = library.makeFunction(name: "glyphVertexShader"),
              let fragmentFunction = library.makeFunction(name: "glyphFragmentShader") else {
            throw MetalGlyphAtlasError.shaderFunctionNotFound
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Enable alpha blending for glyph compositing
        let attachment = descriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func loadBundledShaderSource() -> String? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "GlyphShader", withExtension: "metal"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            return source
        }
        #endif

        if let url = Bundle.main.url(forResource: "GlyphShader", withExtension: "metal"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            return source
        }

        return nil
    }

    // MARK: - Glyph Rasterisation

    /// Measure the cell size for the given font.
    ///
    /// Should be called whenever the font changes. All glyphs are rasterised
    /// into cells of this size.
    public func measureCellSize(font: CTFont) {
        var characters: [UniChar] = [77] // "M"
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        var advance = CGSize(width: 0, height: 0)

        if CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 1) {
            _ = CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advance, 1)
        }

        if advance.width <= 0 {
            advance.width = CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, nil, 0)
        }

        if advance.width <= 0 {
            let fallbackString = NSAttributedString(
                string: "M",
                attributes: [.font: font]
            )
            let line = CTLineCreateWithAttributedString(fallbackString)
            advance.width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }

        cellWidth = max(1, advance.width)
        cellHeight = max(1, ceil(CTFontGetAscent(font) + CTFontGetDescent(font)))
    }

    /// Rasterise a glyph and add it to the atlas if not already present.
    ///
    /// - Parameters:
    ///   - key: The glyph key identifying the character and style.
    ///   - font: The CTFont to use for rendering.
    /// - Returns: The atlas entry for the glyph, or `nil` if rasterisation failed.
    @discardableResult
    public func rasterise(_ key: GlyphKey, font: CTFont) -> GlyphAtlasEntry? {
        // Return cached entry if available
        if let existing = glyphCache[key] {
            return existing
        }

        guard let atlasTexture else { return nil }

        // Determine glyph dimensions
        let glyphWidth = Int(ceil(cellWidth))
        let glyphHeight = Int(ceil(cellHeight))

        guard glyphWidth > 0, glyphHeight > 0 else { return nil }

        // Check if we need to advance to the next row
        if cursorX + glyphWidth > config.atlasSize {
            cursorX = 0
            cursorY += rowHeight
            rowHeight = 0
        }

        // Check if the atlas is full
        if cursorY + glyphHeight > config.atlasSize {
            // Atlas is full — clear and start over
            clearAtlas()
            if cursorY + glyphHeight > config.atlasSize {
                return nil // Atlas is too small even for one row
            }
        }

        // Rasterise the glyph into a bitmap
        let bytesPerRow = glyphWidth * 4
        let bitmapData = UnsafeMutableRawPointer.allocate(
            byteCount: bytesPerRow * glyphHeight,
            alignment: 16
        )
        defer { bitmapData.deallocate() }

        // Zero-fill
        bitmapData.initializeMemory(as: UInt8.self, repeating: 0, count: bytesPerRow * glyphHeight)

        guard let context = CGContext(
            data: bitmapData,
            width: glyphWidth,
            height: glyphHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // CoreGraphics has origin at bottom-left; Metal textures read top-down.
        // Drawing in the natural CG coordinate system produces a correctly
        // oriented glyph in the Metal texture (ascenders at the top of the
        // buffer — first in memory — which Metal reads as y=0).

        // Set up for text drawing
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(true)

        let renderFont = GlyphFallbackFonts.cascadedCTFont(base: font)

        // Draw the glyph in white (the shader will apply the actual foreground color).
        let descent = CTFontGetDescent(renderFont)
        let attributedString = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attributedString, CFRangeMake(0, 0), key.characters as CFString)
        let fullRange = CFRangeMake(0, CFAttributedStringGetLength(attributedString))
        CFAttributedStringSetAttribute(attributedString, fullRange, kCTFontAttributeName, renderFont)

        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        CFAttributedStringSetAttribute(attributedString, fullRange, kCTForegroundColorAttributeName, white)

        let line = CTLineCreateWithAttributedString(attributedString)

        // Place baseline at y=descent so descenders reach y=0 (bottom of CG image)
        // and ascenders reach y=height (top of CG image → top of Metal texture).
        context.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(line, context)

        // Upload to the atlas texture
        let region = MTLRegion(
            origin: MTLOrigin(x: cursorX, y: cursorY, z: 0),
            size: MTLSize(width: glyphWidth, height: glyphHeight, depth: 1)
        )
        atlasTexture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: bitmapData,
            bytesPerRow: bytesPerRow
        )

        // Record the entry
        let entry = GlyphAtlasEntry(
            x: UInt16(cursorX),
            y: UInt16(cursorY),
            width: UInt16(glyphWidth),
            height: UInt16(glyphHeight),
            bearingX: 0,
            bearingY: Float(CTFontGetAscent(renderFont)),
            advance: Float(cellWidth)
        )

        glyphCache[key] = entry

        // Advance cursor
        cursorX += glyphWidth
        rowHeight = max(rowHeight, glyphHeight)

        return entry
    }

    /// Clear all cached glyphs and reset the packing cursor.
    public func clearAtlas() {
        glyphCache.removeAll(keepingCapacity: true)
        cursorX = 0
        cursorY = 0
        rowHeight = 0
    }

    // MARK: - Instanced Drawing

    /// Build a cell instance buffer from grid state.
    ///
    /// - Parameters:
    ///   - cells: A 2D array of `(glyph: GlyphKey, fgColor: (Float, Float, Float, Float), bgColor: (Float, Float, Float, Float))` tuples.
    ///   - columns: Number of columns in the grid.
    ///   - rows: Number of rows in the grid.
    /// - Returns: An array of `CellInstance` ready for upload to a Metal buffer.
    public func buildInstanceBuffer(
        cells: [(glyph: GlyphKey, fg: (Float, Float, Float, Float), bg: (Float, Float, Float, Float))],
        columns: Int,
        rows: Int
    ) -> [CellInstance] {
        guard let atlasTexture else { return [] }

        let atlasW = Float(atlasTexture.width)
        let atlasH = Float(atlasTexture.height)

        var instances: [CellInstance] = []
        instances.reserveCapacity(cells.count)

        for (index, cell) in cells.enumerated() {
            let col = index % columns
            let row = index / columns

            let entry = glyphCache[cell.glyph]

            let uvX: Float
            let uvY: Float
            let uvW: Float
            let uvH: Float

            if let entry {
                uvX = Float(entry.x) / atlasW
                uvY = Float(entry.y) / atlasH
                uvW = Float(entry.width) / atlasW
                uvH = Float(entry.height) / atlasH
            } else {
                // Glyph not in atlas — render as blank (background only)
                uvX = 0; uvY = 0; uvW = 0; uvH = 0
            }

            instances.append(CellInstance(
                gridX: UInt16(col),
                gridY: UInt16(row),
                uvX: uvX,
                uvY: uvY,
                uvWidth: uvW,
                uvHeight: uvH,
                fgR: cell.fg.0,
                fgG: cell.fg.1,
                fgB: cell.fg.2,
                fgA: cell.fg.3,
                bgR: cell.bg.0,
                bgG: cell.bg.1,
                bgB: cell.bg.2,
                bgA: cell.bg.3
            ))
        }

        return instances
    }

    /// Encode a draw call for the grid into the given render command encoder.
    ///
    /// - Parameters:
    ///   - instances: The cell instance data (from ``buildInstanceBuffer``).
    ///   - viewportSize: The size of the drawable in pixels.
    ///   - renderEncoder: The active render command encoder.
    public func draw(
        instances: [CellInstance],
        viewportSize: SIMD2<Float>,
        renderEncoder: MTLRenderCommandEncoder
    ) {
        guard let pipelineState, let atlasTexture else { return }
        guard !instances.isEmpty else { return }

        renderEncoder.setRenderPipelineState(pipelineState)

        // Upload instance data
        let instanceSize = MemoryLayout<CellInstance>.stride * instances.count
        guard let instanceBuffer = device.makeBuffer(
            bytes: instances,
            length: instanceSize,
            options: .storageModeShared
        ) else { return }

        // Upload uniforms
        var uniforms = GridUniforms(
            viewportSize: viewportSize,
            cellSize: SIMD2<Float>(Float(cellWidth), Float(cellHeight)),
            atlasSize: SIMD2<Float>(Float(atlasTexture.width), Float(atlasTexture.height))
        )

        renderEncoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<GridUniforms>.stride, index: 1)
        renderEncoder.setFragmentTexture(atlasTexture, index: 0)

        // Draw 6 vertices per cell (two triangles forming a quad), instanced
        renderEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: instances.count
        )
    }

    // MARK: - Statistics

    /// Number of unique glyphs currently cached in the atlas.
    var cachedGlyphCount: Int { glyphCache.count }

    /// Percentage of atlas texture space used (approximate).
    var atlasUtilisation: Double {
        guard config.atlasSize > 0 else { return 0 }
        let totalPixels = config.atlasSize * config.atlasSize
        let usedPixels = cursorY * config.atlasSize + cursorX * rowHeight
        return min(1.0, Double(usedPixels) / Double(totalPixels))
    }
}

// MARK: - Uniforms

/// Uniform data passed to the glyph vertex/fragment shaders.
struct GridUniforms {
    /// Viewport size in pixels.
    var viewportSize: SIMD2<Float>

    /// Cell size in pixels (width, height).
    var cellSize: SIMD2<Float>

    /// Atlas texture size in pixels (width, height).
    var atlasSize: SIMD2<Float>
}

// MARK: - BoxDrawingRenderer (shared helpers)

/// Standalone helpers for drawing box-drawing characters into any CGContext.
/// Used by both `CoreTextRenderer` (direct on-screen drawing) and
/// `MetalGlyphAtlas` (atlas bitmap rasterisation).
///
/// All methods use a **flipped** coordinate system where Y=0 is at the top
/// and increases downward (matching the atlas context's flip transform).
/// In this system: grid "up" = minY, grid "down" = maxY.
enum BoxDrawingRenderer {

    /// Draw straight line segments from the cell center to edges.
    static func drawStraightSegments(
        info: BoxDrawingLookup.Info,
        in context: CGContext,
        cellRect: CGRect,
        cx: CGFloat,
        cy: CGFloat
    ) {
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
            // Flipped context: "up" in grid = toward minY
            context.move(to: CGPoint(x: cx, y: cellRect.minY))
            context.addLine(to: CGPoint(x: cx, y: cy))
            context.strokePath()
        }
        if info.down {
            // Flipped context: "down" in grid = toward maxY
            context.move(to: CGPoint(x: cx, y: cy))
            context.addLine(to: CGPoint(x: cx, y: cellRect.maxY))
            context.strokePath()
        }
    }

    /// Draw double-line segments (two parallel lines per direction).
    static func drawDoubleSegments(
        info: BoxDrawingLookup.Info,
        in context: CGContext,
        cellRect: CGRect,
        cx: CGFloat,
        cy: CGFloat,
        offset: CGFloat
    ) {
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
            if info.up {
                context.move(to: CGPoint(x: cx - offset, y: info.down ? cellRect.maxY : cy))
                context.addLine(to: CGPoint(x: cx - offset, y: cellRect.minY))
                context.strokePath()
                context.move(to: CGPoint(x: cx + offset, y: info.down ? cellRect.maxY : cy))
                context.addLine(to: CGPoint(x: cx + offset, y: cellRect.minY))
                context.strokePath()
            }
            if info.down && !info.up {
                context.move(to: CGPoint(x: cx - offset, y: cy))
                context.addLine(to: CGPoint(x: cx - offset, y: cellRect.maxY))
                context.strokePath()
                context.move(to: CGPoint(x: cx + offset, y: cy))
                context.addLine(to: CGPoint(x: cx + offset, y: cellRect.maxY))
                context.strokePath()
            }
        }
    }

    /// Draw a rounded corner arc connecting two segments.
    /// Uses flipped coordinates: Y=0 at top, increasing downward.
    static func drawRoundedCorner(
        info: BoxDrawingLookup.Info,
        in context: CGContext,
        cellRect: CGRect,
        cx: CGFloat,
        cy: CGFloat
    ) {
        let halfW = cellRect.width / 2
        let halfH = cellRect.height / 2
        let radius = min(halfW, halfH)

        // In flipped context: minY = top, maxY = bottom
        // Grid "up" = minY, grid "down" = maxY
        if info.right && info.down {
            // ╭ — from below (maxY) to right (maxX)
            context.move(to: CGPoint(x: cx, y: cellRect.maxY))
            context.addLine(to: CGPoint(x: cx, y: cy + radius))
            context.addArc(center: CGPoint(x: cx + radius, y: cy + radius),
                           radius: radius,
                           startAngle: .pi,
                           endAngle: .pi * 1.5,
                           clockwise: false)
            context.addLine(to: CGPoint(x: cellRect.maxX, y: cy))
            context.strokePath()
        } else if info.left && info.down {
            // ╮ — from left (minX) to below (maxY)
            context.move(to: CGPoint(x: cellRect.minX, y: cy))
            context.addLine(to: CGPoint(x: cx - radius, y: cy))
            context.addArc(center: CGPoint(x: cx - radius, y: cy + radius),
                           radius: radius,
                           startAngle: .pi * 1.5,
                           endAngle: 0,
                           clockwise: false)
            context.addLine(to: CGPoint(x: cx, y: cellRect.maxY))
            context.strokePath()
        } else if info.left && info.up {
            // ╯ — from above (minY) to left (minX)
            context.move(to: CGPoint(x: cx, y: cellRect.minY))
            context.addLine(to: CGPoint(x: cx, y: cy - radius))
            context.addArc(center: CGPoint(x: cx - radius, y: cy - radius),
                           radius: radius,
                           startAngle: 0,
                           endAngle: .pi * 0.5,
                           clockwise: false)
            context.addLine(to: CGPoint(x: cellRect.minX, y: cy))
            context.strokePath()
        } else if info.right && info.up {
            // ╰ — from right (maxX) to above (minY)
            context.move(to: CGPoint(x: cellRect.maxX, y: cy))
            context.addLine(to: CGPoint(x: cx + radius, y: cy))
            context.addArc(center: CGPoint(x: cx + radius, y: cy - radius),
                           radius: radius,
                           startAngle: .pi * 0.5,
                           endAngle: .pi,
                           clockwise: false)
            context.addLine(to: CGPoint(x: cx, y: cellRect.minY))
            context.strokePath()
        }
    }
}

// MARK: - Render Timing

/// Simple frame timing for benchmarking CoreText vs Metal rendering.
public struct RenderBenchmark {
    private var frameTimes: [CFTimeInterval] = []
    private let maxSamples = 120

    public init() {}

    /// Record a frame's render duration.
    public mutating func record(_ duration: CFTimeInterval) {
        frameTimes.append(duration)
        if frameTimes.count > maxSamples {
            frameTimes.removeFirst(frameTimes.count - maxSamples)
        }
    }

    /// Average frame time in milliseconds.
    public var averageMs: Double {
        guard !frameTimes.isEmpty else { return 0 }
        return (frameTimes.reduce(0, +) / Double(frameTimes.count)) * 1000
    }

    /// 95th percentile frame time in milliseconds.
    public var p95Ms: Double {
        guard !frameTimes.isEmpty else { return 0 }
        let sorted = frameTimes.sorted()
        let idx = min(Int(Double(sorted.count) * 0.95), sorted.count - 1)
        return sorted[idx] * 1000
    }

    /// Number of recorded samples.
    public var sampleCount: Int { frameTimes.count }

    /// Reset all samples.
    public mutating func reset() { frameTimes.removeAll() }
}

// MARK: - Errors

enum MetalGlyphAtlasError: Error, CustomStringConvertible {
    case textureCreationFailed
    case shaderFunctionNotFound
    case pipelineCreationFailed(String)
    case noDevice

    var description: String {
        switch self {
        case .textureCreationFailed:
            return "MetalGlyphAtlas: failed to create atlas texture"
        case .shaderFunctionNotFound:
            return "MetalGlyphAtlas: shader functions not found in Metal library"
        case .pipelineCreationFailed(let reason):
            return "MetalGlyphAtlas: pipeline creation failed — \(reason)"
        case .noDevice:
            return "MetalGlyphAtlas: no Metal device available"
        }
    }
}