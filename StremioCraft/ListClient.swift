import Foundation

/// Lädt eigene Listen über eine URL und gleicht sie mit TMDB ab.
///
/// Unterstützt:
/// - IMDb-Listen (`imdb.com/list/ls…`) und Charts (`/chart/top`, `/chart/toptv`, `/chart/moviemeter`, `/chart/tvmeter`)
/// - MDBList (`mdblist.com/lists/<user>/<liste>`)
/// - TMDB-Listen (`themoviedb.org/list/<id>`)
/// - Stremio-Addon-Kataloge (`…/catalog/<typ>/<id>.json` oder `…/manifest.json`)
/// - jede andere Seite, die IMDb-IDs (`tt…`) enthält
enum ListClient {
    static let maxItems = 100

    struct Resolved {
        var title: String?
        var items: [MediaItem]
    }

    static func load(_ raw: String, apiKey: String, country: String) async throws -> Resolved {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"^ls\d+$"#, options: .regularExpression) != nil {
            return try await imdbList(text, apiKey: apiKey, country: country)
        }
        guard let url = URL(string: text.contains("://") ? text : "https://\(text)"),
              let host = url.host?.lowercased() else {
            throw AppFailure.message("Ungültige Adresse.")
        }
        let path = url.path.lowercased()

        if host.hasSuffix("imdb.com") {
            if let id = firstMatch(#"ls\d+"#, in: url.path) {
                return try await imdbList(id, apiKey: apiKey, country: country)
            }
            let charts: [(String, String, String)] = [
                ("/chart/toptv", "TOP_RATED_TV_SHOWS", "IMDb Top-Serien"),
                ("/chart/top", "TOP_RATED_MOVIES", "IMDb Top 250"),
                ("/chart/moviemeter", "MOST_POPULAR_MOVIES", "IMDb Beliebte Filme"),
                ("/chart/tvmeter", "MOST_POPULAR_TV_SHOWS", "IMDb Beliebte Serien")
            ]
            if let chart = charts.first(where: { path.hasPrefix($0.0) }) {
                let ids = try await imdbChart(chart.1)
                return Resolved(title: chart.2, items: try await resolve(ids, apiKey: apiKey, country: country))
            }
            throw AppFailure.message("Diese IMDb-Adresse wird nicht unterstützt. Möglich sind Listen (imdb.com/list/ls…) und Charts.")
        }

        if host.hasSuffix("mdblist.com"), path.hasPrefix("/lists/") {
            return try await mdbList(url, apiKey: apiKey, country: country)
        }

        if host.hasSuffix("themoviedb.org"), let id = firstMatch(#"(?<=/list/)\d+"#, in: url.path) {
            let list = try await TMDBClient.fetchList(apiKey: apiKey, listId: id, country: country)
            return Resolved(title: list.name, items: Array(list.items.prefix(maxItems)))
        }

        if path.hasSuffix("/manifest.json") || path.contains("/catalog/") {
            return try await stremioCatalog(url, apiKey: apiKey, country: country)
        }

        let (data, _) = try await fetch(url)
        let body = String(decoding: data, as: UTF8.self)
        let ids = unique(matches(#"tt\d{7,9}"#, in: body))
        guard !ids.isEmpty else {
            throw AppFailure.message("Unter dieser Adresse wurden keine IMDb-IDs gefunden.")
        }
        return Resolved(title: nil, items: try await resolve(ids, apiKey: apiKey, country: country))
    }

    // MARK: - Quellen

    private static func imdbList(_ id: String, apiKey: String, country: String) async throws -> Resolved {
        let query = #"{ list(id: "\#(id)") { name { originalText } items(first: 250) { edges { node { listItem { ... on Title { id } } } } } } }"#
        let root = try await imdbGraphQL(query)
        guard let list = root["list"] as? [String: Any] else {
            throw AppFailure.message("IMDb-Liste \(id) nicht gefunden oder privat.")
        }
        let name = (list["name"] as? [String: Any])?["originalText"] as? String
        let edges = ((list["items"] as? [String: Any])?["edges"] as? [[String: Any]]) ?? []
        let ids = edges.compactMap { (($0["node"] as? [String: Any])?["listItem"] as? [String: Any])?["id"] as? String }
        return Resolved(title: name, items: try await resolve(ids, apiKey: apiKey, country: country))
    }

    private static func imdbChart(_ type: String) async throws -> [String] {
        let query = #"{ chartTitles(chart: { chartType: \#(type) }, first: 250) { edges { node { id } } } }"#
        let root = try await imdbGraphQL(query)
        let edges = ((root["chartTitles"] as? [String: Any])?["edges"] as? [[String: Any]]) ?? []
        return edges.compactMap { ($0["node"] as? [String: Any])?["id"] as? String }
    }

    private static func imdbGraphQL(_ query: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://graphql.imdb.com/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("imdb-web-next", forHTTPHeaderField: "x-imdb-client-name")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = object["data"] as? [String: Any] else {
            throw AppFailure.message("IMDb hat die Liste nicht geliefert.")
        }
        return root
    }

