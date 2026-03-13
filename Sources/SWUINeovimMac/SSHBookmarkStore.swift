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
    }
}
