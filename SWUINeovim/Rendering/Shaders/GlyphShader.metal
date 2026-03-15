// GlyphShader.metal
// SWUINeovim — Metal vertex + fragment shaders for the glyph atlas renderer.
//
// Draws the editor grid with instanced quads — one quad per cell, with
// texture-atlas lookup per glyph. Each cell renders a background rectangle
// and a foreground glyph sampled from the atlas texture.
//
// The vertex shader expands 6 vertices (two triangles) per instance into a
// quad positioned at the cell's grid coordinates. The fragment shader samples
// the glyph atlas and composites the glyph over the cell background.

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared Structures

/// Per-cell instance data uploaded from the CPU.
/// Scalar fields are used to match Swift's packed struct layout exactly.
struct CellInstance {
    ushort gridX;
    ushort gridY;
    float uvX;
    float uvY;
    float uvWidth;
    float uvHeight;
    float fgR;
    float fgG;
    float fgB;
    float fgA;
    float bgR;
    float bgG;
    float bgB;
    float bgA;
};

/// Uniform data passed once per draw call.
/// Must match `MetalGlyphAtlas.GridUniforms` layout exactly.
struct GridUniforms {
    float2 viewportSize;    // viewport size in pixels
    float2 cellSize;        // cell size in pixels (width, height)
    float2 atlasSize;       // atlas texture size in pixels (width, height)
};

/// Interpolated data from vertex to fragment shader.
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 fgColor;
    float4 bgColor;
    float hasGlyph;         // 1.0 if glyph present, 0.0 for blank cells
};

// MARK: - Vertex Shader

/// Expands each cell instance into a quad (two triangles, 6 vertices).
///
/// Vertex IDs 0–5 map to the quad corners:
///
///     0---1      Triangles: (0,1,2) and (3,4,5)
///     | / |      where 3=2, 4=1 (shared diagonal)
///     2---3
///
/// The quad is positioned at the cell's grid coordinates in clip space.
/// UV coordinates are computed from the atlas entry for glyph sampling.
vertex VertexOut glyphVertexShader(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device CellInstance* instances [[buffer(0)]],
    constant GridUniforms& uniforms [[buffer(1)]]
) {
    const device CellInstance& cell = instances[instanceID];

    // Corner offsets for the quad (normalised 0–1)
    // Vertex order: top-left, top-right, bottom-left, bottom-left, top-right, bottom-right
    constexpr float2 corners[6] = {
        float2(0.0, 0.0),  // top-left
        float2(1.0, 0.0),  // top-right
        float2(0.0, 1.0),  // bottom-left
        float2(0.0, 1.0),  // bottom-left (duplicate)
        float2(1.0, 0.0),  // top-right  (duplicate)
        float2(1.0, 1.0),  // bottom-right
    };

    float2 corner = corners[vertexID];

    // Compute pixel position of this vertex
    float2 cellOrigin = float2(float(cell.gridX), float(cell.gridY)) * uniforms.cellSize;
    float2 pixelPos = cellOrigin + corner * uniforms.cellSize;

    // Convert to clip space: [-1, 1] with Y flipped (top = +1, bottom = -1)
    float2 clipPos;
    clipPos.x = (pixelPos.x / uniforms.viewportSize.x) * 2.0 - 1.0;
    clipPos.y = 1.0 - (pixelPos.y / uniforms.viewportSize.y) * 2.0;

    // Compute texture coordinates from the atlas UV rect
    float2 texCoord = float2(
        cell.uvX + corner.x * cell.uvWidth,
        cell.uvY + corner.y * cell.uvHeight
    );

    // Determine if this cell has a glyph (non-zero UV size)
    float hasGlyph = (cell.uvWidth > 0.0 && cell.uvHeight > 0.0) ? 1.0 : 0.0;

    VertexOut out;
    out.position = float4(clipPos, 0.0, 1.0);
    out.texCoord = texCoord;
    out.fgColor = float4(cell.fgR, cell.fgG, cell.fgB, cell.fgA);
    out.bgColor = float4(cell.bgR, cell.bgG, cell.bgB, cell.bgA);
    out.hasGlyph = hasGlyph;

    return out;
}

// MARK: - Fragment Shader

/// Samples the glyph atlas and composites the glyph over the cell background.
///
/// Glyphs are rasterised in white in the atlas, so the alpha channel carries
/// the glyph shape. We multiply by the foreground color and blend over the
/// background.
fragment float4 glyphFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    // Start with the background color
    float4 color = in.bgColor;

    if (in.hasGlyph > 0.5) {
        constexpr sampler atlasSampler(
            mag_filter::nearest,
            min_filter::nearest,
            address::clamp_to_zero
        );

        float4 glyphSample = atlas.sample(atlasSampler, in.texCoord);

        // The atlas stores white glyphs — alpha carries the shape.
        // Multiply by foreground color to tint the glyph.
        float glyphAlpha = glyphSample.a;
        float4 glyphColor = float4(in.fgColor.rgb * glyphAlpha, glyphAlpha);

        // Alpha-composite glyph over background: src-over blending
        color = glyphColor + color * (1.0 - glyphAlpha);
    }

    return color;
}
