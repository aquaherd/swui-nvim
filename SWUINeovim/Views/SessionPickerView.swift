// SessionPickerView.swift
// SWUINeovim
//
// Connection launcher for local and remote Neovim sessions.
// Presents a list of saved SSH bookmarks and a local connection option (macOS only).
// Conforms to Apple HIG: macOS uses a proper window layout, iPadOS uses a sheet/navigation style.

import SwiftUI

// MARK: - Connection Target

/// Describes how to connect to a Neovim instance.
enum ConnectionTarget: Identifiable, Hashable {
    case local(nvimPath: String, arguments: [String])
    case remote(bookmark: SSHBookmarkModel)

    var id: String {
        switch self {
        case .local(let path, _):
            return "local:\(path)"
        case .remote(let bookmark):
            return "remote:\(bookmark.id.uuidString)"
        }
    }

    var displayName: String {
        switch self {
        case .local:
            return "Local Neovim"
        case .remote(let bookmark):
            return bookmark.name
        }
    }

    var subtitle: String {
        switch self {
        case .local(let path, _):
            return path
        case .remote(let bookmark):
            return "\(bookmark.username)@\(bookmark.host):\(bookmark.port)"
        }
    }

    var systemImage: String {
        switch self {
        case .local:
            return "terminal"
        case .remote:
            return "network"
        }
    }
}

// MARK: - SSH Bookmark Model

/// A saved SSH connection bookmark, suitable for SwiftUI binding and persistence.
struct SSHBookmarkModel: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: UInt16 = 22
    var username: String
    var remoteCommand: String = "nvim --headless --embed"
    var useAgent: Bool = true
    var privateKeyPath: String?

    /// A user-readable summary of the connection.
    var summary: String {
        "\(username)@\(host):\(port)"
    }
}

// MARK: - SessionPickerView

/// The main connection launcher view.
///
/// On macOS, this is displayed as the initial window content or as a sheet.
/// On iPadOS, it's presented as a full-screen view or within a NavigationStack.
///
/// Users can:
/// - Start a local Neovim session (macOS only)
/// - Connect to a saved SSH bookmark
/// - Add / edit / delete SSH bookmarks
struct SessionPickerView: View {
    /// Callback invoked when the user selects a connection target.
    var onConnect: (ConnectionTarget) -> Void

    /// Persistent storage for SSH bookmarks.
    @State private var bookmarks: [SSHBookmarkModel] = []

    /// Whether the "Add Bookmark" sheet is presented.
    @State private var isAddingBookmark = false

    /// The bookmark currently being edited (nil = new bookmark).
    @State private var editingBookmark: SSHBookmarkModel?

    /// Local nvim path (macOS only).
    @State private var localNvimPath: String = "/opt/homebrew/bin/nvim"

    /// Extra arguments for local nvim.
    @State private var localExtraArgs: String = ""

    /// Search text for filtering bookmarks.
    @State private var searchText: String = ""

    /// Whether the local settings popover/section is expanded.
    @State private var showLocalSettings = false

    // MARK: - Filtered Bookmarks

    private var filteredBookmarks: [SSHBookmarkModel] {
        if searchText.isEmpty {
            return bookmarks
        }
        let query = searchText.lowercased()
        return bookmarks.filter { bookmark in
            bookmark.name.lowercased().contains(query) ||
            bookmark.host.lowercased().contains(query) ||
            bookmark.username.lowercased().contains(query)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                #if os(macOS)
                localSection
                #endif

                remoteSection
            }
            .navigationTitle("Connect to Neovim")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .searchable(text: $searchText, prompt: "Filter servers")
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .automatic) {
                    addBookmarkButton
                }
                #else
                ToolbarItem(placement: .topBarTrailing) {
                    addBookmarkButton
                }
                #endif
            }
            .sheet(isPresented: $isAddingBookmark) {
                BookmarkEditorView(
                    bookmark: editingBookmark ?? SSHBookmarkModel(
                        name: "",
                        host: "",
                        username: NSUserName()
                    ),
                    isNew: editingBookmark == nil,
                    onSave: { saved in
                        saveBookmark(saved)
                        isAddingBookmark = false
                        editingBookmark = nil
                    },
                    onCancel: {
                        isAddingBookmark = false
                        editingBookmark = nil
                    }
                )
            }
            .onAppear {
                loadBookmarks()
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 500, minHeight: 350, idealHeight: 480)
        #endif
    }

    // MARK: - Local Section (macOS only)

    #if os(macOS)
    private var localSection: some View {
        Section {
            Button {
                let args = localExtraArgs
                    .split(separator: " ")
                    .map(String.init)
                onConnect(.local(nvimPath: localNvimPath, arguments: args))
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local Neovim")
                            .font(.headline)
                        Text(localNvimPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            DisclosureGroup("Local Settings", isExpanded: $showLocalSettings) {
                LabeledContent("nvim path") {
                    TextField("Path to nvim", text: $localNvimPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                }

                LabeledContent("Extra arguments") {
                    TextField("e.g. --clean -u NONE", text: $localExtraArgs)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                }
            }
            .font(.subheadline)
        } header: {
            Label("Local", systemImage: "desktopcomputer")
        }
    }
    #endif

    // MARK: - Remote Section

    private var remoteSection: some View {
        Section {
            if filteredBookmarks.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Servers", systemImage: "externaldrive.badge.wifi")
                } description: {
                    Text("Add an SSH connection to a remote Neovim instance.")
                } actions: {
                    Button("Add Server") {
                        editingBookmark = nil
                        isAddingBookmark = true
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredBookmarks) { bookmark in
                    BookmarkRow(bookmark: bookmark) {
                        onConnect(.remote(bookmark: bookmark))
                    }
                    .contextMenu {
                        Button("Edit") {
                            editingBookmark = bookmark
                            isAddingBookmark = true
                        }
                        Button("Duplicate") {
                            duplicateBookmark(bookmark)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            deleteBookmark(bookmark)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Delete", role: .destructive) {
                            deleteBookmark(bookmark)
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button("Edit") {
                            editingBookmark = bookmark
                            isAddingBookmark = true
                        }
                        .tint(.blue)
                    }
                }
            }
        } header: {
            Label("Remote Servers", systemImage: "network")
        }
    }

    // MARK: - Toolbar

    private var addBookmarkButton: some View {
        Button {
            editingBookmark = nil
            isAddingBookmark = true
        } label: {
            Label("Add Server", systemImage: "plus")
        }
        .help("Add a new SSH server bookmark")
    }

    // MARK: - Persistence

    private static let bookmarksKey = "ssh_bookmarks"

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarksKey),
              let decoded = try? JSONDecoder().decode([SSHBookmarkModel].self, from: data)
        else { return }
        bookmarks = decoded
    }

    private func persistBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarksKey)
    }

    private func saveBookmark(_ bookmark: SSHBookmarkModel) {
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = bookmark
        } else {
            bookmarks.append(bookmark)
        }
        persistBookmarks()
    }

    private func deleteBookmark(_ bookmark: SSHBookmarkModel) {
        bookmarks.removeAll { $0.id == bookmark.id }
        persistBookmarks()
    }

    private func duplicateBookmark(_ bookmark: SSHBookmarkModel) {
        var copy = bookmark
        copy.id = UUID()
        copy.name = "\(bookmark.name) (Copy)"
        bookmarks.append(copy)
        persistBookmarks()
    }
}