    private static func mdbList(_ url: URL, apiKey: String, country: String) async throws -> Resolved {
        var base = url.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/json") { base += "/json" }
        guard let jsonURL = URL(string: base) else { throw AppFailure.message("Ungültige MDBList-Adresse.") }
        let (data, _) = try await fetch(jsonURL)
        let json = try JSONSerialization.jsonObject(with: data)
        var entries: [[String: Any]] = []
        if let array = json as? [[String: Any]] {
            entries = array
        } else if let dict = json as? [String: Any] {
            entries = ((dict["movies"] as? [[String: Any]]) ?? []) + ((dict["shows"] as? [[String: Any]]) ?? [])
        }
        let ids = entries.compactMap { $0["imdb_id"] as? String }.filter { $0.hasPrefix("tt") }
        guard !ids.isEmpty else { throw AppFailure.message("MDBList-Liste ist leer oder privat.") }
        let slug = url.pathComponents.last?.replacingOccurrences(of: "-", with: " ").capitalized
        return Resolved(title: slug, items: try await resolve(ids, apiKey: apiKey, country: country))
    }

    private static func stremioCatalog(_ url: URL, apiKey: String, country: String) async throws -> Resolved {
        var catalogURL = url
        var title: String?
        if url.path.lowercased().hasSuffix("/manifest.json") {
            let (data, _) = try await fetch(url)
            let manifest = try JSONDecoder().decode(StremioManifest.self, from: data)
            guard let catalog = manifest.catalogs?.first(where: { !$0.needsExtra }) else {
                throw AppFailure.message("Das Addon bietet keinen frei abrufbaren Katalog.")
            }
            title = catalog.name ?? manifest.name
            catalogURL = url.deletingLastPathComponent()
                .appendingPathComponent("catalog")
                .appendingPathComponent(catalog.type)
                .appendingPathComponent("\(catalog.id).json")
        }
        let (data, _) = try await fetch(catalogURL)
        let payload = try JSONDecoder().decode(StremioCatalog.self, from: data)
        let ids = payload.metas.compactMap { meta -> String? in
            let id = (meta.imdbId ?? meta.id).split(separator: ":").first.map(String.init) ?? ""
            return id.hasPrefix("tt") ? id : nil
        }
        guard !ids.isEmpty else { throw AppFailure.message("Der Katalog enthält keine IMDb-Titel.") }
        return Resolved(title: title, items: try await resolve(ids, apiKey: apiKey, country: country))
    }

    // MARK: - IMDb → TMDB

    private static func resolve(_ ids: [String], apiKey: String, country: String) async throws -> [MediaItem] {
        let wanted = Array(unique(ids).prefix(maxItems))
        let items = await IMDbMapping.shared.items(for: wanted, apiKey: apiKey, country: country)
        guard !items.isEmpty else { throw AppFailure.message("Keiner der Titel wurde bei TMDB gefunden.") }
        return items
    }

    // MARK: - Hilfen

    private static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Mozilla/5.0 (AppleTV; tvOS) StremioCraft", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AppFailure.message("Liste nicht erreichbar (HTTP \(code)).")
        }
        return (data, response)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Persistenter Cache IMDb-ID → TMDB-Titel, damit Listen nach dem ersten Laden ohne `/find`-Aufrufe auskommen.
actor IMDbMapping {
    static let shared = IMDbMapping()

    private var map: [String: MediaItem] = [:]
    private var misses = Set<String>()
    private var loaded = false
    private var saveScheduled = false

    private let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("imdb-tmdb-map.json")

    func items(for ids: [String], apiKey: String, country: String) async -> [MediaItem] {
        loadIfNeeded()
        let missing = ids.filter { map[$0] == nil && !misses.contains($0) }
        if !missing.isEmpty {
            let found = await withTaskGroup(of: (String, MediaItem?).self) { group in
                var results: [(String, MediaItem?)] = []
                var iterator = missing.makeIterator()
                for _ in 0..<min(8, missing.count) {
                    guard let id = iterator.next() else { break }
                    group.addTask { (id, try? await TMDBClient.find(apiKey: apiKey, imdbId: id, country: country)) }
                }
                while let result = await group.next() {
                    results.append(result)
                    if let id = iterator.next() {
                        group.addTask { (id, try? await TMDBClient.find(apiKey: apiKey, imdbId: id, country: country)) }
                    }
                }
                return results
            }
            for (id, item) in found {
                if let item { map[id] = item } else { misses.insert(id) }
            }
            scheduleSave()
        }
        return ids.compactMap { map[$0] }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: MediaItem].self, from: data) {
            map = stored
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.persist()
        }
    }

    private func persist() {
        saveScheduled = false
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

private struct StremioManifest: Decodable {
    var name: String?
    var catalogs: [Catalog]?

    struct Catalog: Decodable {
        var type: String
        var id: String
        var name: String?
        var extra: [Extra]?
        var extraRequired: [String]?

        var needsExtra: Bool {
            !(extraRequired ?? []).isEmpty || (extra ?? []).contains { $0.isRequired == true }
        }
    }

    struct Extra: Decodable {
        var name: String
        var isRequired: Bool?
    }
}

private struct StremioCatalog: Decodable {
    var metas: [Meta]

    struct Meta: Decodable {
        var id: String
        var imdbId: String?
        enum CodingKeys: String, CodingKey {
            case id
            case imdbId = "imdb_id"
        }
    }
}
