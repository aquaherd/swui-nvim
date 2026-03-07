// SWUINeovimApp.swift
// SWUINeovim
//
// The main SwiftUI application entry point for SWUINeovim.
// Provides WindowGroup for editor sessions, Settings for preferences,
// and macOS menu bar commands.

import SwiftUI

@main
struct SWUINeovimApp: App {

    // MARK: - App State

    /// Tracks whether the user has completed onboarding / first-launch setup.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    /// The user's preferred font family name.
    @AppStorage("editorFontFamily") private var editorFontFamily = "Menlo"

    /// The user's preferred font size in points.
    @AppStorage("editorFontSize") private var editorFontSize: Double = 14.0

    /// Path to the local nvim binary (macOS only).
    @AppStorage("nvimPath") private var nvimPath = "/opt/homebrew/bin/nvim"

    /// Additional arguments passed to nvim on startup.
    @AppStorage("nvimExtraArgs") private var nvimExtraArgs = ""

    #if os(macOS)
    /// Controls whether new windows open with a local or remote session.
    @AppStorage("defaultConnectionMode") private var defaultConnectionMode = "local"
    #else
    /// On iPadOS the only connection mode is remote (SSH).
    private let defaultConnectionMode = "ssh"
    #endif

    // MARK: - Scene

    var body: some Scene {
        // Main editor window — each window owns one NvimSession.
        WindowGroup("SWUINeovim", id: "editor") {
            ContentView()
                .environment(\.editorFontFamily, editorFontFamily)
                .environment(\.editorFontSize, editorFontSize)
        }
        .commands {
            appCommands
        }
        #if os(macOS)
        .defaultSize(width: 960, height: 640)
        #endif

        // Session picker / connection window
        WindowGroup("Connect", id: "session-picker") {
            SessionPickerView()
        }
        #if os(macOS)
        .defaultSize(width: 480, height: 360)
        #endif

        // Settings (macOS) / in-app settings sheet (iPadOS handled in-view)
        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }

    // MARK: - Commands

    @CommandsBuilder
    private var appCommands: some Commands {
        // Replace the default New Window command with our own
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                newEditorWindow()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Connect to Remote…") {
                openSessionPicker()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()
        }

