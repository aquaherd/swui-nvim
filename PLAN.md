
# SWUINeovim — Project Plan

> A native SwiftUI frontend for Neovim on macOS and iPadOS, communicating over
> MessagePack-RPC, with CoreText/Metal grid rendering and first-class SSH
> remote support.

---

## 1. Vision & Goals

| Goal | Detail |
|------|--------|
| **Native feel** | Full adherence to Apple HIG on both macOS and iPadOS — menu bar, keyboard shortcuts, trackpad/pointer, multitasking, Stage Manager. |
| **Multiple windows** | macOS `WindowGroup` / iPadOS scenes; each window owns one Neovim session. |
| **Popups as overlays** | Completion menus, hover info, command-line, and wildmenu rendered as SwiftUI overlays on the editor surface, not as separate windows. |
| **High-performance rendering** | Editor grid drawn with CoreText for glyph shaping, optionally backed by a Metal glyph atlas for large/multiple grids. |
| **Remote Neovim** | Built-in SSH transport (`Network.framework` + libssh2-style channel, or `NIOSSH`) so users can attach to a remote `nvim --headless`. |
| **Lightweight App Store review** | Single developer account, no custom crypto, no private API, no embedded interpreters — minimal review friction. |

---

## 2. Architecture Overview

```
/dev/null/architecture.txt#L1-25
┌──────────────────────────────────────────────────────────┐
│                      SwiftUI Shell                       │
│  ┌──────────┐  ┌───────────┐  ┌───────────────────────┐  │
│  │ MenuBar  │  │ TabBar /  │  │  Settings /           │  │
│  │ Commands │  │ WindowMgr │  │  Preferences          │  │
│  └──────────┘  └───────────┘  └───────────────────────┘  │
│                        │                                  │
│         ┌──────────────┴──────────────┐                   │
│         │      EditorSurface          │                   │
│         │  (NSView / UIView repr.)    │                   │
│         │  CoreText + Metal renderer  │                   │
│         │                             │                   │
│         │  ┌─────────────────────┐    │                   │
│         │  │  Overlay Layer      │    │                   │
│         │  │  (popupmenu, hover, │    │                   │
│         │  │   cmdline, messages)│    │                   │
│         │  └─────────────────────┘    │                   │
│         └─────────────┬───────────────┘                   │
│                       │                                   │
│         ┌─────────────┴───────────────┐                   │
│         │   NvimSession (actor)       │                   │
│         │   MsgPack-RPC client        │                   │
│         │   ┌─────────┐ ┌──────────┐  │                   │
│         │   │ Local   │ │ SSH      │  │                   │
│         │   │Transport│ │Transport │  │                   │
│         │   └─────────┘ └──────────┘  │                   │
│         └─────────────────────────────┘                   │
└──────────────────────────────────────────────────────────┘
```

### Layer Responsibilities

| Layer | Responsibility |
|-------|---------------|
| **SwiftUI Shell** | App lifecycle, scenes, windows, menus, settings, navigation. Pure SwiftUI. |
| **EditorSurface** | Platform-specific view (`NSViewRepresentable` / `UIViewRepresentable`) hosting the rendering layer. Handles input events (key, mouse/touch, scroll, IME). |
| **Overlay Layer** | SwiftUI views (`.overlay`) for popupmenu, floating windows, command-line, messages. Positioned via grid coordinates translated to screen points. |
| **NvimSession** | Swift actor managing one Neovim process/connection. Owns the MsgPack-RPC channel, UI event state machine, and redraw queue. |
| **Transport** | Protocol-abstracted byte stream — local `Process` stdio or SSH channel. |

---

## 3. Module Breakdown

### 3.1 `MsgPack` — Pure Swift Codable MessagePack

A small, dependency-free library. Ships as a Swift package embedded in the Xcode project.

