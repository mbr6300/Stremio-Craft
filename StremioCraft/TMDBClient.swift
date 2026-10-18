import Foundation

/// Kataloge wie `src-tauri/src/services/discovery.rs` in Stremio-VMB:
/// TMDB `movie/top_rated` (dort `list_type: imdb_top`) und
/// `discover/movie|tv` mit `with_watch_providers`.
enum TMDBClient {
    static let base = "https://api.themoviedb.org/3"
    static let imageBase = "https://image.tmdb.org/t/p"

    struct Provider: Identifiable {
        var id: String
        var name: String
        /// VMB-Konstante aus `PROVIDERS`. Prime ist dort 9; in CH liefert 9 keine Titel, 119 schon.
        var tmdbProviderId: Int
        var fallbackProviderId: Int?
        /// Feste Katalog-Region für Anbieter, die es in der eingestellten Region nicht gibt.
        var region: String?

        var allIds: [Int] { [tmdbProviderId] + (fallbackProviderId.map { [$0] } ?? []) }
    }

    static let providers: [Provider] = [
        Provider(id: "netflix", name: "Netflix", tmdbProviderId: 8, fallbackProviderId: nil),
        Provider(id: "disney", name: "Disney+", tmdbProviderId: 337, fallbackProviderId: nil),
        Provider(id: "prime", name: "Prime Video", tmdbProviderId: 9, fallbackProviderId: 119),
        Provider(id: "hbo", name: "HBO / Max", tmdbProviderId: 1899, fallbackProviderId: nil),
        Provider(id: "paramount", name: "Paramount+", tmdbProviderId: 531, fallbackProviderId: nil),
        // Hulu gibt es nur in den USA (in CH/DE/AT laufen die Inhalte über Disney+), daher US-Katalog.
        Provider(id: "hulu", name: "Hulu", tmdbProviderId: 15, fallbackProviderId: nil, region: "US")
    ]

    /// Titel und Beschreibungen bleiben in jeder Region deutsch; die Region bestimmt nur den
    /// Katalog (was wo verfügbar ist). Fehlt eine Übersetzung, liefert TMDB das Original.
    static func language(for country: String) -> String {
        "de-DE"
    }

    /// `type`: "all", "movie" oder "tv". Zwei Seiten, damit reine Film-/Serienreihen voll sind.
    static func fetchTrending(apiKey: String, country: String, type: String = "all") async throws -> [MediaItem] {
        var items: [MediaItem] = []
        for page in 1...2 {
            let url = try makeURL("/trending/\(type)/week", [
                "api_key": apiKey,
                "language": language(for: country),
                "page": String(page)
            ])
            items += try await get(url) { (payload: TMDBPage) in
                payload.results.compactMap { entry in
                    switch type {
                    case "movie": return parseMovie(entry)
                    case "tv": return parseTV(entry)
                    default: return entry.title != nil ? parseMovie(entry) : parseTV(entry)
                    }
                }
            }
        }
        return items
    }

