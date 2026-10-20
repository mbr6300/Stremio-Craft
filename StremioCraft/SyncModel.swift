import CryptoKit
import Foundation
import Security

// MARK: - Sync-Code

/// Gemeinsamer Geheimcode aller Geräte eines „Kontos“ – ohne Login.
/// 20 Zeichen aus einem Alphabet ohne verwechselbare Zeichen (≈ 100 Bit).
struct SyncCode: Equatable {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ") // Crockford Base32
    let raw: String

    static func generate() -> SyncCode {
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return SyncCode(raw: String(bytes.map { alphabet[Int($0) % alphabet.count] }))
    }

    /// Akzeptiert Eingaben mit Leerzeichen, Bindestrichen, Kleinbuchstaben und O/I/L statt 0/1.
    init?(input: String) {
        let mapped = input.uppercased().compactMap { char -> Character? in
            switch char {
            case "O": return "0"
            case "I", "L": return "1"
            case _ where Self.alphabet.contains(char): return char
            default: return nil
            }
        }
        guard mapped.count == 20 else { return nil }
        raw = String(mapped)
    }

    private init(raw: String) { self.raw = raw }

    /// Zur Anzeige: `K7QF-M2XD-9RHT-WP4N-…`
    var formatted: String {
        stride(from: 0, to: raw.count, by: 4).map { start in
            let begin = raw.index(raw.startIndex, offsetBy: start)
            return String(raw[begin..<raw.index(begin, offsetBy: 4)])
        }.joined(separator: "-")
    }

    /// Speicher-ID beim Server: Hash, der den Code nicht verrät.
    var spaceID: String {
        SHA256.hash(data: Data("stremiocraft-space:\(raw)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Schlüssel für die Verschlüsselung auf dem Gerät.
    var key: SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(raw.utf8)),
            salt: Data("stremiocraft-sync".utf8),
            info: Data("snapshot-v1".utf8),
            outputByteCount: 32
        )
    }

    func seal(_ data: Data) throws -> String {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw SyncError.crypto }
        return combined.base64EncodedString()
    }

    func open(_ blob: String) throws -> Data {
        guard let data = Data(base64Encoded: blob) else { throw SyncError.crypto }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }
}

enum SyncError: LocalizedError {
    case crypto
    case server(Int)
    case noServer
    case pairingExpired
    case conflict

    var errorDescription: String? {
        switch self {
        case .crypto: return "Die Sync-Daten liessen sich nicht entschlüsseln – stimmt der Code?"
        case .server(429): return "Zu viele Anfragen – der Sync-Server bremst kurz. Bitte eine Minute warten."
        case .server(let status): return "Sync-Server antwortet mit Fehler \(status)."
        case .noServer: return "Kein Sync-Server eingetragen."
        case .pairingExpired: return "Die PIN ist abgelaufen oder unbekannt."
        case .conflict: return "Die Daten haben sich gleichzeitig geändert – bitte erneut versuchen."
        }
    }
}

// MARK: - Datenstand

/// Alles, was zwischen den Geräten geteilt wird. Gerätespezifisches (Player, Grösse,
/// aktives Profil) gehört nicht dazu.
struct SyncSnapshot: Codable, Equatable {
    var profiles: [Profile] = []
    /// Schlüssel "" = „Alle“, sonst Profil-ID.
    var buckets: [String: SyncBucket] = [:]
    var catalogs: [CatalogEntry]?
    var country: String?
    var torrentio: TorrentioOptions?
    var realDebridToken: String?
}

struct SyncBucket: Codable, Equatable {
    var favorites: [FavoriteItem] = []
    var loved: [FavoriteItem] = []
    var progress: [WatchProgress] = []
    var watched: [String] = []
    var searches: [String] = []
}

// MARK: - Zusammenführen

/// Dreiwege-Zusammenführung: Basis ist der zuletzt gemeinsam gesehene Stand. Was nur auf
/// einer Seite geändert wurde, gewinnt; bei echten Konflikten entscheidet der jüngere Fortschritt
/// bzw. das eigene Gerät. Gelöschtes bleibt gelöscht, weil es in der Basis noch vorkam.
enum SyncMerge {
    /// - Parameter joining: erstes Verbinden ohne Basis – dann gelten Einstellungen des Kontos.
    static func merge(base: SyncSnapshot?, local: SyncSnapshot, remote: SyncSnapshot) -> SyncSnapshot {
        let joining = base == nil
        let base = base ?? SyncSnapshot()
        // Beim ersten Verbinden gleichnamige Profile zusammenlegen (sonst gäbe es „Mama“ doppelt).
        let local = joining ? unifyProfiles(local, with: remote) : local
        var result = SyncSnapshot()
        result.profiles = keyed(base.profiles, local.profiles, remote.profiles, id: \.id) { mine, _ in mine }
        let profileIDs = Set(result.profiles.map(\.id))
        let bucketKeys = Set(local.buckets.keys).union(remote.buckets.keys).filter { $0.isEmpty || profileIDs.contains($0) }
        for key in bucketKeys {
            result.buckets[key] = bucket(base.buckets[key] ?? SyncBucket(), local.buckets[key] ?? SyncBucket(), remote.buckets[key] ?? SyncBucket())
        }
        result.catalogs = value(base.catalogs, local.catalogs, remote.catalogs, preferRemote: joining)
        result.country = value(base.country, local.country, remote.country, preferRemote: joining)
        result.torrentio = value(base.torrentio, local.torrentio, remote.torrentio, preferRemote: joining)
        result.realDebridToken = value(base.realDebridToken, local.realDebridToken, remote.realDebridToken, preferRemote: joining && remote.realDebridToken != nil)
        return result
    }

