// SettingsView.swift
// SWUINeovim
//
// App preferences for font, shell path, startup arguments, SSH keys,
// and rendering options. Uses the native Settings scene on macOS and
// a navigation-based sheet on iPadOS.

import SwiftUI

// MARK: - User Defaults Keys

extension UserDefaults {
    enum SWUIKeys {
        static let fontName = "SWUINeovim.fontName"
        static let fontSize = "SWUINeovim.fontSize"
        static let lineSpacing = "SWUINeovim.lineSpacing"
        static let nvimPath = "SWUINeovim.nvimPath"
        static let nvimExtraArgs = "SWUINeovim.nvimExtraArgs"
        static let useMetalRenderer = "SWUINeovim.useMetalRenderer"
        static let cursorBlinkEnabled = "SWUINeovim.cursorBlinkEnabled"
        static let sshBookmarks = "SWUINeovim.sshBookmarks"
        static let appearance = "SWUINeovim.appearance"
    }
}

// MARK: - AppSettings Observable

/// Centralized application settings, backed by UserDefaults and
/// published for SwiftUI observation.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: Font

    @Published var fontName: String {
        didSet { UserDefaults.standard.set(fontName, forKey: UserDefaults.SWUIKeys.fontName) }
    }

    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: UserDefaults.SWUIKeys.fontSize) }
    }

    @Published var lineSpacing: Double {
        didSet { UserDefaults.standard.set(lineSpacing, forKey: UserDefaults.SWUIKeys.lineSpacing) }
    }

    // MARK: Neovim

    @Published var nvimPath: String {
        didSet { UserDefaults.standard.set(nvimPath, forKey: UserDefaults.SWUIKeys.nvimPath) }
    }

    @Published var nvimExtraArgs: String {
        didSet { UserDefaults.standard.set(nvimExtraArgs, forKey: UserDefaults.SWUIKeys.nvimExtraArgs) }
    }

    // MARK: Rendering

    @Published var useMetalRenderer: Bool {
        didSet { UserDefaults.standard.set(useMetalRenderer, forKey: UserDefaults.SWUIKeys.useMetalRenderer) }
    }

    @Published var cursorBlinkEnabled: Bool {
        didSet { UserDefaults.standard.set(cursorBlinkEnabled, forKey: UserDefaults.SWUIKeys.cursorBlinkEnabled) }
    }

    // MARK: Appearance

    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: UserDefaults.SWUIKeys.appearance) }
    }

    // MARK: SSH Bookmarks

    @Published var sshBookmarks: [SSHBookmark] {
        didSet { persistSSHBookmarks() }
    }

    // MARK: Init

    private init() {
        let defaults = UserDefaults.standard

        self.fontName = defaults.string(forKey: UserDefaults.SWUIKeys.fontName) ?? "MenloPlatformFont-Regular"
        self.fontSize = defaults.object(forKey: UserDefaults.SWUIKeys.fontSize) as? Double ?? 14.0
        self.lineSpacing = defaults.object(forKey: UserDefaults.SWUIKeys.lineSpacing) as? Double ?? 1.0
        self.nvimPath = defaults.string(forKey: UserDefaults.SWUIKeys.nvimPath) ?? "/opt/homebrew/bin/nvim"
        self.nvimExtraArgs = defaults.string(forKey: UserDefaults.SWUIKeys.nvimExtraArgs) ?? ""
        self.useMetalRenderer = defaults.object(forKey: UserDefaults.SWUIKeys.useMetalRenderer) as? Bool ?? false
        self.cursorBlinkEnabled = defaults.object(forKey: UserDefaults.SWUIKeys.cursorBlinkEnabled) as? Bool ?? true

        let appearanceRaw = defaults.string(forKey: UserDefaults.SWUIKeys.appearance) ?? AppAppearance.system.rawValue
        self.appearance = AppAppearance(rawValue: appearanceRaw) ?? .system

        if let data = defaults.data(forKey: UserDefaults.SWUIKeys.sshBookmarks),
           let decoded = try? JSONDecoder().decode([SSHBookmark].self, from: data) {
            self.sshBookmarks = decoded
        } else {
            self.sshBookmarks = []
        }
    }

    // MARK: Extra Args Parsing

    /// Returns the extra arguments as an array of strings, split by whitespace.
    var nvimExtraArgsArray: [String] {
        nvimExtraArgs
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: Persistence Helpers

    private func persistSSHBookmarks() {
        if let data = try? JSONEncoder().encode(sshBookmarks) {
            UserDefaults.standard.set(data, forKey: UserDefaults.SWUIKeys.sshBookmarks)
        }
    }

    /// Reset all settings to their defaults.
    func resetToDefaults() {
        fontName = "MenloPlatformFont-Regular"
        fontSize = 14.0
        lineSpacing = 1.0
        nvimPath = "/opt/homebrew/bin/nvim"
        nvimExtraArgs = ""
        useMetalRenderer = false
        cursorBlinkEnabled = true
        appearance = .system
    }
}

