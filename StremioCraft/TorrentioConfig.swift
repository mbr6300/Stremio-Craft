import Foundation

/// Baut die Torrentio-Addon-URL.
///
/// Stremio-VMB (`src-tauri/src/services/rd_streams.rs`) nutzt ohne Optionen
/// `https://torrentio.strem.fun/stream/{type}/{id}.json` und schaltet Info-Hashes
/// danach lokal über Real-Debrid frei (`info_hash_to_stream`).
/// Sobald Anbieter, Sortierung, Qualitätsfilter, Sprache oder ein Real-Debrid-Token
/// gesetzt sind, hängt derselbe Präfix vor `manifest.json` und `stream/…`,
/// analog zu `extract_debridio_base_url` plus `/stream/{type}/{id}.json`.
enum TorrentioConfig {
    static let host = "https://torrentio.strem.fun"

    static func configSegment(options: TorrentioOptions, realDebridToken: String?) -> String? {
        var parts: [String] = []
        let providers = sanitize(options.providers)
        if !providers.isEmpty { parts.append("providers=\(providers)") }
        let sort = sanitize(options.sort)
        if !sort.isEmpty { parts.append("sort=\(sort)") }
        let quality = sanitize(options.qualityFilter)
        if !quality.isEmpty { parts.append("qualityfilter=\(quality)") }
        let language = sanitize(options.language)
        if !language.isEmpty { parts.append("language=\(language)") }
        if let token = realDebridToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            parts.append("realdebrid=\(token)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "|")
    }

    static func manifestURL(options: TorrentioOptions, realDebridToken: String?) -> URL {
        endpoint(options: options, token: realDebridToken, suffix: "manifest.json")
    }

    static func streamURL(
        options: TorrentioOptions,
        realDebridToken: String?,
        mediaType: String,
        imdbPath: String
    ) -> URL {
        let kind = mediaType == "tv" || mediaType == "series" ? "series" : "movie"
        return endpoint(options: options, token: realDebridToken, suffix: "stream/\(kind)/\(imdbPath).json")
    }

    static func maskedManifest(options: TorrentioOptions, realDebridToken: String?) -> String {
        let url = manifestURL(options: options, realDebridToken: realDebridToken).absoluteString
        guard let token = realDebridToken, !token.isEmpty else { return url }
        return url.replacingOccurrences(of: token, with: "••••")
    }

    private static func endpoint(options: TorrentioOptions, token: String?, suffix: String) -> URL {
        if let segment = configSegment(options: options, realDebridToken: token) {
            // `|` wird als %7C kodiert. Torrentio akzeptiert das in manifest- und stream-Pfaden.
            let encoded = segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
            return URL(string: "\(host)/\(encoded)/\(suffix)")!
        }
        return URL(string: "\(host)/\(suffix)")!
    }

    private static func sanitize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "|", with: "")
    }
}

