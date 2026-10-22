import Foundation

/// Regeln für die Stream-Vorauswahl (Einstellungen → Stream-Auswahl). Leer heisst „egal“.
struct StreamPreferences: Codable, Equatable {
    enum HDR: String, Codable, CaseIterable {
        case any, prefer, avoid
    }

    /// Höchste Auflösung (2160, 1080, 720); höher wird nach hinten sortiert.
    var maxResolution: Int?
    var hdr: HDR = .any
    /// Grössere Dateien nach hinten (z. B. für langsame Leitungen).
    var maxSizeGB: Double?
    /// Bevorzugte Tonsprache im Release-Namen ("de", "en").
    var language: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxResolution = try c.decodeIfPresent(Int.self, forKey: .maxResolution)
        hdr = try c.decodeIfPresent(HDR.self, forKey: .hdr) ?? .any
        maxSizeGB = try c.decodeIfPresent(Double.self, forKey: .maxSizeGB)
        language = try c.decodeIfPresent(String.self, forKey: .language)
    }
}

/// Zuletzt gewählter Stream einer Serie – die nächsten Folgen bevorzugen dieselbe Gruppe und Auflösung.
struct StreamMemory: Codable, Equatable {
    var group: String?
    var rank: Int
}

/// Sortiert Streams nach den Regeln: sofort verfügbar zuerst, dann Punkte für Auflösung, HDR,
/// Grösse, Sprache und die gemerkte Wahl bei Serien.
enum StreamPicker {
    static func sort(_ streams: [StreamCandidate], preferences: StreamPreferences, memory: StreamMemory?) -> [StreamCandidate] {
        let scored = streams.map { ($0, score($0, preferences: preferences, memory: memory)) }
        return scored.sorted { lhs, rhs in
            if lhs.0.isCached != rhs.0.isCached { return lhs.0.isCached }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.rank > rhs.0.rank
        }.map(\.0)
    }

    static func score(_ stream: StreamCandidate, preferences: StreamPreferences, memory: StreamMemory?) -> Double {
        let text = "\(stream.quality) \(stream.title) \(stream.fileName ?? "")".lowercased()
        var score = Double(stream.rank)
        if let max = preferences.maxResolution, resolution(stream) > max { score -= 80 }
        let isHDR = ["hdr", " dv", "dolby vision", "dovi"].contains { text.contains($0) }
        switch preferences.hdr {
        case .prefer: if isHDR { score += 15 }
        case .avoid: if isHDR { score -= 40 }
        case .any: break
        }
        if let limit = preferences.maxSizeGB, let size = sizeGB(stream.size), size > limit { score -= 50 }
        if let language = preferences.language, matches(language: language, text: text) { score += 25 }
        if let memory {
            if let group = memory.group, releaseGroup(stream)?.caseInsensitiveCompare(group) == .orderedSame { score += 30 }
            if memory.rank == stream.rank { score += 10 }
        }
        return score
    }

    static func memory(for stream: StreamCandidate) -> StreamMemory {
        StreamMemory(group: releaseGroup(stream), rank: stream.rank)
    }

    /// 2160, 1080, 720, 480 oder 0 (unbekannt).
    static func resolution(_ stream: StreamCandidate) -> Int {
        switch stream.rank {
        case 100: return 2160
        case 70...99: return 1080
        case 60..<70: return 720
        case 1..<60: return 480
        default: return 0
        }
    }

    /// "12.3 GB" / "800 MB" → Gigabyte.
    static func sizeGB(_ text: String) -> Double? {
        let parts = text.split(separator: " ")
        guard let value = parts.first.flatMap({ Double($0) }) else { return nil }
        return parts.last?.uppercased() == "MB" ? value / 1024 : value
    }

    /// Release-Gruppe am Ende des Namens, z. B. "Show.S01E02.1080p.WEB-DL-NTb.mkv" → "NTb".
    static func releaseGroup(_ stream: StreamCandidate) -> String? {
        let name = stream.fileName ?? stream.title.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let base = (name as NSString).deletingPathExtension
        guard let range = base.range(of: #"-([A-Za-z0-9]{2,15})$"#, options: .regularExpression) else { return nil }
        return String(base[range].dropFirst())
    }

    private static func matches(language: String, text: String) -> Bool {
        switch language {
        case "de": return ["🇩🇪", "german", "deutsch", ".ger.", " ger ", "multi", ".dl."].contains { text.contains($0) }
        case "en": return text.contains("🇬🇧") || !["🇩🇪", "🇫🇷", "🇪🇸", "🇮🇹", "🇷🇺", "german", "french", "ita "].contains { text.contains($0) }
        default: return false
        }
    }
}