    /// Eine Seite TMDB-Discover für Filme (`type` "movie") oder Serien ("tv"):
    /// optional nach Genre, Streaming-Anbieter und „nur Neues“ gefiltert.
    static func fetchDiscover(
        apiKey: String,
        country: String,
        query discover: DiscoverQuery,
        type: String,
        sort: GenreSort,
        page: Int
    ) async throws -> (items: [MediaItem], totalPages: Int) {
        let isTV = type == "tv"
        var query = [
            "api_key": apiKey,
            "language": language(for: country),
            "page": String(page),
            "include_adult": "false"
        ]
        if let genre = isTV ? discover.tvGenre : discover.movieGenre {
            query["with_genres"] = String(genre)
        }
        if !discover.providers.isEmpty {
            query["watch_region"] = discover.region ?? country
            query["with_watch_providers"] = discover.providers.map(String.init).joined(separator: "|")
            query["with_watch_monetization_types"] = "flatrate"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let day: (Int) -> String = { formatter.string(from: Date().addingTimeInterval(TimeInterval(-$0 * 86_400))) }
        if discover.recent {
            // Filme der letzten Monate, Serien mit neuen Folgen im letzten Monat.
            if isTV {
                query["air_date.gte"] = day(30)
                query["air_date.lte"] = day(0)
            } else {
                query["primary_release_date.gte"] = day(150)
                query["primary_release_date.lte"] = day(0)
            }
        }
        switch sort {
        case .popular:
            query["sort_by"] = "popularity.desc"
            query["vote_count.gte"] = discover.recent ? "5" : "20"
        case .topRated:
            query["sort_by"] = "vote_average.desc"
            query["vote_count.gte"] = discover.recent ? "30" : (isTV ? "200" : "500")
        case .newest:
            query["sort_by"] = isTV ? "first_air_date.desc" : "primary_release_date.desc"
            query[isTV ? "first_air_date.lte" : "primary_release_date.lte"] = day(0)
            query["vote_count.gte"] = "15"
        }
        let url = try makeURL(isTV ? "/discover/tv" : "/discover/movie", query)
        return try await get(url) { (payload: TMDBPage) in
            (payload.results.compactMap { isTV ? parseTV($0) : parseMovie($0) }, payload.totalPages ?? 1)
        }
    }

    /// YouTube-Trailer zu einem Titel: deutsche vor englischen, Trailer vor Teasern, offizielle zuerst.
    static func fetchTrailers(apiKey: String, tmdbId: Int, mediaType: String) async throws -> [Trailer] {
        let type = mediaType == "tv" ? "tv" : "movie"
        let url = try makeURL("/\(type)/\(tmdbId)/videos", [
            "api_key": apiKey,
            "language": "de-DE",
            "include_video_language": "de,en,null"
        ])
        let videos = try await get(url) { (payload: VideosPayload) in payload.results }
        let ranked = videos
            .filter { $0.site == "YouTube" && ["Trailer", "Teaser"].contains($0.type ?? "") && !($0.key ?? "").isEmpty }
            .sorted { lhs, rhs in
                func score(_ v: VideoEntry) -> Int {
                    (v.language == "de" ? 100 : 0) + (v.type == "Trailer" ? 10 : 0) + (v.official == true ? 1 : 0)
                }
                return score(lhs) > score(rhs)
            }
        return ranked.prefix(6).map {
            Trailer(key: $0.key ?? "", name: $0.name ?? "Trailer", language: $0.language ?? "")
        }
    }

    /// TMDB-Empfehlungen zu einem Titel.
    static func fetchRecommendations(apiKey: String, tmdbId: Int, mediaType: String, country: String) async throws -> [MediaItem] {
        let type = mediaType == "tv" ? "tv" : "movie"
        let url = try makeURL("/\(type)/\(tmdbId)/recommendations", [
            "api_key": apiKey,
            "language": language(for: country)
        ])
        return try await get(url) { (payload: TMDBPage) in
            payload.results.compactMap { type == "tv" ? parseTV($0) : parseMovie($0) }
        }
    }

    /// IMDb-ID → TMDB-Titel. Grundlage für alle URL-Listen.
    static func find(apiKey: String, imdbId: String, country: String) async throws -> MediaItem? {
        let url = try makeURL("/find/\(imdbId)", [
            "api_key": apiKey,
            "external_source": "imdb_id",
            "language": language(for: country)
        ])
        return try await get(url) { (payload: FindPayload) in
            payload.movieResults.first.flatMap(parseMovie) ?? payload.tvResults.first.flatMap(parseTV)
        }
    }

    static func fetchList(apiKey: String, listId: String, country: String) async throws -> (name: String?, items: [MediaItem]) {
        let url = try makeURL("/list/\(listId)", [
            "api_key": apiKey,
            "language": language(for: country)
        ])
        return try await get(url) { (payload: ListPayload) in
            (payload.name, payload.items.compactMap(parseAny))
        }
    }

    static func fetchProviderRow(apiKey: String, provider: Provider, country: String) async throws -> [MediaItem] {
        let region = provider.region ?? country
        let primary = try await fetchProvider(apiKey: apiKey, providerId: provider.tmdbProviderId, country: country, region: region)
        if !primary.isEmpty || provider.fallbackProviderId == nil {
            return primary
        }
        return try await fetchProvider(apiKey: apiKey, providerId: provider.fallbackProviderId!, country: country, region: region)
    }

    static func search(apiKey: String, query: String) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let url = try makeURL("/search/multi", [
            "api_key": apiKey,
            "query": trimmed,
            "language": "de-DE",
            "include_adult": "false"
        ])
        return try await get(url) { (payload: MultiSearchPayload) in
            payload.results.compactMap(parseAny)
        }
    }

    private static func parseAny(_ entry: SearchEntry) -> MediaItem? {
        guard let kind = entry.mediaType, kind == "movie" || kind == "tv" else { return nil }
        guard let id = entry.id else { return nil }
        let title = entry.title ?? entry.name ?? ""
        guard !title.isEmpty else { return nil }
        let date = entry.releaseDate ?? entry.firstAirDate
        return MediaItem(
            tmdbId: id,
            mediaType: kind,
            title: title,
            overview: entry.overview ?? "",
            posterURL: image(entry.posterPath, size: "w500"),
            backdropURL: image(entry.backdropPath, size: "w1280"),
            year: year(from: date),
            rating: entry.voteAverage
        )
    }

