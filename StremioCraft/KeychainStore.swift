import Foundation
import Security

enum KeychainStore {
    private static let service = "com.stremio.craft"
    private static let account = "realdebrid.apiToken"

    private static let baseQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account
    ]

    static func saveToken(_ token: String) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var insert = baseQuery
        insert[kSecValueData as String] = Data(token.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        #if targetEnvironment(macCatalyst)
        if status == errSecMissingEntitlement {
            try FileTokenStore.save(token)
            return
        }
        #endif
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
        guard status == errSecSuccess, let data = item as? Data else {
            #if targetEnvironment(macCatalyst)
            return FileTokenStore.load()
            #else
            return nil
            #endif
        }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func deleteToken() {
        SecItemDelete(baseQuery as CFDictionary)
        #if targetEnvironment(macCatalyst)
        FileTokenStore.delete()
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// Der lokal signierte Mac-Build hat kein Provisioning-Profil und damit keinen Zugriff auf den
/// Schlüsselbund (-34018). Ersatzweise liegt der Token in einer nur für den Benutzer lesbaren Datei.
// lean-ctx: Datei statt Schlüsselbund, umstellen sobald der Mac-Build mit Provisioning-Profil signiert wird
private enum FileTokenStore {
    private static var url: URL {
        URL.applicationSupportDirectory.appending(path: "StremioCraft/realdebrid.token")
    }

    static func save(_ token: String) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(token.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw AppFailure.message("Token konnte nicht gespeichert werden: \(error.localizedDescription)")
        }
    }

    static func load() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