| Component | Notes |
|-----------|-------|
| `MsgPackEncoder` | `Encoder` conformance. Produces `Data`. |
| `MsgPackDecoder` | `Decoder` conformance. Consumes `Data` / streaming bytes. |
| `MsgPackValue` | Dynamic enum (`Int`, `String`, `Binary`, `Array`, `Map`, `Ext`, …). `Codable` round-trips. |
| **No C dependencies** | Pure Swift — no review concerns. |

### 3.2 `NvimRPC` — MessagePack-RPC Client

| Component | Notes |
|-----------|-------|
| `RPCMessage` | `enum { request, response, notification }` with `msgid`. |
| `RPCChannel` | Actor. Reads/writes framed messages over an `AsyncStream<UInt8>` pair. Tracks in-flight requests via `AsyncThrowingContinuation`. |
| `NvimAPI` | Auto-generated (or hand-written) typed wrappers for `nvim_*` API functions. |
| `NvimUIEvents` | Parsed redraw batches (`grid_line`, `grid_scroll`, `hl_attr_define`, `mode_change`, `popupmenu_show`, `cmdline_show`, …). |

### 3.3 `Transport` — Local & SSH

```
/dev/null/transport.swift#L1-7
protocol NvimTransport: Sendable {
    func start() async throws
    func send(_ data: Data) async throws
    var received: AsyncThrowingStream<Data, Error> { get }
    func stop() async
}
```

| Variant | Implementation |
|---------|---------------|
| **LocalTransport** | Spawns `nvim --embed` via `Foundation.Process`, pipes stdio. macOS only (iPadOS has no local nvim). |
| **SSHTransport** | Connects via `NIOSSHClient` (SwiftNIO SSH) or a minimal libssh2 wrapper. Runs `nvim --headless --listen` on the remote and tunnels the RPC channel over an SSH exec channel. |

> **App Store note:** `NIOSSH` uses Swift Crypto which wraps Apple CryptoKit on
> Apple platforms — no custom OpenSSL, no export-compliance issues. This is the
> same crypto stack Apple ships in Safari. No ITSAppUsesNonExemptEncryption
> flag required beyond the standard networking exemption.

### 3.4 `GridRenderer` — CoreText + Metal

| Component | Notes |
|-----------|-------|
| `GridState` | 2-D array of `GridCell { character: String, hlID: Int }`. One per `ext_multigrid` grid. |
| `HighlightTable` | Maps `hl_attr_define` IDs → resolved `NSColor`/`UIColor`, font traits, underline/strikethrough styles. |
| `CoreTextRenderer` | For each dirty row, shapes a `CTLine` per run of identical highlight, draws into a `CGContext`. Handles wide chars, emoji, ligatures. Owner-draws box-drawing characters (U+2500–U+257F, rounded corners U+256D–U+2570) as CGContext paths instead of font glyphs for pixel-perfect grid alignment. |
| `BoxDrawingLookup` | Static lookup table mapping ~90 Unicode box-drawing characters to segment connectivity (`left`/`right`/`up`/`down`) and style flags (`heavy`, `rounded`, `double`, `dashed`). Used by `CoreTextRenderer` and forward-compatible with `MetalGlyphAtlas` (same table can drive atlas rasterisation). Defined in `CoreTextRenderer.swift`. |
| `MetalGlyphAtlas` *(opt.)* | Rasterises unique glyphs into a texture atlas; draws the grid as a single instanced draw call. Activated when the grid exceeds a size threshold or user opts in. Falls back to CoreText-only on older hardware. For box-drawing characters, should use `BoxDrawingLookup` + CGContext path drawing into the atlas bitmap instead of `CTLineDraw` (see Phase 5 notes). |
| `CursorRenderer` | Draws block/beam/underline cursor with blink animation via `CADisplayLink`/`CVDisplayLink`. |

### 3.5 `InputHandler` — Keyboard, Mouse, IME