// MARK: - Appearance Mode

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    #if os(macOS)
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    #endif

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - SSH Bookmark Model

/// A saved SSH server bookmark for the session picker.
/// Passwords and key passphrases are stored in Keychain separately.
struct SSHBookmark: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: UInt16 = 22
    var username: String
    var remoteCommand: String = "nvim --headless --embed"
    var useAgent: Bool = true
    var privateKeyPath: String?

    var displayTitle: String {
        if name.isEmpty {
            return "\(username)@\(host)"
        }
        return name
    }

    var displaySubtitle: String {
        var parts: [String] = []
        parts.append("\(username)@\(host)")
        if port != 22 {
            parts.append("port \(port)")
        }
        if !useAgent, let keyPath = privateKeyPath {
            let filename = (keyPath as NSString).lastPathComponent
            parts.append("key: \(filename)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Settings View

/// The main settings/preferences view.
///
/// On macOS, this is presented in the `Settings` scene (Preferences window).
/// On iPadOS, it's presented as a sheet from the session picker.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    #if os(macOS)
    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag("general")

            FontSettingsTab(settings: settings)
                .tabItem {
                    Label("Font", systemImage: "textformat")
                }
                .tag("font")

            NeovimSettingsTab(settings: settings)
                .tabItem {
                    Label("Neovim", systemImage: "terminal")
                }
                .tag("neovim")

            SSHSettingsTab(settings: settings)
                .tabItem {
                    Label("SSH", systemImage: "network")
                }
                .tag("ssh")

            RenderingSettingsTab(settings: settings)
                .tabItem {
                    Label("Rendering", systemImage: "cpu")
                }
                .tag("rendering")
        }
        .frame(minWidth: 480, minHeight: 320)
        .padding()
    }
    #else
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    GeneralSettingsTab(settings: settings)
                } label: {
                    Label("General", systemImage: "gearshape")
                }

                NavigationLink {
                    FontSettingsTab(settings: settings)
                } label: {
                    Label("Font", systemImage: "textformat")
                }

                NavigationLink {
                    SSHSettingsTab(settings: settings)
                } label: {
                    Label("SSH Servers", systemImage: "network")
                }

                NavigationLink {
                    RenderingSettingsTab(settings: settings)
                } label: {
                    Label("Rendering", systemImage: "cpu")
                }

                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        settings.resetToDefaults()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
    }
    #endif
}

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName)
                            .tag(appearance)
                    }
                }
                #if os(macOS)
                .pickerStyle(.segmented)
                #endif

                Toggle("Cursor Blinking", isOn: $settings.cursorBlinkEnabled)
            } header: {
                Text("Appearance")
            }

            #if os(macOS)
            Section {
                Button("Reset All Settings to Defaults") {
                    settings.resetToDefaults()
                }
                .foregroundColor(.red)
            } header: {
                Text("Reset")
            }
            #endif
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 400)
        #else
        .navigationTitle("General")
        #endif
    }
}

// MARK: - Font Settings Tab

struct FontSettingsTab: View {
    @ObservedObject var settings: AppSettings

    @State private var previewText = "The quick brown fox jumps over the lazy dog.\nfn main() { println!(\"Hello, world!\"); }"

    private var resolvedFont: Font {
        #if os(macOS)
        if let nsFont = NSFont(name: settings.fontName, size: settings.fontSize) {
            return Font(nsFont)
        }
        return .system(size: settings.fontSize, design: .monospaced)
        #else
        if let uiFont = UIFont(name: settings.fontName, size: settings.fontSize) {
            return Font(uiFont)
        }
        return .system(size: settings.fontSize, design: .monospaced)
        #endif
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Font Name")
                    Spacer()
                    TextField("Font Name", text: $settings.fontName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }

                HStack {
                    Text("Font Size")
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            if settings.fontSize > 8 {
                                settings.fontSize -= 1
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)

                        Text("\(Int(settings.fontSize)) pt")
                            .monospacedDigit()
                            .frame(minWidth: 50)

                        Button {
                            if settings.fontSize < 72 {
                                settings.fontSize += 1
                            }
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Line Spacing")
                    Slider(value: $settings.lineSpacing, in: 0.8...2.0, step: 0.05) {
                        Text("Line Spacing")
                    } minimumValueLabel: {
                        Text("0.8")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("2.0")
                            .font(.caption)
                    }
                    Text("Current: \(settings.lineSpacing, specifier: "%.2f")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Font")
            }

            Section {
                Text(previewText)
                    .font(resolvedFont)
                    .lineSpacing(CGFloat(settings.lineSpacing - 1.0) * settings.fontSize)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } header: {
                Text("Preview")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recommended Monospace Fonts")
                        .font(.caption.bold())
                    Text("Menlo, SF Mono, JetBrains Mono, Fira Code, Cascadia Code, Iosevka")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Tips")
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 400)
        #else
        .navigationTitle("Font")
        #endif
    }
}

// MARK: - Neovim Settings Tab (macOS only)

#if os(macOS)
struct NeovimSettingsTab: View {
    @ObservedObject var settings: AppSettings

