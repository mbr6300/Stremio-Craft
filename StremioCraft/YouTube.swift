import AVFoundation
import Foundation

// YouTube ohne Werbung und Ablenkung: Suche und Wiedergabe über die inoffizielle InnerTube-Schnittstelle
// (wie die YouTube-Apps selbst), neueste Videos der Abos über die öffentlichen RSS-Feeds der Kanäle.
// Shorts werden überall ausgefiltert. YouTube ändert die Schnittstelle gelegentlich – dann hier anpassen.

struct YouTubeVideo: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var channelID: String
    var channelTitle: String
    var published: Date?
    /// Von YouTube vorformatiert, z. B. „vor 3 Tagen“ (nur bei Suchtreffern).
    var publishedText: String?
    var durationText: String?
    var viewsText: String?

    var thumbnail: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") }
}

struct YouTubeChannel: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var thumbnail: URL? = nil
}

enum YouTubeError: LocalizedError {
    case unplayable(String?)
    case noStreams
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unplayable(let reason): return reason ?? "Dieses Video lässt sich nicht abspielen."
        case .noStreams: return "Für dieses Video gibt es keine abspielbaren Streams."
        case .badResponse: return "YouTube hat unerwartet geantwortet. Bitte später nochmals versuchen."
        }
    }
}

enum YouTubeClient {
    private static let api = "https://www.youtube.com/youtubei/v1"
    /// Die iOS-App von YouTube bekommt direkte Stream-Adressen ohne Signatur-Rätsel.
    private static let iosVersion = "20.10.4"
    private static let iosAgent = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
    private static var region: String { Locale.current.region?.identifier ?? "CH" }

    // MARK: Suche

    static func search(_ query: String) async throws -> (channels: [YouTubeChannel], videos: [YouTubeVideo]) {
        let client: [String: Any] = ["clientName": "WEB", "clientVersion": "2.20250101.00.00", "hl": "de", "gl": region]
        let json = try await post("search", body: ["context": ["client": client], "query": query])
        let channels = collect(json, key: "channelRenderer").compactMap(channel(from:))
        let videos = collect(json, key: "videoRenderer").compactMap(video(from:))
        return (channels, videos)
    }

    private static func channel(from renderer: [String: Any]) -> YouTubeChannel? {
        guard let id = renderer["channelId"] as? String, let title = text(renderer["title"]) else { return nil }
        let thumbs = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumb = (thumbs?.last?["url"] as? String).map { $0.hasPrefix("//") ? "https:" + $0 : $0 }
        return YouTubeChannel(id: id, title: title, thumbnail: thumb.flatMap(URL.init(string:)))
    }