    /// Lokale Profile, die im Konto schon unter gleichem Namen existieren, übernehmen dessen ID;
    /// ihre Listen werden mit denen des Kontoprofils vereinigt.
    static func unifyProfiles(_ local: SyncSnapshot, with remote: SyncSnapshot) -> SyncSnapshot {
        let remoteIDs = Set(remote.profiles.map(\.id))
        var renames: [String: String] = [:]
        for profile in local.profiles where !remoteIDs.contains(profile.id) {
            if let match = remote.profiles.first(where: {
                $0.name.compare(profile.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                renames[profile.id] = match.id
            }
        }
        guard !renames.isEmpty else { return local }
        var result = local
        result.profiles = local.profiles.filter { renames[$0.id] == nil }
        for (old, new) in renames {
            let moved = result.buckets.removeValue(forKey: old) ?? SyncBucket()
            result.buckets[new] = bucket(SyncBucket(), result.buckets[new] ?? SyncBucket(), moved)
        }
        return result
    }

    private static func bucket(_ base: SyncBucket, _ local: SyncBucket, _ remote: SyncBucket) -> SyncBucket {
        SyncBucket(
            favorites: keyed(base.favorites, local.favorites, remote.favorites, id: \.id) { mine, _ in mine },
            loved: keyed(base.loved, local.loved, remote.loved, id: \.id) { mine, _ in mine },
            progress: keyed(base.progress, local.progress, remote.progress, id: \.id) { mine, theirs in
                mine.updatedAt >= theirs.updatedAt ? mine : theirs
            },
            watched: set(base.watched, local.watched, remote.watched),
            searches: searches(base.searches, local.searches, remote.searches)
        )
    }

    /// Einzelwert: wer ihn geändert hat, gewinnt; bei Änderung auf beiden Seiten das eigene Gerät.
    static func value<T: Equatable>(_ base: T?, _ local: T?, _ remote: T?, preferRemote: Bool = false) -> T? {
        if local == remote { return local }
        if preferRemote { return remote ?? local }
        if local == base { return remote }
        if remote == base { return local }
        return local
    }

    /// Listen mit IDs: Element für Element zusammenführen, Reihenfolge des eigenen Geräts behalten,
    /// neu hinzugekommene fremde Einträge vorne einfügen (sie sind meist die jüngsten).
    static func keyed<T: Equatable>(
        _ base: [T], _ local: [T], _ remote: [T],
        id: (T) -> String,
        resolve: (T, T) -> T
    ) -> [T] {
        func index(_ list: [T]) -> [String: T] {
            var map: [String: T] = [:]
            for item in list where map[id(item)] == nil { map[id(item)] = item }
            return map
        }
        let b = index(base), l = index(local), r = index(remote)
        var merged: [String: T] = [:]
        for key in Set(l.keys).union(r.keys).union(b.keys) {
            let bv = b[key], lv = l[key], rv = r[key]
            if lv == rv { merged[key] = lv }
            else if lv == bv { merged[key] = rv }
            else if rv == bv { merged[key] = lv }
            else if let lv, let rv { merged[key] = resolve(lv, rv) }
            else { merged[key] = lv ?? rv } // geändert vs. gelöscht: Änderung behalten
        }
        var order: [String] = []
        var seen = Set<String>()
        for key in remote.map(id) where l[key] == nil && merged[key] != nil && seen.insert(key).inserted { order.append(key) }
        for key in local.map(id) where merged[key] != nil && seen.insert(key).inserted { order.append(key) }
        for key in remote.map(id) where merged[key] != nil && seen.insert(key).inserted { order.append(key) }
        return order.compactMap { merged[$0] }
    }

    static func set(_ base: [String], _ local: [String], _ remote: [String]) -> [String] {
        let b = Set(base), l = Set(local), r = Set(remote)
        let kept = l.intersection(r).union(l.subtracting(b)).union(r.subtracting(b))
        return kept.sorted()
    }

    private static func searches(_ base: [String], _ local: [String], _ remote: [String]) -> [String] {
        if local == remote || remote == base { return local }
        if local == base { return remote }
        var seen = Set<String>()
        return Array((local + remote).filter { seen.insert($0.lowercased()).inserted }.prefix(10))
    }
}