    @State private var nvimVersionOutput: String = ""
    @State private var isCheckingNvim = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Neovim Path")
                    Spacer()
                    TextField("/opt/homebrew/bin/nvim", text: $settings.nvimPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)

                    Button("Browse…") {
                        browseForNvim()
                    }
                }

                HStack {
                    Text("Extra Arguments")
                    Spacer()
                    TextField("e.g. --clean -u NONE", text: $settings.nvimExtraArgs)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }

                HStack {
                    Button("Check Neovim") {
                        checkNvimVersion()
                    }
                    .disabled(isCheckingNvim)

                    if isCheckingNvim {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if !nvimVersionOutput.isEmpty {
                        Text(nvimVersionOutput)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } header: {
                Text("Local Neovim")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The app launches Neovim with `--embed` automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Common paths: /opt/homebrew/bin/nvim, /usr/local/bin/nvim, /usr/bin/nvim")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Notes")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400)
    }

    private func browseForNvim() {
        let panel = NSOpenPanel()
        panel.title = "Select Neovim Binary"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")

        if panel.runModal() == .OK, let url = panel.url {
            settings.nvimPath = url.path
        }
    }

    private func checkNvimVersion() {
        isCheckingNvim = true
        nvimVersionOutput = ""

        Task {
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: settings.nvimPath)
                process.arguments = ["--version"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                // Extract just the first line (e.g. "NVIM v0.10.0")
                let firstLine = output.components(separatedBy: .newlines).first ?? ""

                await MainActor.run {
                    if process.terminationStatus == 0 {
                        nvimVersionOutput = "✅ \(firstLine)"
                    } else {
                        nvimVersionOutput = "❌ Exit code \(process.terminationStatus)"
                    }
                    isCheckingNvim = false
                }
            } catch {
                await MainActor.run {
                    nvimVersionOutput = "❌ \(error.localizedDescription)"
                    isCheckingNvim = false
                }
            }
        }
    }
}
#endif

// MARK: - SSH Settings Tab

struct SSHSettingsTab: View {
    @ObservedObject var settings: AppSettings

    @State private var isAddingBookmark = false
    @State private var editingBookmark: SSHBookmark?

