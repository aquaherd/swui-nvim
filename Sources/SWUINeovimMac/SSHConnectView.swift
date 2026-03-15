// SSHConnectView.swift
// SWUINeovimMac
//
// Sheet for connecting to an SSH server from the main editor window.

import SwiftUI
import Transport

struct SSHConnectView: View {
    let onConnect: (SSHConnectionConfig) -> Void
    let onCancel: () -> Void

    @StateObject private var bookmarkLibrary = SSHBookmarkLibrary.shared
    @State private var selectedBookmark: SSHBookmark?
    @State private var errorMessage: String?

    // Quick connect fields
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var password: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("Connect to Remote Neovim")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Form {
                if !bookmarks.isEmpty {
                    Section("Saved Servers") {
                        ForEach(bookmarks) { bookmark in
                            Button(action: {
                                connectWithBookmark(bookmark)
                            }) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(bookmark.name)
                                            .fontWeight(.medium)
                                        Text("\(bookmark.username)@\(bookmark.host):\(bookmark.port)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Quick Connect") {
                    TextField("Host", text: $host)
                        .textContentType(.URL)
                    TextField("Port", text: $port)
                    TextField("Username", text: $username)
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Connect") {
                    quickConnect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty || username.isEmpty)
            }
            .padding()
        }
        .frame(width: 420, height: bookmarks.isEmpty ? 300 : 450)
        .onAppear {
            bookmarkLibrary.reload()
            errorMessage = nil
        }
    }

    private var bookmarks: [SSHBookmark] {
        bookmarkLibrary.bookmarks
    }

    private func connectWithBookmark(_ bookmark: SSHBookmark) {
        errorMessage = nil

        do {
            onConnect(try SSHBookmarkStore.makeConfig(for: bookmark))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func quickConnect() {
        errorMessage = nil
        let portNum = UInt16(port) ?? 22
        let auth: SSHAuthentication = password.isEmpty ? .agent : .password(password)
        let config = SSHConnectionConfig(
            host: host,
            port: portNum,
            username: username,
            authentication: auth
        )
        onConnect(config)
    }
}
