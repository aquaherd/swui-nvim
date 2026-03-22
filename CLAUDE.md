# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**swui-nvim** is a native SwiftUI frontend for Neovim on macOS and iPadOS. It communicates with Neovim via MessagePack-RPC and renders using CoreText (CPU) or Metal (GPU-accelerated glyph atlas). It supports both local Neovim processes and remote sessions over SSH.

## Commands

```bash
just build                     # Build SWUINeovimMac (debug)
just build-release             # Release build
just run                       # Run SWUINeovimMac
just test                      # Test entire workspace

# Test individual packages
just test-msgpack              # cd Packages/MsgPack && swift test
just test-nvimrpc              # cd Packages/NvimRPC && swift test

# Distribution (requires env vars, see README)
just stage-release             # Stage app bundle
just sign-release              # Codesign
just notarize-release          # Notarize + staple
just package-notarized         # Copy to dist/
```

Tests live in `Tests/` at the workspace root. Run a single test with:
```bash
swift test --filter MyTestClass/testMethodName
```

## Architecture

The codebase is split into a **shared library** (`SWUINeovim/`) and a **macOS executable** (`Sources/SWUINeovimMac/`), with three independent Swift packages under `Packages/`.

### Layer Stack (top → bottom)

1. **SwiftUI Shell** — app lifecycle, `WindowGroup`, menu bar commands, tab bar, settings
2. **EditorView / EditorSurface** — `NSViewRepresentable`/`UIViewRepresentable` wrapping the rendering surface; hosts SwiftUI overlay layer for popupmenu, cmdline, floating windows
3. **Renderer** — either `CoreTextRenderer` (CPU, CGContext) or `MetalGlyphAtlas` (GPU, instanced draw calls via `GlyphShader.metal`); `GridState` owns the 2D cell array and dirty-region tracking; `HighlightTable` maps Nvim highlight IDs to colors/attributes; `CursorRenderer` handles blink animation
4. **NvimSession (Actor)** — owns the RPC channel, drives the UI state machine, processes `redraw!` events from `NvimUIEvents.swift`, exposes `@Published` grid/cursor/highlight state to SwiftUI
5. **Transport** — protocol-abstracted byte stream; two implementations: `LocalProcessRPCTransport` (spawns nvim) and `SSHRPCTransport` (SwiftNIO SSH channel)

### Packages

| Package | Role |
|---|---|
| `Packages/MsgPack` | Pure-Swift MessagePack encoder/decoder; no dependencies |
| `Packages/NvimRPC` | MessagePack-RPC client; depends on MsgPack |
| `Packages/Transport` | Local-process and SSH transports; depends on SwiftNIO + NIOSSH |

### Key Files

- `SWUINeovim/Session/NvimSession.swift` — central actor; start here to understand session lifecycle
- `SWUINeovim/Session/NvimUIEvents.swift` — parses all Neovim `redraw` event types into typed structs
- `SWUINeovim/Rendering/GridState.swift` — grid cell model, scroll logic, dirty tracking
- `SWUINeovim/Rendering/MetalGlyphAtlas.swift` — GPU glyph atlas; instanced rendering path
- `SWUINeovim/Rendering/Shaders/GlyphShader.metal` — vertex/fragment shaders for grid
- `SWUINeovim/Input/KeyTranslator.swift` — maps platform key events → Neovim notation (`<C-a>`, `<D-s>`, etc.)
- `Sources/SWUINeovimMac/MacSessionController.swift` — macOS session wiring

## Platform Notes

- macOS target: 14+ (Sonoma). iOS/iPadOS target: 17+.
- `#if os(macOS)` / `#if os(iOS)` guards separate platform-specific code; input handlers (`MacInputHandler`, `IOSInputHandler`) and the editor surface are platform-specific.
- Swift 6 concurrency (`actor`, `@MainActor`, `Sendable`) is used throughout; avoid introducing data races.
- Metal renderer is the default on macOS when a Metal device is available; CoreText is the fallback.

## Release Workflow

No Xcode required. All release steps are shell scripts in `scripts/` driven by environment variables:

| Variable | Purpose |
|---|---|
| `SWUINVIM_SHORT_VERSION` | Override `CFBundleShortVersionString` |
| `SWUINVIM_BUILD_VERSION` | Override build number (default: `git rev-list --count HEAD`) |
| `SWUINVIM_DEVELOPMENT_TEAM` | Apple team ID |
| `SWUINVIM_CODESIGN_IDENTITY` | Developer ID Application cert name |
| `SWUINVIM_CODESIGN_ENTITLEMENTS` | Path to entitlements plist (default: `scripts/SWUINeovimMac.entitlements`) |
| `SWUINVIM_NOTARY_PROFILE` | Keychain notarytool profile name |
| `SWUINVIM_NOTARY_APPLE_ID` / `_TEAM_ID` / `_PASSWORD` | Inline notarization credentials |

Output artifacts land in `.build/arm64-apple-macosx/release/` and `dist/release/{signed,notarized}/`.
