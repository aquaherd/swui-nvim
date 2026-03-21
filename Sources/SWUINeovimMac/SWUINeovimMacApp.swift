import SwiftUI
import MsgPack
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

#if os(macOS)
    NSWindow.allowsAutomaticWindowTabbing = false
#endif
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
    @Environment(\..colorScheme) private var colorScheme
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
        let tabline = controller.session.tabline

        VStack(spacing: 0) {
            if tabline.tabs.count > 1 {
                NvimTabBarView(
                    tabs: tabline.tabs,
                    currentTabHandle: tabline.currentTabHandle,
                    onSelect: { handle in
                        Task {
                            try? await controller.session.selectTab(handle: handle)
                        }
                    },
                    onNewTab: {
                        Task {
                            try? await controller.session.command("tabnew")
                        }
                    },
                    onCloseCurrentTab: {
                        Task {
                            try? await controller.session.command("tabclose")
                        }
                    }
                )
            }

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
private struct NvimTabBarView: View {
    let tabs: [TabInfo]
    let currentTabHandle: MsgPackValue
    let onSelect: (MsgPackValue) -> Void
    let onNewTab: () -> Void
    let onCloseCurrentTab: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Scrollable tab pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(tabs.enumerated()), id: \.element.handle) { index, tab in
                        NvimTabPillView(
                            label: tabLabel(tab, index: index),
                            isSelected: tab.handle == currentTabHandle,
                            onSelect: { onSelect(tab.handle) },
                            onClose: tab.handle == currentTabHandle ? onCloseCurrentTab : nil
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            // New-tab button
            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Tab")
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tabLabel(_ tab: TabInfo, index: Int) -> String {
        guard !tab.name.isEmpty else { return "[No Name]" }
        let basename = URL(fileURLWithPath: tab.name).lastPathComponent
        return basename.isEmpty ? tab.name : basename
    }
}

private struct NvimTabPillView: View {
    let label: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)

                Text(label)
                    .lineLimit(1)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)

                // Close button — shown on active tab always, or on any tab while hovered
                if onClose != nil || isHovered {
                    Button {
                        onClose?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .frame(width: 14, height: 14)
                            .background(
                                Circle().fill(isSelected
                                    ? Color.primary.opacity(0.15)
                                    : Color.clear
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? Color.primary.opacity(0.7) : Color.secondary)
                    .opacity((onClose != nil || isHovered) ? 1 : 0)
                    .help("Close Tab")
                } else {
                    // Placeholder to keep pill width stable
                    Color.clear.frame(width: 14, height: 14)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected
                    ? Color.primary.opacity(0.10)
                    : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.primary.opacity(0.18) : Color.clear,
                    lineWidth: 0.5
                )
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .animation(.easeOut(duration: 0.1), value: isSelected)
    }
}

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
            nsView.window?.tabbingMode = .disallowed
            onResolve(nsView.window)
        }
    }
}
#endif
