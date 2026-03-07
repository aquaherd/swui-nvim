import SwiftUI
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
    @State private var controller = Phase1SessionController()
    @State private var didAutoConnect: Bool = false
    @AppStorage("swuineovim.nvimPath") private var nvimPath: String = "/opt/local/bin/nvim"
    @AppStorage("swuineovim.editorFontName") private var editorFontName: String = "Menlo-Regular"
    @AppStorage("swuineovim.editorFontSize") private var editorFontSize: Double = 14

    var body: some View {
        #if os(macOS)
        EditorGridViewRepresentable(
            controller: controller,
            fontName: editorFontName,
            fontSize: editorFontSize
        )
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
