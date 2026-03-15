// SSHBookmarkStore.swift
// SWUINeovimMac
//
// Persistence for SSH server bookmarks via UserDefaults.

import Foundation
import Transport

/// Simple persistence layer for SSH bookmarks using UserDefaults.
enum SSHBookmarkStore {
    private static let key = "swuineovim.sshBookmarks"

    static func load() -> [SSHBookmark] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SSHBookmark].self, from: data)) ?? []
    }

    static func save(_ bookmarks: [SSHBookmark]) {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: key)
        Task { @MainActor in
            SSHBookmarkLibrary.shared.reload()
        }
    }

    static func makeConfig(for bookmark: SSHBookmark) throws -> SSHConnectionConfig {
        let savedCredential = SSHKeychainHelper.load(forBookmarkID: bookmark.id)
        let auth: SSHAuthentication

        if bookmark.useAgent {
            auth = .agent
        } else if let keyPath = bookmark.privateKeyPath {
            auth = .privateKey(path: keyPath, passphrase: savedCredential)
        } else {
            guard let savedCredential, !savedCredential.isEmpty else {
                throw SSHBookmarkConfigError.missingPassword(bookmark.name)
            }
            auth = .password(savedCredential)
        }

        return SSHConnectionConfig(
            host: bookmark.host,
            port: bookmark.port,
            username: bookmark.username,
            authentication: auth,
            remoteCommand: bookmark.remoteCommand
        )
    }
}

enum SSHBookmarkConfigError: LocalizedError {
    case missingPassword(String)

    var errorDescription: String? {
        switch self {
        case .missingPassword(let name):
            return "No saved password found for \(name). Edit the bookmark and save the password again."
        }
    }
}

@MainActor
final class SSHBookmarkLibrary: ObservableObject {
    static let shared = SSHBookmarkLibrary()

    @Published private(set) var bookmarks: [SSHBookmark] = SSHBookmarkStore.load()

    private init() {}

    func reload() {
        bookmarks = SSHBookmarkStore.load()
    }
}
