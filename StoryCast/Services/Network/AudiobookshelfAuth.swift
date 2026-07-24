import Foundation
import Security
import os

/// Error types for keychain operations
enum KeychainError: LocalizedError {
    case invalidToken
    case saveFailed(Int32)
    case loadFailed(Int32)
    case deleteFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Authentication token is invalid."
        case .saveFailed(let status):
            return "Failed to save token to Keychain (OSStatus \(status))."
        case .loadFailed(let status):
            return "Failed to load token from Keychain (OSStatus \(status))."
        case .deleteFailed(let status):
            return "Failed to delete token from Keychain (OSStatus \(status))."
        }
    }
}

/// Manages Audiobookshelf authentication tokens using the iOS Keychain.
/// Tokens are stored per server URL so multi-server support works correctly.
actor AudiobookshelfAuth {
    static let shared = AudiobookshelfAuth()

    private let service = "StoryCast.AudiobookshelfToken"

    private init() {}

    // MARK: - Token Storage

    /// Saves an API token for the given server URL.
    /// Throws KeychainError if the token cannot be saved.
    func saveToken(_ token: String, for serverURL: String) throws {
        let key = keychainKey(for: serverURL)
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.invalidToken
        }

        // Delete any existing entry first to avoid duplicate-item errors.
        try deleteToken(for: serverURL)

        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            AppLogger.network.error("Keychain save failed for \(key, privacy: .private): \(status)")
            throw KeychainError.saveFailed(status)
        }
    }

    /// Retrieves the stored API token for the given server URL, or nil if absent.
    func token(for serverURL: String) -> String? {
        let key = keychainKey(for: serverURL)
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    /// Removes the stored token for the given server URL.
    /// Throws KeychainError if the deletion fails (excluding not-found cases).
    func deleteToken(for serverURL: String) throws {
        let key = keychainKey(for: serverURL)
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            AppLogger.network.warning("Keychain delete failed for \(key, privacy: .private): \(status)")
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - Private

    private func keychainKey(for serverURL: String) -> String {
        // Normalise the URL so trailing slashes don't create duplicate entries.
        return serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Device Identity

    private static let deviceIDService = "StoryCast.ABSDeviceID"
    private static let deviceIDAccount = "deviceID"

    /// Returns the persistent ABS device ID, migrating from UserDefaults if needed.
    static func absDeviceID() -> String {
        // Check Keychain first
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: deviceIDService,
            kSecAttrAccount as String: deviceIDAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        if SecItemCopyMatching(readQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let id = String(data: data, encoding: .utf8), !id.isEmpty {
            return id
        }

        // Migrate from UserDefaults if present
        if let existing = UserDefaults.standard.string(forKey: "StoryCast.DeviceID"), !existing.isEmpty {
            saveABSDeviceID(existing)
            UserDefaults.standard.removeObject(forKey: "StoryCast.DeviceID")
            return existing
        }

        // Generate new ID
        let newID = UUID().uuidString
        saveABSDeviceID(newID)
        return newID
    }

    private static func saveABSDeviceID(_ id: String) {
        guard let data = id.data(using: .utf8) else { return }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: deviceIDService,
            kSecAttrAccount as String: deviceIDAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(addQuery as CFDictionary)
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Deletes the ABS device ID from Keychain.
    static func deleteABSDeviceID() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: deviceIDService,
            kSecAttrAccount as String: deviceIDAccount
        ] as CFDictionary)
    }
}