| Platform | Key path |
|----------|----------|
| macOS | `NSViewRepresentable` → `keyDown`, `flagsChanged`, `insertText(_:replacementRange:)`, `scrollWheel`, `mouseDown/Up/Moved/Dragged`. |
| iPadOS | `UIViewRepresentable` + hidden `UITextInput` responder for IME & hardware keyboard. Software keyboard toggle. |

All key events are translated to Neovim's `<C-x>`, `<D-s>`, `<M-…>` notation and sent via `nvim_input()`.

### 3.6 `SwiftUI Shell`

| Component | Platform | Notes |
|-----------|----------|-------|
| `SWUINeovimApp` | Shared | `@main`, `WindowGroup`, `Settings`. |
| `EditorView` | Shared | Wraps `EditorSurface` + overlay layer. Holds `@StateObject` of `NvimSession`. |
| `OverlayPopupMenu` | Shared | SwiftUI `List` overlay for completion popup, positioned by grid cell. |
| `OverlayCmdline` | Shared | SwiftUI text field overlay for `ext_cmdline`. |
| `OverlayMessages` | Shared | Notification-style banners for `ext_messages`. |
| `SessionPickerView` | Shared | Connect to local or remote nvim; saved server bookmarks. |
| `SettingsView` | macOS | `Settings` scene — font, appearance, SSH keys, default args. |
| `SettingsView` | iPadOS | Navigation-based settings inside a sheet. |
| `MultiWindowSupport` | macOS | `openWindow(value:)` to open new nvim sessions. |
| `MultiWindowSupport` | iPadOS | Scene support for Stage Manager / Split View. |

---

## 4. Xcode Project Structure

```
/dev/null/tree.txt#L1-38
SWUINeovim.xcodeproj
│
├── SWUINeovim/                      # App target (macOS + iPadOS)
│   ├── App/
│   │   ├── SWUINeovimApp.swift
│   │   ├── AppCommands.swift        # macOS menu bar commands
│   │   └── AppDelegate.swift        # only if needed for lifecycle hooks
│   ├── Views/
│   │   ├── EditorView.swift
│   │   ├── EditorSurface.swift      # NSViewRepresentable / UIViewRepresentable
│   │   ├── SessionPickerView.swift
│   │   ├── SettingsView.swift
│   │   └── Overlays/
│   │       ├── PopupMenuOverlay.swift
│   │       ├── CmdlineOverlay.swift
│   │       └── MessageOverlay.swift
│   ├── Rendering/
│   │   ├── GridState.swift
│   │   ├── HighlightTable.swift
│   │   ├── CoreTextRenderer.swift
│   │   ├── MetalGlyphAtlas.swift
│   │   ├── CursorRenderer.swift
│   │   └── Shaders/
│   │       └── GlyphShader.metal
│   ├── Input/
│   │   ├── KeyTranslator.swift
│   │   ├── MacInputHandler.swift
│   │   └── IOSInputHandler.swift
│   ├── Session/
│   │   ├── NvimSession.swift        # actor
│   │   ├── NvimUIEvents.swift
│   │   └── NvimAPI.swift
│   ├── Resources/
│   │   ├── Assets.xcassets
│   │   └── Info.plist
│   └── SWUINeovim.entitlements
│
├── Packages/
│   ├── MsgPack/                     # local Swift package
│   │   ├── Sources/MsgPack/
│   │   └── Tests/MsgPackTests/
│   ├── NvimRPC/                     # local Swift package
│   │   ├── Sources/NvimRPC/
│   │   └── Tests/NvimRPCTests/
│   └── Transport/                   # local Swift package
│       ├── Sources/Transport/
│       └── Tests/TransportTests/
│
└── SWUINeovimTests/
    ├── GridStateTests.swift
    ├── KeyTranslatorTests.swift
    └── IntegrationTests.swift
```

### Build & Signing

