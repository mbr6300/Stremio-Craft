import Foundation

struct IMDbInfo: Codable, Hashable {
    var id: String
    var rating: Double?
    var votes: Int?
    var metascore: Int?
    var certificate: String?
    var runtimeMinutes: Int?
    var directors: [String]
    var cast: [String]

    var votesText: String? {
        guard let votes, votes > 0 else { return nil }
        if votes >= 1_000_000 { return String(format: "%.1f Mio.", Double(votes) / 1_000_000) }
        if votes >= 1_000 { return "\(votes / 1_000) Tsd." }
        return "\(votes)"
    }
}

/// IMDb-Bewertungen und Credits über die öffentliche GraphQL-Schnittstelle (nur private Nutzung).
/// Ergebnisse werden im Speicher und auf Disk gehalten, damit Fokuswechsel keine Anfragen auslösen.
actor IMDbClient {
    static let shared = IMDbClient()

    private var infos: [String: IMDbInfo] = [:]
    /// TMDB-Schlüssel ("movie-123") → IMDb-ID; leerer String = keine IMDb-ID vorhanden.
    private var tmdbToIMDb: [String: String] = [:]
    private var running: [String: Task<IMDbInfo?, Never>] = [:]
    private var loaded = false
    private var saveScheduled = false

    private let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("imdb-info.json")

    private struct Store: Codable {
        var infos: [String: IMDbInfo]
        var ids: [String: String]
    }

    /// IMDb-Infos zu einem TMDB-Titel. Nutzt eine bekannte IMDb-ID oder fragt TMDB danach.
    func info(for item: MediaItem, apiKey: String) async -> IMDbInfo? {
        loadIfNeeded()
        let key = item.id
        if let known = item.imdbId ?? tmdbToIMDb[key] {
            return known.isEmpty ? nil : await info(imdbId: known)
        }
        guard let lookup = try? await TMDBClient.imdbId(apiKey: apiKey, tmdbId: item.tmdbId, mediaType: item.normalizedType) else {
            return nil // Netzfehler: nicht cachen, später erneut versuchen
        }
        let imdb = lookup.hasPrefix("tt") ? lookup : ""
        tmdbToIMDb[key] = imdb
        scheduleSave()
        return imdb.isEmpty ? nil : await info(imdbId: imdb)
    }

    func info(imdbId: String) async -> IMDbInfo? {
        loadIfNeeded()
        if let hit = infos[imdbId] { return hit }
        if let task = running[imdbId] { return await task.value }
        let task = Task<IMDbInfo?, Never> { try? await Self.fetch([imdbId]).first }
        running[imdbId] = task
        let result = await task.value
        running[imdbId] = nil
        if let result {
            infos[imdbId] = result
            scheduleSave()
        }
        return result
    }

    /// Lädt viele Titel in wenigen Anfragen vor (z. B. für IMDb-Listen).
    func prefetch(_ ids: [String]) async {
        loadIfNeeded()
        let missing = Array(Set(ids.filter { infos[$0] == nil && running[$0] == nil }))
        guard !missing.isEmpty else { return }
        for start in stride(from: 0, to: missing.count, by: 50) {
            let chunk = Array(missing[start..<min(start + 50, missing.count)])
            guard let results = try? await Self.fetch(chunk) else { continue }
            for info in results { infos[info.id] = info }
        }
        scheduleSave()
    }

    // MARK: - Netz

    private static func fetch(_ ids: [String]) async throws -> [IMDbInfo] {
        let list = ids.map { "\"\($0)\"" }.joined(separator: ",")
        let query = """
        { titles(ids: [\(list)]) { id ratingsSummary { aggregateRating voteCount } metacritic { metascore { score } } \
        certificate { rating } runtime { seconds } principalCredits { category { id } credits(limit: 5) { name { nameText { text } } } } } }
        """
        var request = URLRequest(url: URL(string: "https://graphql.imdb.com/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("imdb-web-next", forHTTPHeaderField: "x-imdb-client-name")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppFailure.message("IMDb nicht erreichbar.")
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (payload.data?.titles ?? []).compactMap { $0 }.map { title in
            func names(_ categories: Set<String>) -> [String] {
                (title.principalCredits ?? [])
                    .filter { categories.contains($0.category?.id ?? "") }
                    .flatMap { $0.credits ?? [] }
                    .compactMap { $0.name?.nameText?.text }
            }
            return IMDbInfo(
                id: title.id,
                rating: title.ratingsSummary?.aggregateRating,
                votes: title.ratingsSummary?.voteCount,
                metascore: title.metacritic?.metascore?.score,
                certificate: title.certificate?.rating,
                runtimeMinutes: title.runtime?.seconds.map { $0 / 60 },
                directors: names(["director", "creator"]),
                cast: Array(names(["cast"]).prefix(5))
            )
        }
    }

    // MARK: - Cache

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: fileURL), let store = try? JSONDecoder().decode(Store.self, from: data) {
            infos = store.infos
            tmdbToIMDb = store.ids
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.persist()
        }
    }

    private func persist() {
        saveScheduled = false
        if let data = try? JSONEncoder().encode(Store(infos: infos, ids: tmdbToIMDb)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private struct Payload: Decodable {
        var data: DataBlock?
        struct DataBlock: Decodable { var titles: [Title?]? }
        struct Title: Decodable {
            var id: String
            var ratingsSummary: Ratings?
            var metacritic: Metacritic?
            var certificate: Certificate?
            var runtime: Runtime?
            var principalCredits: [CreditGroup]?
        }
        struct Ratings: Decodable { var aggregateRating: Double?; var voteCount: Int? }
        struct Metacritic: Decodable { var metascore: Score? }
        struct Score: Decodable { var score: Int? }
        struct Certificate: Decodable { var rating: String? }
        struct Runtime: Decodable { var seconds: Int? }
        struct CreditGroup: Decodable { var category: Category?; var credits: [Credit]? }
        struct Category: Decodable { var id: String? }
        struct Credit: Decodable { var name: Name? }
        struct Name: Decodable { var nameText: Text? }
        struct Text: Decodable { var text: String? }
    }
}
