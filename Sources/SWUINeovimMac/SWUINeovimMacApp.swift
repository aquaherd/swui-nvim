import SwiftUI
import SWUINeovim
import Transport
#if os(macOS)
import AppKit
#endif

@main
struct SWUINeovimMacApp: App {
    var body: some Scene {
        WindowGroup("SWUINeovimMac") {
            SWUINeovimMacRootView()
            .frame(minWidth: 900, minHeight: 600)
        }

        Settings {
            SWUINeovimMacSettingsView()
        }
    }
}

private struct SWUINeovimMacRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var controller = MacSessionController()
    @State private var didAutoConnect: Bool = false
    @State private var showSSHConnect: Bool = false
    @State private var sshError: String?
    @AppStorage("swuineovim.nvimPath") private var nvimPath: String = "/opt/local/bin/nvim"
    @AppStorage("swuineovim.editorFontName") private var editorFontName: String = "Menlo-Regular"
    @AppStorage("swuineovim.editorFontSize") private var editorFontSize: Double = 14

    var body: some View {
        #if os(macOS)
        let cellSize = computeCellSize(fontName: editorFontName, fontSize: CGFloat(editorFontSize))

        ZStack(alignment: .topLeading) {
            // Layer 1: Editor surface
            EditorGridViewRepresentable(
                controller: controller,
                fontName: editorFontName,
                fontSize: editorFontSize
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Layer 2: Popup menu overlay
            if controller.session.popupMenu.isVisible {
                PopupMenuOverlayView(
                    state: controller.session.popupMenu,
                    cellSize: cellSize,
                    defaultFG: controller.session.defaultColors.foreground,
                    defaultBG: controller.session.defaultColors.background,
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            WindowAccessor { window in
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

                if !didAutoConnect {
                    didAutoConnect = true
                    controller.connectLocal()
                }
            }
            .onChange(of: nvimPath) { _, newPath in
                controller.nvimPath = newPath
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
                        controller.disconnect()
                        controller.nvimPath = nvimPath
                        controller.updateAppearance(isDark: isSystemDarkMode())
                        controller.connectSSH(config: config)
                    },
                    onCancel: {
                        showSSHConnect = false
                    }
                )
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 8) {
                        if let sshState = controller.sshConnectionState {
                            sshStatusView(sshState)
                        }
                        Button {
                            showSSHConnect = true
                        } label: {
                            Label("SSH", systemImage: "network")
                        }
                        .help("Connect to remote Neovim via SSH")
                    }
                }
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

    @ViewBuilder
    private func sshStatusView(_ state: SSHConnectionState) -> some View {
        switch state {
        case .connecting, .authenticating:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
                    .font(.caption)
            }
        case .connected:
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.green)
                Text("SSH")
                    .font(.caption)
            }
        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .font(.caption)
                    .lineLimit(1)
            }
        case .disconnected:
            EmptyView()
        }
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