| Setting | Value |
|---------|-------|
| Team | Single developer Apple ID (Personal Team or individual membership) |
| Bundle ID | `com.<developer>.swuinvim` |
| Deployment targets | macOS 14.0+, iPadOS 17.0+ (to use latest SwiftUI features) |
| Architectures | Apple Silicon (arm64); Intel via Rosetta is acceptable |
| Sandbox | Enabled (App Sandbox) |
| Capabilities | Network (outgoing connections for SSH), Files (user-selected for local nvim binary path) |
| Hardened Runtime | Yes |
| Code signing | Automatic, "Sign to Run Locally" for dev; archive with distribution cert for App Store |

---

## 5. App Store Review Considerations

| Concern | Mitigation |
|---------|-----------|
| **Crypto / export compliance** | SSH transport uses Apple CryptoKit (via Swift Crypto / NIOSSH). Apple's own frameworks — standard ECCN 5D992 mass-market exemption. Answer "Yes, only standard https / TLS / CryptoKit" in App Store Connect. |
| **Embedded interpreter** | No embedded Lua, Python, or shell. Neovim runs as a separate process (macOS) or on a remote machine (iPadOS). |
| **Arbitrary code execution** | The app is a *terminal UI client*, not a code runner. Similar precedent: Blink Shell, Prompt, Termius — all approved. |
| **Private API** | None. CoreText and Metal are public frameworks. |
| **Minimum functionality (iPadOS)** | The app connects to a remote editor and renders its UI. Include onboarding that clearly explains the remote-neovim setup. Provide a "demo" connection option or built-in tutorial buffer if needed. |
| **Age rating** | None — no user-generated content rendered beyond the editor grid, no web views, no social features. Rated 4+. |

---

## 6. Data Flow

```
/dev/null/dataflow.txt#L1-20
User keystroke
  │
  ▼
InputHandler.keyDown()
  │  translate to nvim notation ("<C-a>", "<D-s>", etc.)
  ▼
NvimSession.input("<C-a>")
  │  msgpack-rpc request: nvim_input
  ▼
Transport.send(encoded)
  │  stdio pipe or SSH channel
  ▼
nvim process
  │  processes key, triggers redraw
  ▼
Transport.received
  │  msgpack-rpc notification: redraw [...]
  ▼
NvimSession.handleRedraw(events)
  │  updates GridState, HighlightTable, popupmenu state
  ▼
EditorSurface.setNeedsDisplay()
  │  CoreTextRenderer draws dirty rows
  ▼
Display
```

---

## 7. Implementation Phases

### Phase 0 — Skeleton (Week 1–2)

- [x] Create Xcode project with macOS + iPadOS targets.
- [x] Scaffold directory structure and empty Swift files.
- [x] Implement `MsgPack` encoder/decoder with unit tests.
- [x] Implement `RPCChannel` actor with mock transport tests.

### Phase 1 — Local Rendering (Week 3–5)

- [x] `LocalTransport`: spawn `nvim --embed`, pipe stdio.
- [x] `NvimSession`: attach UI, negotiate capabilities (`ext_multigrid`, `ext_popupmenu`, `ext_cmdline`, `ext_messages`, `ext_linegrid`).
- [x] `GridState` + `HighlightTable`: process `grid_line`, `hl_attr_define`, `grid_scroll`, `grid_resize`.
- [x] `CoreTextRenderer`: draw a single grid into an `NSView`/`UIView`.
- [x] Owner-drawn box-drawing characters: `BoxDrawingLookup` table + `drawBoxDrawingCells()` for pixel-perfect grid lines (light, heavy, double, rounded, dashed variants).
- [x] Basic `InputHandler`: forward keystrokes, handle modifiers.
- [x] **Milestone:** editable Neovim session in a macOS window.

### Phase 2 — SwiftUI Shell (Week 6–7)

- [x] `SWUINeovimApp` with `WindowGroup`.
- [x] macOS menu bar: File (new window, open, close), Edit (undo/redo forwarded to nvim), View (font size), Window.
- [x] iPadOS: keyboard shortcut discoverability overlay.
- [x] `SettingsView`: font picker, shell path, startup arguments.
- [x] Multiple windows — each opens a new `NvimSession`.