    var body: some View {
        Form {
            Section {
                if settings.sshBookmarks.isEmpty {
                    ContentUnavailableView {
                        Label("No Saved Servers", systemImage: "network.slash")
                    } description: {
                        Text("Add an SSH server to connect to a remote Neovim instance.")
                    } actions: {
                        Button("Add Server") {
                            isAddingBookmark = true
                        }
                    }
                } else {
                    ForEach(settings.sshBookmarks) { bookmark in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookmark.displayTitle)
                                    .font(.body.bold())
                                Text(bookmark.displaySubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                editingBookmark = bookmark
                            } label: {
                                Image(systemName: "pencil.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { indexSet in
                        settings.sshBookmarks.remove(atOffsets: indexSet)
                    }
                }

                if !settings.sshBookmarks.isEmpty {
                    Button {
                        isAddingBookmark = true
                    } label: {
                        Label("Add Server", systemImage: "plus")
                    }
                }
            } header: {
                Text("SSH Servers")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Authentication")
                        .font(.caption.bold())
                    Text("SSH agent authentication is recommended. Passwords and key passphrases are stored securely in the system Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("SSH Library")
                        .font(.caption.bold())
                    Text("Connections use Apple's CryptoKit via NIOSSH — no custom cryptography, fully App Store compliant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Notes")
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 400)
        #else
        .navigationTitle("SSH Servers")
        #endif
        .sheet(isPresented: $isAddingBookmark) {
            SSHBookmarkEditor(bookmark: .constant(SSHBookmark(
                name: "",
                host: "",
                username: NSUserName()
            ))) { newBookmark in
                settings.sshBookmarks.append(newBookmark)
                isAddingBookmark = false
            } onCancel: {
                isAddingBookmark = false
            }
        }
        .sheet(item: $editingBookmark) { bookmark in
            SSHBookmarkEditor(
                bookmark: Binding(
                    get: { bookmark },
                    set: { updated in
                        if let index = settings.sshBookmarks.firstIndex(where: { $0.id == bookmark.id }) {
                            settings.sshBookmarks[index] = updated
                        }
                    }
                )
            ) { updatedBookmark in
                if let index = settings.sshBookmarks.firstIndex(where: { $0.id == bookmark.id }) {
                    settings.sshBookmarks[index] = updatedBookmark
                }
                editingBookmark = nil
            } onCancel: {
                editingBookmark = nil
            }
        }
    }
}

// MARK: - SSH Bookmark Editor

struct SSHBookmarkEditor: View {
    @Binding var bookmark: SSHBookmark

    var onSave: (SSHBookmark) -> Void
    var onCancel: () -> Void

    @State private var localBookmark: SSHBookmark

    init(
        bookmark: Binding<SSHBookmark>,
        onSave: @escaping (SSHBookmark) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._bookmark = bookmark
        self.onSave = onSave
        self.onCancel = onCancel
        self._localBookmark = State(initialValue: bookmark.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display Name", text: $localBookmark.name)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Name")
                } footer: {
                    Text("Optional. If empty, shows username@host.")
                }

                Section {
                    TextField("Hostname or IP", text: $localBookmark.host)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("22", value: $localBookmark.port, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 80)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }

                    TextField("Username", text: $localBookmark.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Connection")
                }

                Section {
                    Toggle("Use SSH Agent", isOn: $localBookmark.useAgent)

                    if !localBookmark.useAgent {
                        HStack {
                            Text("Private Key Path")
                            Spacer()
                            TextField("~/.ssh/id_ed25519", text: Binding(
                                get: { localBookmark.privateKeyPath ?? "" },
                                set: { localBookmark.privateKeyPath = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif

                            #if os(macOS)
                            Button("Browse…") {
                                browseForKey()
                            }
                            #endif
                        }
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("SSH agent is the recommended authentication method.")
                }

                Section {
                    TextField("nvim --headless --embed", text: $localBookmark.remoteCommand)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Remote Command")
                } footer: {
                    Text("The command executed on the remote host. Defaults to nvim --headless --embed.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(localBookmark.name.isEmpty ? "New Server" : localBookmark.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(localBookmark)
                    }
                    .disabled(localBookmark.host.isEmpty || localBookmark.username.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 400)
        #endif
    }

    #if os(macOS)
    private func browseForKey() {
        let panel = NSOpenPanel()
        panel.title = "Select SSH Private Key"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")

        if panel.runModal() == .OK, let url = panel.url {
            localBookmark.privateKeyPath = url.path
        }
    }
    #endif
}

// MARK: - Rendering Settings Tab

struct RenderingSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Use Metal GPU Renderer", isOn: $settings.useMetalRenderer)

                VStack(alignment: .leading, spacing: 4) {
                    Text("When enabled, the editor grid is rendered using a Metal glyph atlas for improved performance on large grids (4K+ displays, many splits).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("When disabled, CoreText renders each row directly — lower latency for typical grid sizes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Renderer")
            }

            Section {
                Toggle("Cursor Blinking", isOn: $settings.cursorBlinkEnabled)
            } header: {
                Text("Cursor")
            }

            Section {
                HStack {
                    Text("Metal Device")
                    Spacer()
                    Text(metalDeviceName)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("GPU Info")
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 400)
        #else
        .navigationTitle("Rendering")
        #endif
    }

    private var metalDeviceName: String {
        #if canImport(Metal)
        import Metal
        #endif
        // We can't import Metal conditionally in the computed property,
        // so we use a runtime check.
        if let device = MTLCreateSystemDefaultDevice() {
            return device.name
        }
        return "Not available"
    }
}

// MARK: - Metal Import for GPU Info

import Metal

// MARK: - Preview

#if DEBUG
#Preview("Settings") {
    SettingsView()
}

#Preview("SSH Bookmark Editor") {
    SSHBookmarkEditor(
        bookmark: .constant(SSHBookmark(
            name: "Dev Server",
            host: "dev.example.com",
            username: "hakan"
        )),
        onSave: { _ in },
        onCancel: { }
    )
}
#endif