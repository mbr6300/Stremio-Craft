import Foundation
import Security

/// Geheimnisse im Schlüsselbund: Real-Debrid-Token und Sync-Code.
enum KeychainStore {
    private static let service = "com.stremio.craft"
    static let realDebridAccount = "realdebrid.apiToken"
    static let syncCodeAccount = "sync.code"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    // MARK: - Real-Debrid

    static func saveToken(_ token: String) throws { try save(token, account: realDebridAccount) }
    static func loadToken() -> String? { load(account: realDebridAccount) }
    static func deleteToken() { delete(account: realDebridAccount) }

    // MARK: - Allgemein

    static func save(_ value: String, account: String) throws {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var insert = baseQuery(account)
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        #if targetEnvironment(macCatalyst)
        if status == errSecMissingEntitlement {
            try FileSecretStore.save(value, account: account)
            return
        }
        #endif
        guard status == errSecSuccess else {
            throw AppFailure.message("Schlüsselbund: Wert konnte nicht gespeichert werden (\(status)).")
        }
    }

    static func load(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            #if targetEnvironment(macCatalyst)
            // Wert aus der Ersatzdatei in den Schlüsselbund übernehmen, sobald dieser verfügbar ist.
            guard let value = FileSecretStore.load(account: account) else { return nil }
            var insert = baseQuery(account)
            insert[kSecValueData as String] = Data(value.utf8)
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            if SecItemAdd(insert as CFDictionary, nil) == errSecSuccess {
                FileSecretStore.delete(account: account)
            }
            return value
            #else
            return nil
            #endif
        }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        #if targetEnvironment(macCatalyst)
        FileSecretStore.delete(account: account)
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// Ein lokal signierter Mac-Build ohne Provisioning-Profil hat keinen Zugriff auf den
/// Schlüsselbund (-34018). Ersatzweise liegt der Wert in einer nur für den Benutzer lesbaren Datei.
// lean-ctx: Datei statt Schlüsselbund, nur ohne Provisioning-Profil
private enum FileSecretStore {
    private static func url(_ account: String) -> URL {
        // Alter Dateiname des Tokens bleibt gültig.
        let name = account == KeychainStore.realDebridAccount ? "realdebrid.token" : "\(account).secret"
        return URL.applicationSupportDirectory.appending(path: "StremioCraft/\(name)")
    }

    static func save(_ value: String, account: String) throws {
        let url = url(account)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw AppFailure.message("Wert konnte nicht gespeichert werden: \(error.localizedDescription)")
        }
    }

    static func load(account: String) -> String? {
        guard let data = try? Data(contentsOf: url(account)) else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func delete(account: String) {
        try? FileManager.default.removeItem(at: url(account))
    }
}
#endif
