import SwiftUI
import Transport
#if os(macOS)
import AppKit
#endif

struct SWUINeovimMacSettingsView: View {
    @AppStorage("swuineovim.nvimPath") private var nvimPath: String = "/opt/local/bin/nvim"
    @AppStorage("swuineovim.editorFontName") private var editorFontName: String = "Menlo-Regular"
    @AppStorage("swuineovim.editorFontSize") private var editorFontSize: Double = 14
    @AppStorage("swuineovim.metalEnabled") private var metalEnabled: Bool = true
    @Environment(\.colorScheme) private var colorScheme
    @State private var openFontPanelToken: Int = 0
    @State private var fontValidationMessage: String?
    @StateObject private var bookmarkLibrary = SSHBookmarkLibrary.shared
    @State private var editingBookmark: SSHBookmark?
    @State private var showBookmarkEditor = false

    private var currentBackgroundLabel: String {
        colorScheme == .dark ? "dark" : "light"
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            fontTab
                .tabItem { Label("Font", systemImage: "textformat") }

            sshTab
                .tabItem { Label("SSH", systemImage: "network") }
        }
        .frame(width: 520)
        .sheet(isPresented: $showBookmarkEditor) {
            SSHBookmarkEditorView(
                bookmark: editingBookmark,
                onSave: { bookmark in
                    var updated = sshBookmarks
                    if let idx = sshBookmarks.firstIndex(where: { $0.id == bookmark.id }) {
                        updated[idx] = bookmark
                    } else {
                        updated.append(bookmark)
                    }
                    SSHBookmarkStore.save(updated)
                    showBookmarkEditor = false
                },
                onCancel: {
                    showBookmarkEditor = false
                }
            )
        }
        .onAppear {
            bookmarkLibrary.reload()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Neovim") {
                HStack {
                    TextField("", text: $nvimPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    #if os(macOS)
                    Button("Browse…") { browseForNvim() }
                    #endif
                }
                if !nvimPath.isEmpty && !FileManager.default.isExecutableFile(atPath: nvimPath) {
                    Text("File not found or not executable.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Text("Absolute path to the nvim binary for local --embed startup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Text("Theme source: macOS Light/Dark")
                Text("Neovim background: \(currentBackgroundLabel)")
                    .foregroundStyle(.secondary)
                Text("This value is pushed to Neovim as :set background=<light|dark> while connected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            #if os(macOS)
            Section("Renderer") {
                if EditorGridNSView.isMetalAvailable {
                    Toggle("Use Metal GPU Renderer", isOn: $metalEnabled)
                    Text("Renders the editor grid on the GPU. Disable to fall back to CoreText.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Metal GPU Renderer")
                        Spacer()
                        Text("Not available on this Mac")
                            .foregroundStyle(.secondary)
                    }
                    Text("CoreText renderer is in use.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .padding(12)
    }

    // MARK: - Font Tab

    private var fontTab: some View {
        Form {
            Section("Font") {
                HStack {
                    Text("Current")
                    Spacer()
                    Text("\(editorFontName) \(Int(editorFontSize))")
                        .foregroundStyle(.secondary)
                }

                Text("Monospaced fonts only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Stepper(value: $editorFontSize, in: 8...36, step: 1) {
                    Text("Size: \(Int(editorFontSize))")
                }

                if let fontValidationMessage {
                    Text(fontValidationMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                #if os(macOS)
                Button("Pick Font…") {
                    fontValidationMessage = nil
                    openFontPanelToken &+= 1
                }
                FontPanelAccessor(
                    fontName: $editorFontName,
                    fontSize: $editorFontSize,
                    validationMessage: $fontValidationMessage,
                    openToken: openFontPanelToken
                )
                .frame(width: 0, height: 0)
                #endif
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    // MARK: - SSH Tab

    private var sshTab: some View {
        Form {
            Section("SSH Servers") {
                if sshBookmarks.isEmpty {
                    Text("No saved servers. Add one to connect remotely.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sshBookmarks) { bookmark in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(bookmark.name)
                                    .fontWeight(.medium)
                                Text("\(bookmark.username)@\(bookmark.host):\(bookmark.port)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") {
                                editingBookmark = bookmark
                                showBookmarkEditor = true
                            }
                            .buttonStyle(.borderless)
                            Button(role: .destructive) {
                                SSHKeychainHelper.delete(forBookmarkID: bookmark.id)
                                SSHBookmarkStore.save(sshBookmarks.filter { $0.id != bookmark.id })
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add Server…") {
                    editingBookmark = nil
                    showBookmarkEditor = true
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    #if os(macOS)
    private func browseForNvim() {
        let panel = NSOpenPanel()
        panel.title = "Select nvim Binary"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: nvimPath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            nvimPath = url.path
        }
    }
    #endif

    private var sshBookmarks: [SSHBookmark] {
        bookmarkLibrary.bookmarks
    }
}

#if os(macOS)
private struct FontPanelAccessor: NSViewRepresentable {
    @Binding var fontName: String
    @Binding var fontSize: Double
    @Binding var validationMessage: String?
    let openToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(fontName: $fontName, fontSize: $fontSize, validationMessage: $validationMessage)
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.fontName = $fontName
        context.coordinator.fontSize = $fontSize
        context.coordinator.validationMessage = $validationMessage

        guard context.coordinator.lastOpenToken != openToken else { return }
        context.coordinator.lastOpenToken = openToken
        context.coordinator.openPanel()
    }

    final class Coordinator: NSObject {
        var fontName: Binding<String>
        var fontSize: Binding<Double>
        var validationMessage: Binding<String?>
        var lastOpenToken: Int = 0

        init(fontName: Binding<String>, fontSize: Binding<Double>, validationMessage: Binding<String?>) {
            self.fontName = fontName
            self.fontSize = fontSize
            self.validationMessage = validationMessage
        }

        @MainActor
        func openPanel() {
            let currentSize = max(8, CGFloat(fontSize.wrappedValue))
            let current = NSFont(name: fontName.wrappedValue, size: currentSize)
                ?? NSFont.monospacedSystemFont(ofSize: currentSize, weight: .regular)
            let seed = isMonospaced(current)
                ? current
                : NSFont.monospacedSystemFont(ofSize: currentSize, weight: .regular)

            let manager = NSFontManager.shared
            manager.target = self
            manager.action = #selector(changeFont(_:))
            NSFontPanel.shared.setPanelFont(seed, isMultiple: false)
            manager.orderFrontFontPanel(nil)
        }

        @objc
        @MainActor
        func changeFont(_ sender: Any?) {
            let currentSize = max(8, CGFloat(fontSize.wrappedValue))
            let current = NSFont(name: fontName.wrappedValue, size: currentSize)
                ?? NSFont.monospacedSystemFont(ofSize: currentSize, weight: .regular)

            let converted = NSFontManager.shared.convert(current)
            guard isMonospaced(converted) else {
                validationMessage.wrappedValue = "Selected font is not monospaced. Please pick a monospaced font."
                return
            }

            validationMessage.wrappedValue = nil
            fontName.wrappedValue = converted.fontName
            fontSize.wrappedValue = Double(converted.pointSize)
        }

        @MainActor
        private func isMonospaced(_ font: NSFont) -> Bool {
            let traits = CTFontGetSymbolicTraits(font as CTFont)
            return traits.contains(.traitMonoSpace)
        }
    }
}
#endif