// MARK: - BookmarkRow

/// A single row in the server list showing a saved SSH bookmark.
private struct BookmarkRow: View {
    let bookmark: SSHBookmarkModel
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(bookmark.name)
                        .font(.headline)

                    Text(bookmark.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if bookmark.remoteCommand != "nvim --headless --embed" {
                        Text(bookmark.remoteCommand)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if bookmark.useAgent {
                        Label("Agent", systemImage: "key")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if bookmark.privateKeyPath != nil {
                        Label("Key File", systemImage: "key.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Password", systemImage: "lock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - BookmarkEditorView

/// A sheet for adding or editing an SSH bookmark.
private struct BookmarkEditorView: View {
    @State var bookmark: SSHBookmarkModel
    let isNew: Bool
    let onSave: (SSHBookmarkModel) -> Void
    let onCancel: () -> Void

    @State private var authMethod: AuthMethod = .agent

    enum AuthMethod: String, CaseIterable, Identifiable {
        case agent = "SSH Agent"
        case keyFile = "Key File"
        case password = "Password"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Name") {
                        TextField("My Server", text: $bookmark.name)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                    }

                    LabeledContent("Host") {
                        TextField("hostname or IP", text: $bookmark.host)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                    }

                    LabeledContent("Port") {
                        TextField("22", value: $bookmark.port, format: .number)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                            .frame(maxWidth: 80)
                    }

                    LabeledContent("Username") {
                        TextField("user", text: $bookmark.username)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                }

                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: authMethod) { _, newValue in
                        switch newValue {
                        case .agent:
                            bookmark.useAgent = true
                            bookmark.privateKeyPath = nil
                        case .keyFile:
                            bookmark.useAgent = false
                            if bookmark.privateKeyPath == nil {
                                bookmark.privateKeyPath = "~/.ssh/id_ed25519"
                            }
                        case .password:
                            bookmark.useAgent = false
                            bookmark.privateKeyPath = nil
                        }
                    }

                    if authMethod == .keyFile {
                        LabeledContent("Key Path") {
                            TextField("~/.ssh/id_ed25519", text: Binding(
                                get: { bookmark.privateKeyPath ?? "" },
                                set: { bookmark.privateKeyPath = $0.isEmpty ? nil : $0 }
                            ))
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                        }
                    }

                    if authMethod == .password {
                        Text("Password will be requested at connection time and stored securely in the Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if authMethod == .agent {
                        Text("Uses the system SSH agent for key-based authentication.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Remote Command") {
                    TextField("nvim --headless --embed", text: $bookmark.remoteCommand)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif

                    Text("The command executed on the remote host. Must start a Neovim process that communicates over stdin/stdout.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "Add Server" : "Edit Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        onSave(bookmark)
                    }
                    .disabled(!isFormValid)
                }
            }
            .onAppear {
                if bookmark.useAgent {
                    authMethod = .agent
                } else if bookmark.privateKeyPath != nil {
                    authMethod = .keyFile
                } else {
                    authMethod = .password
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 480, minHeight: 420, idealHeight: 500)
        #endif
    }

    private var isFormValid: Bool {
        !bookmark.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !bookmark.host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !bookmark.username.trimmingCharacters(in: .whitespaces).isEmpty &&
        bookmark.port > 0
    }
}

// MARK: - NSUserName Fallback

#if os(iOS)
private func NSUserName() -> String {
    return "user"
}
#endif

// MARK: - Previews

#if DEBUG
#Preview("Session Picker") {
    SessionPickerView { target in
        print("Connect to: \(target.displayName)")
    }
}

#Preview("Session Picker with Bookmarks") {
    SessionPickerView { target in
        print("Connect to: \(target.displayName)")
    }
}

#Preview("Bookmark Editor") {
    BookmarkEditorView(
        bookmark: SSHBookmarkModel(
            name: "Dev Server",
            host: "dev.example.com",
            username: "hakan"
        ),
        isNew: true,
        onSave: { _ in },
        onCancel: {}
    )
}
#endif