        // Editor-specific commands forwarded to the active NvimSession
        CommandMenu("Editor") {
            Button("Save") {
                NotificationCenter.default.post(name: .nvimCommand, object: "w")
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Save As…") {
                NotificationCenter.default.post(name: .nvimCommand, object: "saveas ")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider()

            Button("Undo") {
                NotificationCenter.default.post(name: .nvimInput, object: "u")
            }
            .keyboardShortcut("z", modifiers: .command)

            Button("Redo") {
                NotificationCenter.default.post(name: .nvimInput, object: "<C-r>")
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Divider()

            Button("Find…") {
                NotificationCenter.default.post(name: .nvimInput, object: "/")
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Find and Replace…") {
                NotificationCenter.default.post(name: .nvimCommand, object: "%s/")
            }
            .keyboardShortcut("h", modifiers: [.command, .option])
        }

        CommandMenu("View") {
            Button("Increase Font Size") {
                editorFontSize = min(editorFontSize + 1, 72)
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Decrease Font Size") {
                editorFontSize = max(editorFontSize - 1, 8)
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Reset Font Size") {
                editorFontSize = 14
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        // Help
        CommandGroup(replacing: .help) {
            Button("SWUINeovim Help") {
                openHelp()
            }
        }
    }

    // MARK: - Actions

    private func newEditorWindow() {
        #if os(macOS)
        if let url = URL(string: "swuinvim://new-editor") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    private func openSessionPicker() {
        #if os(macOS)
        if let url = URL(string: "swuinvim://session-picker") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    private func openHelp() {
        if let url = URL(string: "https://github.com/aquaherd/swuinvim") {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a menu command wants to send a Neovim ex-command (`:command`).
    /// The `object` is a `String` with the command text.
    static let nvimCommand = Notification.Name("com.swuinvim.nvimCommand")

    /// Posted when a menu command wants to send raw Neovim input (`nvim_input`).
    /// The `object` is a `String` with the key sequence.
    static let nvimInput = Notification.Name("com.swuinvim.nvimInput")

    /// Posted when a menu command wants to trigger a UI resize.
    static let nvimResize = Notification.Name("com.swuinvim.nvimResize")
}

// MARK: - Environment Keys

/// Custom environment key for the editor font family name.
private struct EditorFontFamilyKey: EnvironmentKey {
    static let defaultValue: String = "Menlo"
}

/// Custom environment key for the editor font size.
private struct EditorFontSizeKey: EnvironmentKey {
    static let defaultValue: Double = 14.0
}

extension EnvironmentValues {
    var editorFontFamily: String {
        get { self[EditorFontFamilyKey.self] }
        set { self[EditorFontFamilyKey.self] = newValue }
    }

    var editorFontSize: Double {
        get { self[EditorFontSizeKey.self] }
        set { self[EditorFontSizeKey.self] = newValue }
    }
}

// MARK: - Placeholder Views

/// The root content view wrapping the editor surface and overlays.
/// This will be replaced with the full EditorView once the rendering
/// layer is connected.
struct ContentView: View {
    @Environment(\.editorFontFamily) private var fontFamily
    @Environment(\.editorFontSize) private var fontSize

    @StateObject private var session = NvimSession()

    var body: some View {
        ZStack {
            // Background fill matching the Neovim default background
            Color(
                red: Double((session.defaultColors.background >> 16) & 0xFF) / 255.0,
                green: Double((session.defaultColors.background >> 8) & 0xFF) / 255.0,
                blue: Double(session.defaultColors.background & 0xFF) / 255.0
            )
            .ignoresSafeArea()

            // Editor surface placeholder — will be replaced with
            // EditorSurface (NSViewRepresentable / UIViewRepresentable)
            VStack {
                if session.state == .disconnected {
                    WelcomeView()
                } else if session.state == .connecting {
                    ProgressView("Connecting to Neovim…")
                        .progressViewStyle(.circular)
                } else {
                    Text("Editor surface — \(session.title)")
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Overlay layer for popupmenu, cmdline, messages
            overlayLayer
        }
        .onAppear {
            // Auto-connect to local nvim on macOS
            #if os(macOS)
            // Connection will be initiated when EditorSurface is ready
            #endif
        }
    }

    @ViewBuilder
    private var overlayLayer: some View {
        // Popup menu overlay
        if session.popupMenu.isVisible {
            PopupMenuOverlay(
                items: session.popupMenu.items,
                selectedIndex: session.popupMenu.selectedIndex
            )
        }

        // Command line overlay
        if session.cmdline.isVisible {
            CmdlineOverlay(
                firstCharacter: session.cmdline.firstCharacter,
                prompt: session.cmdline.prompt,
                content: session.cmdline.text
            )
        }

        // Message overlay
        if !session.messages.isEmpty {
            MessageOverlay(messages: session.messages)
        }
    }
}

/// A welcome screen shown when no session is active.
struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("SWUINeovim")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("A native Neovim frontend for macOS & iPadOS")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            #if os(macOS)
            HStack(spacing: 16) {
                Button("New Local Session") {
                    // TODO: Start local nvim --embed
                }
                .buttonStyle(.borderedProminent)

                Button("Connect to Remote…") {
                    // TODO: Open session picker
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
            #else
            Button("Connect to Remote Neovim") {
                // TODO: Open session picker
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)

            Text("iPadOS requires a remote Neovim instance via SSH.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            #endif
        }
        .padding(40)
    }
}

// MARK: - Placeholder Overlay Views

/// Placeholder popup menu overlay — will be moved to its own file.
struct PopupMenuOverlay: View {
    let items: [PopupMenuItem]
    let selectedIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.prefix(20).enumerated()), id: \.offset) { index, item in
                HStack {
                    Text(item.word)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    if !item.kind.isEmpty {
                        Text(item.kind)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(index == selectedIndex ? Color.accentColor.opacity(0.3) : Color.clear)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 8)
        .frame(maxWidth: 300)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// Placeholder command line overlay — will be moved to its own file.
struct CmdlineOverlay: View {
    let firstCharacter: String
    let prompt: String
    let content: String

    var body: some View {
        HStack(spacing: 4) {
            Text(firstCharacter.isEmpty ? ":" : firstCharacter)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            if !prompt.isEmpty {
                Text(prompt)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(content)
                .font(.system(.body, design: .monospaced))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 4)
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
    }
}

/// Placeholder message overlay — will be moved to its own file.
struct MessageOverlay: View {
    let messages: [MessageEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(messages.suffix(5)) { message in
                Text(message.text)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 4)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Placeholder Session Picker

/// Placeholder session picker view — will be replaced with a full
/// implementation supporting saved SSH bookmarks.
struct SessionPickerView: View {
    @State private var host = ""
    @State private var username = ""
    @State private var port = "22"

    var body: some View {
        NavigationStack {
            Form {
                Section("Local") {
                    #if os(macOS)
                    Button("Start Local Session") {
                        // TODO: Launch local nvim
                    }
                    #else
                    Text("Local sessions are not available on iPadOS.")
                        .foregroundStyle(.secondary)
                    #endif
                }

                Section("Remote (SSH)") {
                    TextField("Host", text: $host)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    TextField("Username", text: $username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("Port", text: $port)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif

                    Button("Connect") {
                        // TODO: Initiate SSH connection
                    }
                    .disabled(host.isEmpty || username.isEmpty)
                }

                Section("Saved Servers") {
                    Text("No saved servers yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connect")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .frame(minWidth: 320, minHeight: 280)
    }
}

// MARK: - Placeholder Settings View

#if os(macOS)
/// Placeholder settings view for macOS — will be replaced with a full
/// implementation with font picker, shell path, SSH key management, etc.
struct SettingsView: View {
    @AppStorage("editorFontFamily") private var fontFamily = "Menlo"
    @AppStorage("editorFontSize") private var fontSize: Double = 14.0
    @AppStorage("nvimPath") private var nvimPath = "/opt/homebrew/bin/nvim"
    @AppStorage("nvimExtraArgs") private var extraArgs = ""

    var body: some View {
        TabView {
            Form {
                Section("Font") {
                    TextField("Font Family", text: $fontFamily)
                    HStack {
                        Text("Size")
                        Slider(value: $fontSize, in: 8...72, step: 1) {
                            Text("Font Size")
                        }
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 50)
                    }
                    Text("Preview: The quick brown fox jumps over the lazy dog")
                        .font(.custom(fontFamily, size: fontSize))
                        .padding(.vertical, 4)
                }
            }
            .tabItem {
                Label("Appearance", systemImage: "paintbrush")
            }
            .tag("appearance")

            Form {
                Section("Neovim") {
                    TextField("nvim Path", text: $nvimPath)
                    TextField("Extra Arguments", text: $extraArgs)
                        .textFieldStyle(.roundedBorder)
                    Text("Arguments are appended after --embed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tabItem {
                Label("Neovim", systemImage: "terminal")
            }
            .tag("neovim")

            Form {
                Section("SSH") {
                    Text("SSH key management and saved servers will appear here.")
                        .foregroundStyle(.secondary)
                }
            }
            .tabItem {
                Label("SSH", systemImage: "network")
            }
            .tag("ssh")
        }
        .frame(width: 500, height: 350)
        .padding()
    }
}
#endif