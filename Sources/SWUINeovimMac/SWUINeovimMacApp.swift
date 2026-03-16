import SwiftUI
import SWUINeovim
import Transport
#if os(macOS)
import AppKit
#endif

@main
struct SWUINeovimMacApp: App {
    init() {
        UserDefaults.standard.register(defaults: [
            "swuineovim.nvimPath": Self.resolvedNvimPath()
        ])
    }

    /// Returns the first nvim binary found in the well-known install locations
    /// for Homebrew (Apple Silicon and Intel) and MacPorts, falling back to the
    /// Homebrew Apple Silicon path if none is found.
    nonisolated static func resolvedNvimPath() -> String {
        let candidates = [
            "/opt/homebrew/bin/nvim",   // Homebrew – Apple Silicon
            "/usr/local/bin/nvim",      // Homebrew – Intel
            "/opt/local/bin/nvim",      // MacPorts
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? candidates[0]
    }

    var body: some Scene {
        WindowGroup("SWUINeovimMac", id: "local-session") {
            SWUINeovimMacRootView()
            .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            SWUINeovimMacCommands()
        }

        WindowGroup("Remote Session", for: SSHWindowLaunch.self) { launch in
            SWUINeovimMacRootView(initialLaunch: launch.wrappedValue)
                .frame(minWidth: 900, minHeight: 600)
        }

        Settings {
            SWUINeovimMacSettingsView()
        }
    }
}

private struct SSHWindowLaunch: Codable, Hashable, Identifiable {
    enum Mode: String, Codable, Hashable {
        case connectSheet
        case directConnection
    }

    let id: UUID
    let mode: Mode
    let config: SSHConnectionConfig?

    static func connectSheet() -> SSHWindowLaunch {
        SSHWindowLaunch(id: UUID(), mode: .connectSheet, config: nil)
    }

