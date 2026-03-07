// GlyphShader.metal
// SWUINeovim — Metal vertex + fragment shaders for the glyph atlas renderer.
//
// Used by MetalGlyphAtlas (Phase 5) to draw the editor grid with instanced
// quads — one quad per cell, texture-atlas lookup per glyph.
//
// Phase 5 implementation plan:
//   Vertex shader  — take per-instance cell position + atlas UV; output clip-space quad.
//   Fragment shader — sample glyph atlas texture, multiply by foreground colour.
//   Background pass — solid rect per cell using background colour attribute.

#include <metal_stdlib>
using namespace metal;

// TODO(phase5): define GlyphInstance struct matching MetalGlyphAtlas.GlyphInstance.
// TODO(phase5): vertex shader — instanced quad expansion from cell (col, row) + atlas rect.
// TODO(phase5): fragment shader — atlas texture sample + foreground colour blend.
// TODO(phase5): background rect pass.
