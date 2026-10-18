import Foundation

struct MediaItem: Identifiable, Hashable, Codable {
    var tmdbId: Int
    var mediaType: String
    var title: String
    var overview: String
    var posterURL: URL?
    var backdropURL: URL?
    var year: Int?
    var rating: Double?

    var id: String { "\(normalizedType)-\(tmdbId)" }

    var normalizedType: String {
        mediaType == "series" || mediaType == "tv" ? "tv" : "movie"
    }

    var yearText: String {
        year.map(String.init) ?? ""
    }
}

struct SeasonInfo: Identifiable, Hashable {
    var seasonNumber: Int
    var name: String
    var episodeCount: Int
    var id: Int { seasonNumber }
}

struct EpisodeInfo: Identifiable, Hashable {
    var seasonNumber: Int
    var episodeNumber: Int
    var name: String
    var overview: String
    var stillURL: URL?
    var id: String { "\(seasonNumber)-\(episodeNumber)" }
    var label: String { String(format: "S%02dE%02d", seasonNumber, episodeNumber) }
}

struct TitleDetail {
    var media: MediaItem
    var imdbId: String?
    var runtime: Int?
    var genres: [String]
    var seasons: [SeasonInfo]
}

struct StreamCandidate: Identifiable, Hashable {
    var id: String
    var title: String
    var quality: String
    var size: String
    var infoHash: String?
    var fileIndex: Int
    var directURL: URL?
    var rank: Int
}

struct WatchProgress: Identifiable, Hashable, Codable {
    var tmdbId: Int
    var mediaType: String
    var title: String
    var overview: String
    var posterURL: URL?
    var year: Int?
    var position: Double
    var duration: Double?
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    var updatedAt: Date

    var id: String { "stream:\(tmdbId):\(mediaType == "tv" ? "tv" : "movie")" }

    var media: MediaItem {
        MediaItem(
            tmdbId: tmdbId,
            mediaType: mediaType,
            title: title,
            overview: overview,
            posterURL: posterURL,
            backdropURL: nil,
            year: year,
            rating: nil
        )
    }

    var isActive: Bool {
        guard position >= 15 else { return false }
        guard let duration, duration > 0 else { return true }
        return position < duration * 0.92
    }

    var subtitle: String {
        var parts: [String] = []
        if let season, let episode {
            parts.append(String(format: "S%02dE%02d", season, episode))
        }
        if let episodeTitle, !episodeTitle.isEmpty {
            parts.append(episodeTitle)
        }
        parts.append(Self.clock(position))
        return parts.joined(separator: " · ")
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

struct FavoriteItem: Identifiable, Hashable, Codable {
    var tmdbId: Int
    var mediaType: String
    var title: String
    var overview: String
    var posterURL: URL?
    var year: Int?
    var id: String { "\(mediaType)-\(tmdbId)" }

    var media: MediaItem {
        MediaItem(
            tmdbId: tmdbId,
            mediaType: mediaType,
            title: title,
            overview: overview,
            posterURL: posterURL,
            backdropURL: nil,
            year: year,
            rating: nil
        )
    }
}

struct PlaybackRequest: Hashable {
    var media: MediaItem
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    var resumeSeconds: Double
    var autoStart: Bool
}

enum AppRoute: Hashable {
    case detail(MediaItem)
    case play(PlaybackRequest)
    case settings
    case search
}

struct CatalogRow: Identifiable {
    var id: String
    var title: String
    var items: [MediaItem]
    var message: String?
}

enum AppFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}

struct TorrentioOptions: Equatable, Codable {
    var providers: String = ""
    var sort: String = ""
    var qualityFilter: String = ""
    var language: String = ""
}