    static func direct(_ config: SSHConnectionConfig) -> SSHWindowLaunch {
        SSHWindowLaunch(id: UUID(), mode: .directConnection, config: config)
    }
}

private struct SWUINeovimMacCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var bookmarkLibrary = SSHBookmarkLibrary.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: "local-session")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New SSH Session…") {
                openWindow(value: SSHWindowLaunch.connectSheet())
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            if !bookmarkLibrary.bookmarks.isEmpty {
                Divider()

                ForEach(bookmarkLibrary.bookmarks) { bookmark in
                    Button("Connect to \(bookmark.name)") {
                        openBookmark(bookmark)
                    }
                }
            }

            Divider()
        }
    }

    private func openBookmark(_ bookmark: SSHBookmark) {
        do {
            openWindow(value: SSHWindowLaunch.direct(try SSHBookmarkStore.makeConfig(for: bookmark)))
        } catch {
            let alert = NSAlert()
            alert.messageText = "SSH Bookmark Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

private struct SWUINeovimMacRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    let initialLaunch: SSHWindowLaunch?

    @State private var controller = MacSessionController()
    @State private var didInitializeSession: Bool = false
    @State private var showSSHConnect: Bool = false
    @State private var window: NSWindow?
    @AppStorage("swuineovim.nvimPath") private var nvimPath: String = SWUINeovimMacApp.resolvedNvimPath()
    @AppStorage("swuineovim.editorFontName") private var editorFontName: String = "Menlo-Regular"
    @AppStorage("swuineovim.editorFontSize") private var editorFontSize: Double = 14
    @AppStorage("swuineovim.metalEnabled") private var metalEnabled: Bool = true

    init(initialLaunch: SSHWindowLaunch? = nil) {
        self.initialLaunch = initialLaunch
    }

    var body: some View {
        #if os(macOS)
        let cellSize = computeCellSize(fontName: editorFontName, fontSize: CGFloat(editorFontSize))
        let flushRevision = controller.flushRevision
        let gridSnapshot = controller.gridSnapshot

        ZStack(alignment: .topLeading) {
            // Layer 1: Editor surface
            EditorGridViewRepresentable(
                controller: controller,
                snapshot: gridSnapshot,
                fontName: editorFontName,
                fontSize: editorFontSize,
                metalEnabled: metalEnabled
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(0)

            if !gridSnapshot.layers.isEmpty {
                MultigridOverlayView(
                    snapshot: gridSnapshot,
                    cellSize: cellSize,
                    fontName: editorFontName,
                    fontSize: editorFontSize
                )
                .zIndex(1)
            }

            // Layer 2: Popup menu overlay
            if controller.session.popupMenu.isVisible {
                PopupMenuOverlayView(
                    state: controller.session.popupMenu,
                    cellSize: cellSize,
                    defaultFG: controller.session.defaultColors.foreground,
                    defaultBG: controller.session.defaultColors.background,
                    gridOrigins: gridSnapshot.gridOrigins,
                    preferBottomAnchor: controller.session.cmdline.isVisible,
                    onSelect: { index in
                        let delta = index - controller.session.popupMenu.selectedIndex
                        if delta > 0 {
                            for _ in 0..<delta {
                                controller.sendInput("<C-n>")
                            }
                        } else if delta < 0 {
                            for _ in 0..<(-delta) {
                                controller.sendInput("<C-p>")
                            }
                        }
                        controller.sendInput("<CR>")
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
                .animation(.easeOut(duration: 0.12), value: controller.session.popupMenu.isVisible)
                .zIndex(2)
            }

            // Layer 3: Messages + command line anchored at bottom
            VStack(spacing: 0) {
                Spacer()

                if !controller.session.messages.isEmpty {
                    MessageOverlayView(
                        messages: controller.session.messages,
                        defaultFG: controller.session.defaultColors.foreground,
                        defaultBG: controller.session.defaultColors.background
                    )
                }

                if controller.session.cmdline.isVisible {
                    CmdlineOverlayView(
                        state: controller.session.cmdline,
                        defaultFG: controller.session.defaultColors.foreground,
                        defaultBG: controller.session.defaultColors.background
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.15), value: controller.session.cmdline.isVisible)
                }
            }
            .zIndex(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.clear
                .opacity(flushRevision.isMultiple(of: 2) ? 0 : 0)
                .allowsHitTesting(false)
        )
        .background(
            WindowAccessor { window in
                self.window = window
                updateWindowTitle(window)
                controller.onRemoteExit = { [weak window] in
                    Task { @MainActor in
                        window?.close()
                    }
                }
            }
        )
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                controller.nvimPath = nvimPath
                controller.updateAppearance(isDark: isSystemDarkMode())

                if !didInitializeSession {
                    didInitializeSession = true

                    switch initialLaunch?.mode {
                    case .connectSheet:
                        showSSHConnect = true
                    case .directConnection:
                        if let config = initialLaunch?.config {
                            controller.connectSSH(config: config)
                        } else {
                            controller.connectLocal()
                        }
                    case nil:
                        controller.connectLocal()
                    }
                }
            }
            .onChange(of: nvimPath) { _, newPath in
                controller.nvimPath = newPath
            }
            .onChange(of: controller.session.title) { _, _ in
                updateWindowTitle(window)
            }
            .onChange(of: controller.currentSSHConfig) { _, _ in
                updateWindowTitle(window)
            }
            .onChange(of: controller.sshConnectionState) { _, _ in
                updateWindowTitle(window)
            }
            .onChange(of: colorScheme) { _, newScheme in
                controller.updateAppearance(isDark: newScheme == .dark)
            }
            .onDisappear {
                controller.onRemoteExit = nil
                controller.disconnect()
            }
            .sheet(isPresented: $showSSHConnect) {
                SSHConnectView(
                    onConnect: { config in
                        showSSHConnect = false
                        controller.nvimPath = nvimPath
                        controller.updateAppearance(isDark: isSystemDarkMode())
                        controller.connectSSH(config: config)
                    },
                    onCancel: {
                        showSSHConnect = false

                        if initialLaunch?.mode == .connectSheet,
                           controller.session.state == .disconnected,
                           !controller.isSSH {
                            Task { @MainActor in
                                window?.close()
                            }
                        }
                    }
                )
            }
        #else
        EmptyView()
        #endif
    }

    #if os(macOS)
    private func isSystemDarkMode() -> Bool {
        guard let best = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) else {
            return false
        }
        return best == .darkAqua
    }

    private func updateWindowTitle(_ window: NSWindow?) {
        guard let window else { return }

        let nvimTitle = controller.session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let config = controller.currentSSHConfig {
            let endpoint = sshEndpointTitle(config)
            window.title = nvimTitle.isEmpty ? endpoint : "\(nvimTitle) — \(endpoint)"
        } else {
            window.title = nvimTitle.isEmpty ? "SWUINeovimMac" : nvimTitle
        }
    }

    private func sshEndpointTitle(_ config: SSHConnectionConfig) -> String {
        let portSuffix = config.port == 22 ? "" : ":\(config.port)"
        return "\(config.username)@\(config.host)\(portSuffix)"
    }

    #endif
}

#if os(macOS)
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}
#endif