### Phase 3 — Overlays (Week 8–9)

- [x] `ext_popupmenu` → `PopupMenuOverlay` (completion list).
- [x] `ext_cmdline` → `CmdlineOverlay` (command-line at bottom).
- [x] `ext_messages` → `MessageOverlay` (notification banners).
- [x] Floating windows (`win_float_pos`) → overlay positioned cards.
- [x] Tooltip / hover overlay for LSP hover info.

### Phase 4 — SSH Transport (Week 10–12)

- [ ] Integrate `NIOSSH` (or `Citadel` which wraps it).
- [ ] `SSHTransport`: connect, authenticate (password, key, agent), exec `nvim --headless`, pipe channel.
- [ ] `SessionPickerView`: saved hosts, identity management (Keychain).
- [ ] iPadOS: SSH is the primary (and only) transport.
- [ ] Connection health: auto-reconnect, latency indicator.

### Phase 5 — Metal Renderer (Week 13–14)

- [x] `MetalGlyphAtlas`: rasterise glyphs into a texture atlas.
- [x] Instanced draw call for the grid (one quad per cell, texture lookup).
- [x] `GlyphShader.metal`: vertex + fragment shader.
- [x] **Box-drawing in atlas**: In `MetalGlyphAtlas.rasterise()`, detect box-drawing characters via `BoxDrawingLookup.info(for:)` and draw them into the atlas bitmap using CGContext path logic (shared with `CoreTextRenderer`) instead of `CTLineDraw`. Extracted `BoxDrawingRenderer` helper that accepts any `CGContext`.
- [x] Benchmarks: `RenderBenchmark` struct tracks avg/p95 frame times for both CoreText and Metal paths. `EditorGridNSView.renderStats` exposes active renderer stats.
- [x] Automatic fallback on unsupported hardware. Metal used when grid exceeds `cellCountThreshold` (12K cells); CoreText otherwise. Falls back gracefully when Metal device unavailable.

### Phase 6 — Polish & App Store (Week 15–17)

- [ ] Full iPadOS support: pointer, trackpad gestures, Split View, Stage Manager, external display.
- [ ] Touch bar support (macOS, if applicable).
- [ ] Accessibility: VoiceOver labels for grid cells, Dynamic Type for UI chrome.
- [ ] Localization stubs (English first).
- [ ] App icon, screenshots, App Store metadata.
- [ ] Privacy policy (no data collected).
- [ ] TestFlight beta → App Store submission.

---

## 8. Dependencies

| Dependency | Purpose | Review risk |
|------------|---------|-------------|
| **Swift Crypto** | Crypto primitives for SSH (wraps CryptoKit) | None — Apple-maintained |
| **SwiftNIO** | Async networking foundation | None — Apple-maintained |
| **NIOSSH** | SSH protocol implementation | Low — Apple-maintained, uses Swift Crypto |
| *None others* | — | — |

> The `MsgPack` codec is written from scratch (small scope, ~800 LOC) to avoid
> pulling in unmaintained third-party packages and to ensure full `Codable`
> integration with Neovim's RPC types.

---

## 9. Neovim UI Protocol Notes

The app attaches as an **external UI** via `nvim_ui_attach(width, height, options)` with:

```
/dev/null/options.swift#L1-10
let uiOptions: [String: NvimValue] = [
    "ext_linegrid":   .bool(true),   // modern grid protocol
    "ext_multigrid":  .bool(true),   // separate grids per window
    "ext_popupmenu":  .bool(true),   // UI renders completion menu
    "ext_cmdline":    .bool(true),   // UI renders command line
    "ext_messages":   .bool(true),   // UI renders messages
    "ext_hlstate":    .bool(true),   // semantic highlight info
    "rgb":            .bool(true),   // 24-bit color
]
```

Key redraw events to handle:

| Event | Purpose |
|-------|---------|
| `grid_resize` | Grid dimensions changed |
| `grid_line` | Row content update (cells with text + hl_id) |
| `grid_scroll` | Scroll region |
| `grid_cursor_goto` | Cursor position |
| `grid_clear` | Clear grid |
| `hl_attr_define` | Define highlight attributes |
| `default_colors_set` | Background/foreground defaults |
| `mode_info_set` / `mode_change` | Cursor shape per mode |
| `win_pos` / `win_float_pos` | Multigrid window placement |
| `popupmenu_show/hide/select` | Completion popup |
| `cmdline_show/hide/pos` | Command line |
| `msg_show/clear` | Messages |
| `flush` | End of redraw batch — commit to screen |

---

## 10. Key Design Decisions

### Why CoreText instead of TextKit / SwiftUI Text?

Neovim sends a **cell grid**, not a text document. Each cell has a character,
width, and highlight ID. CoreText gives us precise per-glyph control:
`CTLineDraw` a run of identically-highlighted cells, position exactly on the
pixel grid. TextKit's paragraph-level layout is unnecessary overhead and
SwiftUI `Text` has no sub-glyph positioning control.

### Why Metal (optional)?

For grids larger than ~200×60 (e.g., 4K/6K displays, or multiple splits), the
CoreText path re-rasterises every dirty row on the CPU. A Metal glyph atlas
lets us cache rasterised glyphs in GPU texture memory and draw the entire grid
in a single instanced draw call — CPU cost drops to "upload cell buffer, issue
draw." This is a meaningful win at high cell counts and high refresh rates.

### Why an actor for NvimSession?

The RPC channel is inherently asynchronous (notifications arrive at any time).
A Swift `actor` serialises access to mutable state (grid contents, highlight
table, pending requests) without manual locking, and integrates cleanly with
Swift Concurrency's `AsyncStream` and `Task` model.

### Why NIOSSH instead of shelling out to `ssh`?

1. iPadOS has no `ssh` binary.
2. In-process SSH gives us direct channel I/O without pty hacks.
3. `NIOSSH` is Apple-maintained, uses CryptoKit, and avoids App Store crypto
   flag complications.

---

## 11. Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| App Store rejects "terminal-like" app on iPadOS | High | Low | Precedent: Blink, Termius, Prompt all approved. Frame as "code editor client." |
| NIOSSH missing features (agent forwarding, ed25519-sk) | Medium | Medium | Fall back to password / key file auth. Contribute upstream. |
| CoreText performance on very large grids | Medium | Low | Metal atlas path as escape hatch. |
| Neovim RPC protocol changes | Low | Low | Pin to stable API level; `nvim_get_api_info()` negotiation. |
| Single developer bus factor | High | — | Clean architecture, comprehensive tests, this document. |

---

## 12. Testing Strategy

| Level | Scope | Tool |
|-------|-------|------|
| **Unit** | MsgPack encode/decode, key translation, grid state mutations, highlight resolution | XCTest |
| **Integration** | Spawn real nvim, attach, send keys, assert grid state | XCTest + `nvim --embed` |
| **Snapshot** | Rendered grid images vs. reference | XCTest image comparison |
| **Manual** | Full user flows on macOS + iPadOS (Simulator & device) | TestFlight |

---

## 13. Future Work (Post-1.0)

- **Tabs**: native macOS tab bar mapped to Neovim tabpages.
- **File browser sidebar**: `nvim_exec_lua` to enumerate files, SwiftUI sidebar.
- **Inline images**: Neovim image protocol support (sixel / kitty graphics).
- **Terminal grid**: embedded `:terminal` rendering with proper ANSI color.
- **Clipboard integration**: bi-directional system clipboard via `nvim_set_var('clipboard')`.
- **Handoff / Universal Clipboard**: resume editing across Mac and iPad.
- **Widgets / Shortcuts**: Siri Shortcuts to connect to a saved server.
- **visionOS**: spatial computing target (longer term).

---

*This document is the single source of truth for the project's architecture,
scope, and phasing. Update it as decisions evolve.*