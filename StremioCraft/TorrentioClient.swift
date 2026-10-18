import Foundation

/// Stream-Abfrage wie `fetch_torrentio_streams` in
/// `src-tauri/src/services/rd_streams.rs`. Direkte `url`-Felder (Debrid-Option)
/// werden wie in `fetch_debridio_streams` bevorzugt.
enum TorrentioClient {
    static func streams(
        options: TorrentioOptions,
        token: String?,
        imdbId: String,
        mediaType: String,
        season: Int?,
        episode: Int?
    ) async throws -> [StreamCandidate] {
        let path: String
        if mediaType == "tv" || mediaType == "series" {
            path = "\(imdbId):\(season ?? 1):\(episode ?? 1)"
        } else {
            path = imdbId
        }
        let url = TorrentioConfig.streamURL(
            options: options,
            realDebridToken: token,
            mediaType: mediaType,
            imdbPath: path
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AppFailure.message("Torrentio ist nicht erreichbar. \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppFailure.message("Torrentio hat nicht geantwortet.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppFailure.message("Torrentio-Fehler \(http.statusCode). Addon prüfen oder später erneut versuchen.")
        }
        let decoded: TorrentioPayload
        do {
            decoded = try JSONDecoder().decode(TorrentioPayload.self, from: data)
        } catch {
            throw AppFailure.message("Torrentio-Antwort konnte nicht gelesen werden.")
        }
        let streams = decoded.streams ?? []
        let mapped = streams.compactMap(mapStream)
        return sortByResolution(mapped)
    }

    static func manifestName(options: TorrentioOptions, token: String?) async throws -> String {
        let url = TorrentioConfig.manifestURL(options: options, realDebridToken: token)
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppFailure.message("Torrentio-Manifest nicht erreichbar.")
        }
        let manifest = try JSONDecoder().decode(ManifestPayload.self, from: data)
        return manifest.name ?? "Torrentio"
    }

    private static func mapStream(_ stream: TorrentioStream) -> StreamCandidate? {
        let rawName = (stream.name ?? "").replacingOccurrences(of: "Torrentio\n", with: "")
        let rawTitle = stream.title ?? rawName
        let quality = extractQuality(rawName.isEmpty ? rawTitle : rawName)
        let size = extractSize(rawTitle)
        let direct = stream.url.flatMap { URL(string: $0) }.flatMap { url -> URL? in
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return url
        }
        let hash = stream.infoHash?.trimmingCharacters(in: .whitespacesAndNewlines)
        if direct == nil && (hash == nil || hash?.isEmpty == true) { return nil }
        let label = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return StreamCandidate(
            id: "\(hash ?? direct?.absoluteString ?? UUID().uuidString)-\(stream.fileIdx ?? 0)",
            title: label.isEmpty ? quality : label,
            quality: quality,
            size: size,
            infoHash: hash.flatMap { $0.isEmpty ? nil : $0 },
            fileIndex: stream.fileIdx ?? 0,
            directURL: direct,
            rank: resolutionRank(quality)
        )
    }

    static func sortByResolution(_ streams: [StreamCandidate]) -> [StreamCandidate] {
        streams.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
            return lhs.quality < rhs.quality
        }
    }

    static func resolutionRank(_ quality: String) -> Int {
        let q = quality.lowercased()
        if q.contains("2160") || q.contains("4k") || q.contains("uhd") { return 100 }
        if q.contains("1080") || q.contains("full hd") { return 80 }
        if q.contains("bdrip") || q.contains("bluray") { return 75 }
        if q.contains("web-dl") || q.contains("webdl") { return 70 }
        if q.contains("720") || q.contains("hd") { return 60 }
        if q.contains("480") || q.contains("sd") { return 40 }
        if q.contains("dvd") || q.contains("cam") { return 20 }
        return 50
    }

    private static func extractQuality(_ name: String) -> String {
        let lines = name.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let prefixes = ["1080p", "720p", "2160p", "4k", "480p", "cam", "bdrip", "dvdrip", "web-dl"]
        for line in lines {
            let lower = line.lowercased()
            if prefixes.contains(where: { lower.hasPrefix($0) }) {
                return line
            }
        }
        if let match = name.range(of: #"\d{3,4}p"#, options: .regularExpression) {
            return String(name[match])
        }
        return lines.first ?? "?"
    }

    private static func extractSize(_ title: String) -> String {
        if let marker = title.range(of: "💾") {
            let rest = title[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            if let end = rest.firstIndex(of: " ") {
                let value = rest[..<end].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return String(value) }
            }
            return rest.split(separator: " ").first.map(String.init) ?? "?"
        }
        let lower = title.lowercased()
        for (suffix, unit) in [("gb", "GB"), ("mb", "MB")] {
            guard let range = lower.range(of: suffix) else { continue }
            let before = title[..<range.lowerBound]
            let number = before.reversed().prefix { $0.isNumber || $0 == "." }.reversed()
            let text = String(number).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return "\(text) \(unit)" }
        }
        return "?"
    }
}

private struct TorrentioPayload: Decodable {
    var streams: [TorrentioStream]?
}

private struct TorrentioStream: Decodable {
    var name: String?
    var title: String?
    var infoHash: String?
    var fileIdx: Int?
    var url: String?

    enum CodingKeys: String, CodingKey {
        case name, title, url
        case infoHash = "infoHash"
        case fileIdx = "fileIdx"
    }
}

private struct ManifestPayload: Decodable {
    var name: String?
}
