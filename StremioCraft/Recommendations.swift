import Foundation

/// Vorlieben eines Profils für „Empfohlen für dich“. Alles ist freiwillig; leer heisst „egal“.
struct TastePreferences: Codable, Hashable {
    /// TMDB-Film-Genre-IDs (gelten auch für Serien).
    var likedGenres: [Int] = []
    var dislikedGenres: [Int] = []
    /// Jahrzehnte, z. B. 1990.
    var decades: [Int] = []
    /// Originalsprachen, die ohne Untertitel gehen (ISO 639-1).
    var languages: [String] = []
    /// Minuten (bei Serien pro Folge).
    var maxRuntime: Int?
    /// IMDb-Bewertung.
    var minRating: Double?
    /// Höchste Altersfreigabe (FSK); Titel darüber erscheinen nie.
    var maxAge: Int?
    /// Lieblingsschauspieler und -regie.
    var people: [String] = []

    init() {}

    /// Fehlende Felder (ältere Stände) bleiben leer statt das Profil unlesbar zu machen.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        likedGenres = try c.decodeIfPresent([Int].self, forKey: .likedGenres) ?? []
        dislikedGenres = try c.decodeIfPresent([Int].self, forKey: .dislikedGenres) ?? []
        decades = try c.decodeIfPresent([Int].self, forKey: .decades) ?? []
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? []
        maxRuntime = try c.decodeIfPresent(Int.self, forKey: .maxRuntime)
        minRating = try c.decodeIfPresent(Double.self, forKey: .minRating)
        maxAge = try c.decodeIfPresent(Int.self, forKey: .maxAge)
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
    }

    static let genres: [(id: Int, name: String)] = [
        (28, "Action"), (12, "Abenteuer"), (16, "Animation"), (35, "Komödie"), (80, "Krimi"),
        (99, "Dokumentarfilm"), (18, "Drama"), (10751, "Familie"), (14, "Fantasy"), (36, "Historie"),
        (27, "Horror"), (10402, "Musik"), (9648, "Mystery"), (10749, "Liebesfilm"), (878, "Science-Fiction"),
        (53, "Thriller"), (10752, "Krieg"), (37, "Western")
    ]
    static let decadeChoices = [1960, 1970, 1980, 1990, 2000, 2010, 2020]
    static let languageChoices: [(code: String, name: String)] = [
        ("de", "Deutsch"), ("en", "Englisch"), ("fr", "Französisch"), ("es", "Spanisch"),
        ("it", "Italienisch"), ("ja", "Japanisch"), ("ko", "Koreanisch")
    ]
    static let runtimeChoices: [Int?] = [nil, 90, 120, 150]
    static let ratingChoices: [Double?] = [nil, 6.5, 7, 7.5, 8]
    static let ageChoices: [Int?] = [nil, 0, 6, 12, 16]
}

/// Empfehlungen aus der eigenen Titeldatenbank (rund 30'000 Filme und Serien) im Cloudflare-Worker.
enum RecommendationClient {
    struct Seed: Encodable {
        var id: String
        var w: Double
    }

    struct Query: Encodable {
        var region: String
        var limit = 60
        var seeds: [Seed]
        var exclude: [String]
        var prefs: TastePreferences
    }

    /// `nil`, wenn kein Server eingerichtet, er nicht erreichbar oder die Datenbank noch leer ist –
    /// dann gelten weiterhin die TMDB-Empfehlungen.
    static func fetch(_ query: Query) async -> [MediaItem]? {
        guard let server = SyncService.configuredServerURL else { return nil }
        var request = URLRequest(url: server.appendingPathComponent("v1/recommend"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(query)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return payload.items.map { item in
            MediaItem(
                tmdbId: item.tmdbId,
                mediaType: item.kind,
                title: item.title,
                overview: item.overview ?? "",
                posterURL: image(item.poster, size: "w500"),
                backdropURL: image(item.backdrop, size: "w1280"),
                year: item.year,
                rating: item.rating,
                imdbId: item.imdbId
            )
        }
    }

    private static func image(_ path: String?, size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "\(TMDBClient.imageBase)/\(size)\(path)")
    }

    private struct Payload: Decodable {
        var items: [Item]
    }

    private struct Item: Decodable {
        var kind: String
        var tmdbId: Int
        var imdbId: String?
        var title: String
        var overview: String?
        var poster: String?
        var backdrop: String?
        var year: Int?
        var rating: Double?
    }
}
