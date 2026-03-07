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
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

// MARK: - Glyph Key

/// Identifies a unique glyph in the atlas by its character content and style.
struct GlyphKey: Hashable, Sendable {
    /// The character(s) to render — may be a single Unicode scalar or a grapheme cluster.
    let characters: String

    /// Whether the glyph is bold.
    let bold: Bool

    /// Whether the glyph is italic.
    let italic: Bool

    /// Font size in points.
    let fontSize: CGFloat
}

// MARK: - Atlas Entry

/// Location of a rasterised glyph within the texture atlas.
struct GlyphAtlasEntry: Sendable {
    /// Position in the atlas texture (pixels).
    let x: UInt16
    let y: UInt16

    /// Size of the glyph region in the atlas (pixels).
    let width: UInt16
    let height: UInt16

    /// Offset from the cell origin to the glyph origin (pixels).
    let bearingX: Float
    let bearingY: Float

    /// The advance width of the glyph (pixels).
    let advance: Float
}

// MARK: - Cell Instance (GPU buffer element)

/// Per-cell data uploaded to the GPU for instanced rendering.
/// Matches the layout expected by `GlyphShader.metal`.
struct CellInstance {
    /// Position of this cell in the grid (column, row) — used to compute screen position.
    var gridX: UInt16
    var gridY: UInt16

    /// UV coordinates in the glyph atlas texture (normalised 0–1).
    var uvX: Float
    var uvY: Float
    var uvWidth: Float
    var uvHeight: Float

    /// Foreground color (linear RGB, premultiplied alpha).
    var fgR: Float
    var fgG: Float
    var fgB: Float
    var fgA: Float

    /// Background color (linear RGB, premultiplied alpha).
    var bgR: Float
    var bgG: Float
    var bgB: Float
    var bgA: Float
}

// MARK: - Atlas Configuration

/// Configuration for the glyph atlas.
struct GlyphAtlasConfig: Sendable {
    /// Width and height of the atlas texture in pixels.
    /// Must be a power of two for best GPU compatibility.
    var atlasSize: Int = 2048

    /// Maximum number of unique glyphs cached in the atlas.
    /// When exceeded, the atlas is rebuilt from scratch with only
    /// the glyphs visible in the current grid.
    var maxGlyphs: Int = 4096

    /// Grid cell size threshold (columns × rows) above which
    /// the Metal renderer is preferred over CoreText.
    var cellCountThreshold: Int = 12_000 // ~200×60

    /// Whether to enable the Metal renderer regardless of grid size.
    var forceEnabled: Bool = false
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
final class MetalGlyphAtlas {

    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
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
    private(set) var isAvailable: Bool = false

    /// The cell size in points (set after the first font measurement).
    private(set) var cellWidth: CGFloat = 0
    private(set) var cellHeight: CGFloat = 0

    // MARK: - Init

    /// Create a glyph atlas backed by the given Metal device.
    ///
    /// - Parameters:
    ///   - device: The `MTLDevice` to use for texture and pipeline creation.
    ///   - config: Atlas configuration (texture size, thresholds, etc.).
    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), config: GlyphAtlasConfig = .init()) {
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
            isAvailable = true
        } catch {
            NSLog("[MetalGlyphAtlas] Failed to initialise: \(error)")
            isAvailable = false
        }
    }

    /// Whether the Metal renderer should be used for the given grid dimensions.
    func shouldUseMetalRenderer(columns: Int, rows: Int) -> Bool {
        guard isAvailable else { return false }
        if config.forceEnabled { return true }
        return columns * rows >= config.cellCountThreshold
    }

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
        // Look for the shader library in the main bundle.
        // In development, the .metal file is compiled into default.metallib.
        guard let library = try? device.makeDefaultLibrary() else {
            // If there's no compiled metallib yet (e.g., first build), we defer.
            NSLog("[MetalGlyphAtlas] No Metal library found — pipeline will be created on first use.")
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

    // MARK: - Glyph Rasterisation

    /// Measure the cell size for the given font.
    ///
    /// Should be called whenever the font changes. All glyphs are rasterised
    /// into cells of this size.
    func measureCellSize(font: CTFont) {
        let spaceGlyph: [CGGlyph] = [CTFontGetGlyphWithName(font, "space" as CFString)]
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, spaceGlyph, &advance, 1)

        cellWidth = ceil(advance.width)
        cellHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    /// Rasterise a glyph and add it to the atlas if not already present.
    ///
    /// - Parameters:
    ///   - key: The glyph key identifying the character and style.
    ///   - font: The CTFont to use for rendering.
    /// - Returns: The atlas entry for the glyph, or `nil` if rasterisation failed.
    @discardableResult
    func rasterise(_ key: GlyphKey, font: CTFont) -> GlyphAtlasEntry? {
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

        // Flip coordinates (CoreGraphics has origin at bottom-left)
        context.translateBy(x: 0, y: CGFloat(glyphHeight))
        context.scaleBy(x: 1.0, y: -1.0)

        // Set up for text drawing
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(true)

        // Draw the glyph in white (the shader will apply the actual foreground color)
        let attributedString = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attributedString, CFRangeMake(0, 0), key.characters as CFString)
        let fullRange = CFRangeMake(0, CFAttributedStringGetLength(attributedString))
        CFAttributedStringSetAttribute(attributedString, fullRange, kCTFontAttributeName, font)

        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        CFAttributedStringSetAttribute(attributedString, fullRange, kCTForegroundColorAttributeName, white)

        let line = CTLineCreateWithAttributedString(attributedString)
        let ascent = CTFontGetAscent(font)

        context.textPosition = CGPoint(x: 0, y: ascent)
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
            bearingY: Float(ascent),
            advance: Float(cellWidth)
        )

        glyphCache[key] = entry

        // Advance cursor
        cursorX += glyphWidth
        rowHeight = max(rowHeight, glyphHeight)

        return entry
    }

    /// Clear all cached glyphs and reset the packing cursor.
    func clearAtlas() {
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
    func buildInstanceBuffer(
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
    func draw(
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