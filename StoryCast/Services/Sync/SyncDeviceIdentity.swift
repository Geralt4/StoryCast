import Foundation
import Security

enum SyncDeviceIdentityError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Unable to read the sync device identity (OSStatus \(status))."
        }
    }
}

/// A device-only ID distinguishes independent progress heads without copying the
/// identity to another device through backups or iCloud Keychain.
actor SyncDeviceIdentity {
    static let shared = SyncDeviceIdentity()

    private let service = "StoryCast.SyncDeviceIdentity"
    private let account = "current"

    private init() {}

    func identifier() throws -> String {
        if let existing = readIdentifier() {
            return existing
        }

        let identifier = UUID().uuidString.lowercased()
        guard let data = identifier.data(using: .utf8) else {
            throw SyncDeviceIdentityError.keychain(errSecParam)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = readIdentifier() {
            return existing
        }
        guard status == errSecSuccess else {
            throw SyncDeviceIdentityError.keychain(status)
        }
        return identifier
    }

    private func readIdentifier() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let identifier = String(data: data, encoding: .utf8),
              UUID(uuidString: identifier) != nil else {
            return nil
        }
        return identifier
    }
}
