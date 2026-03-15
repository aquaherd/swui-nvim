// SSHKeychainHelper.swift
// SWUINeovimMac
//
// Secure storage for SSH credentials using the macOS/iOS Keychain.

import Foundation
import Security

/// Manages SSH passwords and key passphrases in the system Keychain.
enum SSHKeychainHelper {
    private static let servicePrefix = "com.swuineovim.ssh"

    /// Save a password or passphrase for a bookmark.
    static func save(password: String, forBookmarkID id: UUID) -> Bool {
        let service = "\(servicePrefix).\(id.uuidString)"
        guard let data = password.data(using: .utf8) else { return false }

        // Delete any existing item first
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "ssh-credential",
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve a password or passphrase for a bookmark.
    static func load(forBookmarkID id: UUID) -> String? {
        let service = "\(servicePrefix).\(id.uuidString)"

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "ssh-credential",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a stored password or passphrase for a bookmark.
    static func delete(forBookmarkID id: UUID) {
        let service = "\(servicePrefix).\(id.uuidString)"

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