    static func fetchDetail(apiKey: String, item: MediaItem) async throws -> TitleDetail {
        let endpoint = item.normalizedType == "tv" ? "tv" : "movie"
        let url = try makeURL("/\(endpoint)/\(item.tmdbId)", [
            "api_key": apiKey,
            "language": "de-DE",
            "append_to_response": "external_ids"
        ])
        let data = try await data(from: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let title = (object["title"] as? String) ?? (object["name"] as? String) ?? item.title
        let overview = (object["overview"] as? String) ?? item.overview
        let poster = image(object["poster_path"] as? String, size: "w500") ?? item.posterURL
        let backdrop = image(object["backdrop_path"] as? String, size: "w1280")
        let date = (object["release_date"] as? String) ?? (object["first_air_date"] as? String)
        let rating = object["vote_average"] as? Double
        let runtime = (object["runtime"] as? Int)
            ?? ((object["episode_run_time"] as? [Int])?.first)
        let genres = (object["genres"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let imdb = (object["external_ids"] as? [String: Any])?["imdb_id"] as? String
        let seasons: [SeasonInfo] = (object["seasons"] as? [[String: Any]] ?? []).compactMap { season in
            let number = season["season_number"] as? Int ?? -1
            guard number > 0 else { return nil }
            return SeasonInfo(
                seasonNumber: number,
                name: (season["name"] as? String) ?? "Staffel \(number)",
                episodeCount: season["episode_count"] as? Int ?? 0
            )
        }
        let media = MediaItem(
            tmdbId: item.tmdbId,
            mediaType: item.normalizedType,
            title: title,
            overview: overview,
            posterURL: poster,
            backdropURL: backdrop,
            year: year(from: date) ?? item.year,
            rating: rating ?? item.rating,
            imdbId: imdb ?? item.imdbId
        )
        return TitleDetail(media: media, imdbId: imdb, runtime: runtime, genres: genres, seasons: seasons)
    }

    static func fetchEpisodes(apiKey: String, tmdbId: Int, season: Int) async throws -> [EpisodeInfo] {
        let url = try makeURL("/tv/\(tmdbId)/season/\(season)", [
            "api_key": apiKey,
            "language": "de-DE"
        ])
        return try await get(url) { (payload: SeasonPayload) in
            payload.episodes.map { episode in
                EpisodeInfo(
                    seasonNumber: episode.seasonNumber ?? season,
                    episodeNumber: episode.episodeNumber ?? 0,
                    name: episode.name ?? "Folge \(episode.episodeNumber ?? 0)",
                    overview: episode.overview ?? "",
                    stillURL: image(episode.stillPath, size: "w500"),
                    runtime: episode.runtime,
                    airDate: episode.airDate
                )
            }.filter { $0.episodeNumber > 0 }
        }
    }

    static func imdbId(apiKey: String, tmdbId: Int, mediaType: String) async throws -> String? {
        let endpoint = mediaType == "tv" ? "tv" : "movie"
        let url = try makeURL("/\(endpoint)/\(tmdbId)/external_ids", ["api_key": apiKey])
        return try await get(url) { (payload: ExternalIDs) in payload.imdbId }
    }

    /// `country` bestimmt die Sprache, `region` den Katalog (z. B. Hulu immer US).
    private static func fetchProvider(apiKey: String, providerId: Int, country: String, region: String) async throws -> [MediaItem] {
        let lang = language(for: country)
        async let movies = discover(
            apiKey: apiKey,
            path: "/discover/movie",
            providerId: providerId,
            country: region,
            language: lang,
            movie: true
        )
        async let series = discover(
            apiKey: apiKey,
            path: "/discover/tv",
            providerId: providerId,
            country: region,
            language: lang,
            movie: false
        )
        let (movieItems, seriesItems) = try await (movies, series)
        return interleave(movieItems, seriesItems)
    }

    private static func discover(
        apiKey: String,
        path: String,
        providerId: Int,
        country: String,
        language: String,
        movie: Bool
    ) async throws -> [MediaItem] {
        let url = try makeURL(path, [
            "api_key": apiKey,
            "language": language,
            "watch_region": country,
            "with_watch_providers": String(providerId),
            "sort_by": "popularity.desc",
            "page": "1"
        ])
        return try await get(url) { (page: TMDBPage) in
            page.results.compactMap { movie ? parseMovie($0) : parseTV($0) }
        }
    }

    private static func parseMovie(_ entry: TMDBEntry) -> MediaItem? {
        guard let id = entry.id, let title = entry.title, !title.isEmpty else { return nil }
        return MediaItem(
            tmdbId: id,
            mediaType: "movie",
            title: title,
            overview: entry.overview ?? "",
            posterURL: image(entry.posterPath, size: "w500"),
            backdropURL: image(entry.backdropPath, size: "w1280"),
            year: year(from: entry.releaseDate),
            rating: entry.voteAverage
        )
    }

    private static func parseTV(_ entry: TMDBEntry) -> MediaItem? {
        guard let id = entry.id else { return nil }
        let title = entry.name ?? entry.title ?? ""
        guard !title.isEmpty else { return nil }
        return MediaItem(
            tmdbId: id,
            mediaType: "tv",
            title: title,
            overview: entry.overview ?? "",
            posterURL: image(entry.posterPath, size: "w500"),
            backdropURL: image(entry.backdropPath, size: "w1280"),
            year: year(from: entry.firstAirDate ?? entry.releaseDate),
            rating: entry.voteAverage
        )
    }

    private static func interleave(_ a: [MediaItem], _ b: [MediaItem]) -> [MediaItem] {
        var result: [MediaItem] = []
        let count = max(a.count, b.count)
        for index in 0..<count {
            if index < a.count { result.append(a[index]) }
            if index < b.count { result.append(b[index]) }
        }
        return result
    }

    private static func image(_ path: String?, size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "\(imageBase)/\(size)\(path)")
    }

    private static func year(from date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    private static func makeURL(_ path: String, _ query: [String: String]) throws -> URL {
        guard var components = URLComponents(string: base + path) else {
            throw AppFailure.message("Ungültige TMDB-Adresse.")
        }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            throw AppFailure.message("Ungültige TMDB-Adresse.")
        }
        return url
    }

    private static func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppFailure.message("TMDB hat nicht geantwortet.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw AppFailure.message("TMDB-API-Schlüssel ist ungültig.")
            }
            throw AppFailure.message("TMDB-Fehler \(http.statusCode).")
        }
        return data
    }

