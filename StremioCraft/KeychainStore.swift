import Foundation
import Security

enum KeychainStore {
    private static let service = "com.stremio.craft"
    private static let account = "realdebrid.apiToken"

    private static var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        #if targetEnvironment(macCatalyst)
        // Der lokal (ad hoc) signierte Mac-Build hat keine Keychain-Berechtigung (-34018);
        // der klassische Login-Schlüsselbund braucht keine.
        query[kSecUseDataProtectionKeychain as String] = false
        #endif
        return query
    }

    static func saveToken(_ token: String) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var insert = baseQuery
        insert[kSecValueData as String] = Data(token.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppFailure.message("Schlüsselbund: Token konnte nicht gespeichert werden (\(status)).")
        }
    }

    static func loadToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func deleteToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
