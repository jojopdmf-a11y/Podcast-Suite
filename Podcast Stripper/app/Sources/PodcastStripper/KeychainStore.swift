import Foundation
import Security

enum HuggingFaceKeychain {
    static let service = "com.podcaststripper.huggingface"
    static let account = "hf_token"

    /// Returns the token, or nil if missing / user denied Keychain access.
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty == false) ? token : nil
    }

    /// Existence check that avoids forcing a password prompt when possible.
    static func hasSavedToken() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess
    }

    static func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeychainError.empty
        }
        let data = Data(trimmed.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Clear any ACL-locked leftover from an older unsigned build.
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        add[kSecAttrLabel as String] = "Podcast Stripper Hugging Face token"
        // nil trusted-app list ⇒ any rebuild of this app can read it after unlock.
        // Fine for a personal HF read token on your own Mac; avoids Keychain hell
        // every time we rebuild an ad-hoc signed app.
        var access: SecAccess?
        if SecAccessCreate(
            "Podcast Stripper Hugging Face token" as CFString,
            nil,
            &access
        ) == errSecSuccess, let access {
            add[kSecAttrAccess as String] = access
        }

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unwritable
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case empty
    case unwritable

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Paste your Hugging Face token first."
        case .unwritable:
            return "Could not save the token to the Keychain."
        }
    }
}
