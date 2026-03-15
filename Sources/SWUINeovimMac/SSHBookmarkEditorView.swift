// SSHBookmarkEditorView.swift
// SWUINeovimMac
//
// Editor sheet for creating or modifying an SSH server bookmark.

import SwiftUI
import Transport

struct SSHBookmarkEditorView: View {
    let bookmark: SSHBookmark?
    let onSave: (SSHBookmark) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var remoteCommand: String = "nvim --headless --embed"
    @State private var authType: AuthType = .agent
    @State private var password: String = ""
    @State private var privateKeyPath: String = ""
    @State private var passphrase: String = ""

    enum AuthType: String, CaseIterable, Identifiable {
        case agent = "SSH Agent / Default Keys"
        case password = "Password"
        case privateKey = "Private Key File"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Connection") {
                    TextField("Display Name", text: $name)
                    TextField("Host", text: $host)
                        .textContentType(.URL)
                    TextField("Port", text: $port)
                    TextField("Username", text: $username)
                        .textContentType(.username)
                    TextField("Remote Command", text: $remoteCommand)
                        .font(.system(.body, design: .monospaced))
                }

                Section("Authentication") {
                    Picker("Method", selection: $authType) {
                        ForEach(AuthType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch authType {
                    case .agent:
                        Text("Will try ~/.ssh/id_ed25519, id_rsa, id_ecdsa in order.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .password:
                        SecureField("Password", text: $password)
                        Text("Stored securely in the Keychain.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .privateKey:
                        TextField("Key File Path", text: $privateKeyPath)
                            .font(.system(.body, design: .monospaced))
                        SecureField("Passphrase (optional)", text: $passphrase)
                        Text("Passphrase stored securely in the Keychain.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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

                Button("Save") {
                    saveBookmark()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty || username.isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 420)
        .onAppear {
            populateFields(from: bookmark)
        }
        .onChange(of: bookmark?.id) { _, _ in
            populateFields(from: bookmark)
        }
    }

    private func populateFields(from bookmark: SSHBookmark?) {
        name = ""
        host = ""
        port = "22"
        username = ""
        remoteCommand = "nvim --headless --embed"
        authType = .agent
        password = ""
        privateKeyPath = ""
        passphrase = ""

        guard let bm = bookmark else { return }

        name = bm.name
        host = bm.host
        port = String(bm.port)
        username = bm.username
        remoteCommand = bm.remoteCommand

        if bm.useAgent {
            authType = .agent
        } else if bm.privateKeyPath != nil {
            authType = .privateKey
            privateKeyPath = bm.privateKeyPath ?? ""
        } else {
            authType = .password
        }

        if let saved = SSHKeychainHelper.load(forBookmarkID: bm.id) {
            if authType == .password {
                password = saved
            } else if authType == .privateKey {
                passphrase = saved
            }
        }
    }

    private func saveBookmark() {
        let portNum = UInt16(port) ?? 22
        let id = bookmark?.id ?? UUID()

        let bm = SSHBookmark(
            id: id,
            name: name.isEmpty ? "\(username)@\(host)" : name,
            host: host,
            port: portNum,
            username: username,
            remoteCommand: remoteCommand,
            useAgent: authType == .agent,
            privateKeyPath: authType == .privateKey ? privateKeyPath : nil
        )

        // Store credential in Keychain
        switch authType {
        case .password:
            if !password.isEmpty {
                _ = SSHKeychainHelper.save(password: password, forBookmarkID: id)
            }
        case .privateKey:
            if !passphrase.isEmpty {
                _ = SSHKeychainHelper.save(password: passphrase, forBookmarkID: id)
            }
        case .agent:
            SSHKeychainHelper.delete(forBookmarkID: id)
        }

        onSave(bm)
    }
}