    private static func get<T: Decodable, R>(_ url: URL, decode: (T) -> R) async throws -> R {
        let payload = try await data(from: url)
        let decoded = try JSONDecoder().decode(T.self, from: payload)
        return decode(decoded)
    }
}

private struct TMDBPage: Decodable {
    var results: [TMDBEntry]
    var totalPages: Int?

    enum CodingKeys: String, CodingKey {
        case results
        case totalPages = "total_pages"
    }
}

private struct TMDBEntry: Decodable {
    var id: Int?
    var title: String?
    var name: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var voteAverage: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
    }
}

private struct MultiSearchPayload: Decodable {
    var results: [SearchEntry]
}

private struct SearchEntry: Decodable {
    var id: Int?
    var mediaType: String?
    var title: String?
    var name: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var voteAverage: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case mediaType = "media_type"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
    }
}

struct Trailer: Identifiable, Hashable {
    var key: String
    var name: String
    var language: String
    var id: String { key }
    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(key)")! }
}

private struct VideosPayload: Decodable {
    var results: [VideoEntry]
}

private struct VideoEntry: Decodable {
    var key: String?
    var name: String?
    var site: String?
    var type: String?
    var official: Bool?
    var language: String?

    enum CodingKeys: String, CodingKey {
        case key, name, site, type, official
        case language = "iso_639_1"
    }
}

private struct FindPayload: Decodable {
    var movieResults: [TMDBEntry]
    var tvResults: [TMDBEntry]
    enum CodingKeys: String, CodingKey {
        case movieResults = "movie_results"
        case tvResults = "tv_results"
    }
}

private struct ListPayload: Decodable {
    var name: String?
    var items: [SearchEntry]
}

private struct ExternalIDs: Decodable {
    var imdbId: String?
    enum CodingKeys: String, CodingKey { case imdbId = "imdb_id" }
}

private struct SeasonPayload: Decodable {
    var episodes: [SeasonEpisode]
}

private struct SeasonEpisode: Decodable {
    var seasonNumber: Int?
    var episodeNumber: Int?
    var name: String?
    var overview: String?
    var stillPath: String?
    var runtime: Int?
    var airDate: String?

    enum CodingKeys: String, CodingKey {
        case name, overview, runtime
        case airDate = "air_date"
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case stillPath = "still_path"
    }
}