    private static func video(from renderer: [String: Any]) -> YouTubeVideo? {
        guard let id = renderer["videoId"] as? String, let title = text(renderer["title"]) else { return nil }
        // Shorts verlinken auf /shorts/…; die gehören nicht in die App.
        let endpoint = renderer["navigationEndpoint"] as? [String: Any]
        let path = ((endpoint?["commandMetadata"] as? [String: Any])?["webCommandMetadata"] as? [String: Any])?["url"] as? String
        if path?.hasPrefix("/shorts") == true { return nil }
        let owner = (renderer["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]]
        let channelID = ((owner?.first?["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
        return YouTubeVideo(
            id: id,
            title: title,
            channelID: channelID ?? "",
            channelTitle: owner?.first?["text"] as? String ?? "",
            publishedText: text(renderer["publishedTimeText"]),
            durationText: text(renderer["lengthText"]),
            viewsText: text(renderer["shortViewCountText"]) ?? text(renderer["viewCountText"])
        )
    }

    // MARK: Kanäle (RSS)

    /// Die 15 neuesten Videos eines Kanals, ohne Shorts.
    static func channelVideos(_ channelID: String) async throws -> [YouTubeVideo] {
        guard let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)") else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw YouTubeError.badResponse }
        return FeedParser.parse(data)
    }

    /// Neueste Videos aller Abos, gemischt und nach Datum sortiert. Fehlschläge einzelner Kanäle fallen weg.
    static func feed(_ channels: [YouTubeChannel]) async -> [YouTubeVideo] {
        await withTaskGroup(of: [YouTubeVideo].self) { group in
            for channel in channels {
                group.addTask { (try? await channelVideos(channel.id)) ?? [] }
            }
            var all: [YouTubeVideo] = []
            for await videos in group { all += videos }
            return all.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        }
    }

    // MARK: Wiedergabe

    /// Zugänge der offiziellen Apps. Ohne „Prüf-Token“ sperrt YouTube bei manchen Videos die HD-Spuren
    /// nach den ersten MB; darum der Reihe nach probieren und zuletzt auf 360p (Bild + Ton in einer Datei)
    /// ausweichen, die bisher immer ganz ladbar ist.
    private static let playerClients: [(client: [String: Any], agent: String, id: String)] = [
        (["clientName": "IOS", "clientVersion": iosVersion, "deviceMake": "Apple", "deviceModel": "iPhone16,2",
          "osName": "iOS", "osVersion": "18.3.2.22D82"], iosAgent, "5"),
        (["clientName": "ANDROID", "clientVersion": "20.10.38", "androidSdkVersion": 30, "osName": "Android", "osVersion": "11"],
         "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip", "3")
    ]

    static func stream(_ videoID: String) async throws -> YouTubeStream {
        var title = ""
        var fallback: URL?
        var lastError: Error = YouTubeError.noStreams
        for entry in playerClients {
            var client = entry.client
            client["hl"] = "de"
            client["gl"] = region
            let json: [String: Any]
            do {
                json = try await post(
                    "player",
                    body: ["context": ["client": client], "videoId": videoID, "contentCheckOk": true, "racyCheckOk": true],
                    agent: entry.agent,
                    headers: ["X-Youtube-Client-Name": entry.id, "X-Youtube-Client-Version": client["clientVersion"] as? String ?? ""]
                )
            } catch {
                lastError = error
                continue
            }
            let status = json["playabilityStatus"] as? [String: Any]
            guard status?["status"] as? String == "OK", let streaming = json["streamingData"] as? [String: Any] else {
                lastError = YouTubeError.unplayable(status?["reason"] as? String)
                continue
            }
            title = (json["videoDetails"] as? [String: Any])?["title"] as? String ?? title
            // Fertige HLS-Liste (Livestreams, teils auch normale Videos).
            if let hls = (streaming["hlsManifestUrl"] as? String).flatMap(URL.init(string:)) {
                return YouTubeStream(title: title, source: .hls(hls))
            }
            let formats = (streaming["adaptiveFormats"] as? [[String: Any]] ?? []).compactMap(YouTubeFormat.init)
            if let playlists = try? await HLSBuilder.playlists(for: formats) {
                return YouTubeStream(title: title, source: .playlists(playlists))
            }
            let muxed = (streaming["formats"] as? [[String: Any]] ?? []).first { $0["itag"] as? Int == 18 }
            if fallback == nil, let url = (muxed?["url"] as? String).flatMap(URL.init(string:)) { fallback = url }
        }
        if let fallback { return YouTubeStream(title: title, source: .progressive(fallback)) }
        throw lastError
    }

    // MARK: Hilfen

    private static func post(_ endpoint: String, body: [String: Any], agent: String? = nil, headers: [String: String] = [:]) async throws -> [String: Any] {
        guard let url = URL(string: "\(api)/\(endpoint)?prettyPrint=false") else { throw YouTubeError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let agent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw YouTubeError.badResponse }
        return json
    }

    /// Text aus `{"simpleText": …}` oder `{"runs": [{"text": …}]}`.
    private static func text(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        let runs = (dict["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
        return runs.map { $0.joined() }
    }

    /// Alle Objekte unter `key`, egal wie tief verschachtelt (die Antworten ändern ihre Struktur oft).
    private static func collect(_ value: Any, key: String) -> [[String: Any]] {
        var found: [[String: Any]] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                for (k, v) in dict {
                    if k == key, let match = v as? [String: Any] { found.append(match) } else { walk(v) }
                }
            } else if let list = node as? [Any] {
                list.forEach(walk)
            }
        }
        walk(value)
        return found
    }
}

/// Atom-Feed eines Kanals → Videos (ohne Shorts).
private final class FeedParser: NSObject, XMLParserDelegate {
    private var videos: [YouTubeVideo] = []
    private var current: [String: String]?
    private var text = ""
    private var channelTitle = ""
    private var isShort = false
    private static let dates = ISO8601DateFormatter()

    static func parse(_ data: Data) -> [YouTubeVideo] {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.videos
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "entry" { current = [:]; isShort = false }
        if name == "link", current != nil, attributes["href"]?.contains("/shorts/") == true { isShort = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if current == nil {
            if name == "title", channelTitle.isEmpty { channelTitle = value }
            return
        }
        switch name {
        case "yt:videoId", "yt:channelId", "title", "published", "name":
            if current?[name] == nil { current?[name] = value }
        case "entry":
            if let entry = current, !isShort, let id = entry["yt:videoId"] {
                videos.append(YouTubeVideo(
                    id: id,
                    title: entry["title"] ?? "",
                    channelID: entry["yt:channelId"] ?? "",
                    channelTitle: entry["name"] ?? channelTitle,
                    published: entry["published"].flatMap(Self.dates.date(from:))
                ))
            }
            current = nil
        default: break
        }
    }
}

// MARK: - Wiedergabe über HLS

struct YouTubeStream {
    enum Source {
        /// Live-Liste von YouTube.
        case hls(URL)
        /// Selbst gebaute HLS-Listen (Pfad → Inhalt), bis 1080p.
        case playlists([String: String])
        /// Notlösung 360p, wenn YouTube die HD-Spuren sperrt.
        case progressive(URL)
    }

    var title: String
    var source: Source

    var isReducedQuality: Bool {
        if case .progressive = source { return true }
        return false
    }
}

/// Eine Spur aus `adaptiveFormats` (Bild oder Ton, fragmentiertes MP4).
struct YouTubeFormat {
    var itag: Int
    var url: String
    var codecs: String
    var isVideo: Bool
    var height: Int
    var width: Int
    var fps: Int
    var bitrate: Int
    var initRange: ClosedRange<Int>
    var indexRange: ClosedRange<Int>
    var audioName: String?
    var audioLanguage: String?
    var audioIsDefault: Bool
    var contentLength: Int

    init?(_ json: [String: Any]) {
        guard let itag = json["itag"] as? Int, let url = json["url"] as? String,
              let mime = json["mimeType"] as? String, mime.contains("mp4"),
              let initRange = Self.range(json["initRange"]), let indexRange = Self.range(json["indexRange"]) else { return nil }
        self.itag = itag
        self.url = url
        codecs = mime.components(separatedBy: "codecs=\"").last?.replacingOccurrences(of: "\"", with: "") ?? ""
        isVideo = mime.hasPrefix("video")
        height = json["height"] as? Int ?? 0
        width = json["width"] as? Int ?? 0
        fps = json["fps"] as? Int ?? 30
        bitrate = json["bitrate"] as? Int ?? 1_000_000
        self.initRange = initRange
        self.indexRange = indexRange
        let track = json["audioTrack"] as? [String: Any]
        audioName = track?["displayName"] as? String
        audioLanguage = (track?["id"] as? String)?.components(separatedBy: ".").first
        audioIsDefault = track?["audioIsDefault"] as? Bool ?? true
        contentLength = Int(json["contentLength"] as? String ?? "") ?? 0
    }

    private static func range(_ value: Any?) -> ClosedRange<Int>? {
        guard let dict = value as? [String: Any],
              let start = Int(dict["start"] as? String ?? ""), let end = Int(dict["end"] as? String ?? ""), end >= start else { return nil }
        return start...end
    }
}

/// Baut aus den MP4-Spuren HLS-Listen mit Byte-Bereichen. YouTube liefert nur kleine Abschnitte
/// (grosse Bereiche → 403); HLS lädt Segment für Segment und wechselt die Qualität selbst.
enum HLSBuilder {
    static let scheme = "ytcraft"

    static func playlists(for formats: [YouTubeFormat]) async throws -> [String: String] {
        // H.264 bis 1080p (spielt überall, auch auf älteren Apple TV), je Höhe die höchste Bildrate.
        var videoByHeight: [Int: YouTubeFormat] = [:]
        for format in formats where format.isVideo && format.codecs.hasPrefix("avc1") && format.height <= 1080 {
            if let existing = videoByHeight[format.height], existing.fps >= format.fps { continue }
            videoByHeight[format.height] = format
        }
        let videos = videoByHeight.values.sorted { $0.height > $1.height }.prefix(4)
        // AAC-Ton (itag 140) je Sprache; Original zuerst.
        var audioByName: [String: YouTubeFormat] = [:]
        for format in formats where !format.isVideo && format.itag == 140 {
            let name = format.audioName ?? "Ton"
            if audioByName[name] == nil { audioByName[name] = format }
        }
        let audios = audioByName.values.sorted { $0.audioIsDefault && !$1.audioIsDefault }.prefix(6)
        guard !videos.isEmpty, !audios.isEmpty else { throw YouTubeError.noStreams }

        // Gesperrte Spuren liefern nur den Anfang: ein Stück weiter hinten muss ladbar sein.
        async let videoOpen = isFullyAvailable(videos[videos.startIndex])
        async let audioOpen = isFullyAvailable(audios[audios.startIndex])
        guard try await videoOpen, try await audioOpen else { throw YouTubeError.noStreams }

        let tracks = Array(videos) + Array(audios)
        let media = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, track) in tracks.enumerated() {
                group.addTask { (index, try await mediaPlaylist(track)) }
            }
            var result: [Int: String] = [:]
            for try await (index, playlist) in group { result[index] = playlist }
            return result
        }

        var playlists: [String: String] = [:]
        var master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        for (offset, audio) in audios.enumerated() {
            let path = "a\(offset).m3u8"
            playlists[path] = media[videos.count + offset]
            var line = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aac\",NAME=\"\(audio.audioName ?? "Ton")\""
            if let language = audio.audioLanguage { line += ",LANGUAGE=\"\(language)\"" }
            line += ",DEFAULT=\(offset == 0 ? "YES" : "NO"),AUTOSELECT=YES,URI=\"\(path)\"\n"
            master += line
        }
        let audioCodec = audios.first?.codecs ?? "mp4a.40.2"
        let audioBitrate = audios.first?.bitrate ?? 130_000
        for (offset, video) in videos.enumerated() {
            let path = "v\(offset).m3u8"
            playlists[path] = media[offset]
            master += "#EXT-X-STREAM-INF:BANDWIDTH=\(video.bitrate + audioBitrate),CODECS=\"\(video.codecs),\(audioCodec)\","
                + "RESOLUTION=\(video.width)x\(video.height),FRAME-RATE=\(video.fps),AUDIO=\"aac\"\n\(path)\n"
        }
        playlists["master.m3u8"] = master
        return playlists
    }

    private static func isFullyAvailable(_ format: YouTubeFormat) async throws -> Bool {
        guard let url = URL(string: format.url), format.contentLength > 1_000_000 else { return true }
        let start = format.contentLength * 2 / 3
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(start + 1023)", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 206
    }

    /// Liest den `sidx`-Index der Spur und macht daraus eine Liste mit einem Segment pro Eintrag.
    private static func mediaPlaylist(_ format: YouTubeFormat) async throws -> String {
        guard let url = URL(string: format.url) else { throw YouTubeError.noStreams }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(format.indexRange.lowerBound)-\(format.indexRange.upperBound)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 206 else { throw YouTubeError.noStreams }
        guard let index = SegmentIndex(data, anchor: format.indexRange.upperBound + 1), !index.segments.isEmpty else {
            throw YouTubeError.noStreams
        }
        let target = Int((index.segments.map(\.duration).max() ?? 6).rounded(.up))
        let initLength = format.initRange.count
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-MAP:URI=\"\(format.url)\",BYTERANGE=\"\(initLength)@\(format.initRange.lowerBound)\""
        ]
        for segment in index.segments {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("#EXT-X-BYTERANGE:\(segment.length)@\(segment.offset)")
            lines.append(format.url)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Inhalt einer `sidx`-Box (ISO/IEC 14496-12): Byte-Bereich und Dauer jedes Abschnitts.
struct SegmentIndex {
    struct Segment { var offset: Int; var length: Int; var duration: Double }
    var segments: [Segment] = []

    /// - Parameter anchor: Dateiposition direkt nach der `sidx`-Box; dort beginnt der erste Abschnitt.
    init?(_ data: Data, anchor: Int) {
        let bytes = [UInt8](data)
        var position = 0
        func read(_ count: Int) -> UInt64? {
            guard position + count <= bytes.count else { return nil }
            defer { position += count }
            return bytes[position..<position + count].reduce(0) { $0 << 8 | UInt64($1) }
        }
        guard let _ = read(4), let type = read(4), type == 0x7369_6478 /* sidx */,
              let version = read(1), read(3) != nil, read(4) != nil,
              let timescale = read(4), timescale > 0 else { return nil }
        let wide = version == 0 ? 4 : 8
        guard read(wide) != nil, let firstOffset = read(wide), read(2) != nil, let count = read(2) else { return nil }
        var offset = anchor + Int(firstOffset)
        for _ in 0..<count {
            guard let reference = read(4), let duration = read(4), read(4) != nil else { return nil }
            let length = Int(reference & 0x7FFF_FFFF)
            segments.append(Segment(offset: offset, length: length, duration: Double(duration) / Double(timescale)))
            offset += length
        }
    }
}

/// Liefert die selbst gebauten Listen an AVPlayer (`ytcraft://video/master.m3u8`); die Segmente selbst
/// lädt AVPlayer direkt bei YouTube.
final class HLSPlaylistLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let playlists: [String: String]
    let queue = DispatchQueue(label: "ytcraft.playlists")

    init(playlists: [String: String]) {
        self.playlists = playlists
    }

    var masterURL: URL { URL(string: "\(HLSBuilder.scheme)://video/master.m3u8")! }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = request.request.url, url.scheme == HLSBuilder.scheme,
              let playlist = playlists[url.lastPathComponent], let data = playlist.data(using: .utf8) else { return false }
        request.contentInformationRequest?.contentType = "public.m3u-playlist"
        request.contentInformationRequest?.contentLength = Int64(data.count)
        request.contentInformationRequest?.isByteRangeAccessSupported = false
        request.dataRequest?.respond(with: data)
        request.finishLoading()
        return true
    }
}
