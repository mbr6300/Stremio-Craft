import Foundation

/// Zugang zur eigenen Mediathek auf dem NAS (Synology: Paketzentrum → WebDAV Server, Port 5006 für
/// HTTPS bzw. 5005 für HTTP). Das Passwort liegt im Schlüsselbund und wird – verschlüsselt wie der
/// Real-Debrid-Token – mit den anderen Geräten geteilt.
struct MediaLibraryConfig: Codable, Equatable, Identifiable, Hashable {
    var id = UUID().uuidString
    /// Anzeigename, z. B. „Synology“ oder „Mac mini“.
    var name = "Meine Mediathek"
    /// z. B. `https://192.168.1.10:5006/video`
    var url: String
    var username: String
    var password: String
    /// Selbstsigniertes Zertifikat des NAS akzeptieren (Heimnetz ohne eigenes Zertifikat).
    var allowSelfSigned = true

    init(id: String = UUID().uuidString, name: String = "Meine Mediathek", url: String, username: String, password: String, allowSelfSigned: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
        self.password = password
        self.allowSelfSigned = allowSelfSigned
    }

    /// Ältere Stände (eine einzige Mediathek) hatten weder ID noch Namen.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "default"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Meine Mediathek"
        url = try c.decode(String.self, forKey: .url)
        username = try c.decode(String.self, forKey: .username)
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        allowSelfSigned = try c.decodeIfPresent(Bool.self, forKey: .allowSelfSigned) ?? true
    }

    var baseURL: URL? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    var isComplete: Bool { baseURL != nil && !username.isEmpty && !password.isEmpty }
}

/// Eintrag eines WebDAV-Ordners.
struct LibraryEntry: Identifiable, Hashable {
    /// Pfad auf dem Server, wie er in `href` steht (prozentkodiert), z. B. `/video/Filme/Alien%20(1979).mkv`.
    var href: String
    var name: String
    var isFolder: Bool
    var size: Int64?
    var modified: Date?

    var id: String { href }

    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "webm", "wmv", "mpg", "mpeg", "iso"]

    var isVideo: Bool {
        !isFolder && Self.videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Lesbarer Titel: „The.Matrix.1999.1080p.BluRay.x264-GRP.mkv“ → „The Matrix 1999“.
    var displayTitle: String {
        guard !isFolder else { return name }
        var base = (name as NSString).deletingPathExtension
        base = base.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
        let noise = #"(?i)\b(2160p|1080p|720p|480p|4k|uhd|hdr10\+?|hdr|dv|dovi|bluray|blu-ray|bdrip|brrip|web-?dl|webrip|web|remux|x26[45]|h ?26[45]|hevc|avc|aac|ac3|dts(-hd)?|truehd|atmos|ddp?5 1|10bit|proper|repack|german|dl|multi)\b.*$"#
        base = base.replacingOccurrences(of: noise, with: "", options: .regularExpression)
        let cleaned = base.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-([")))
        return cleaned.isEmpty ? name : cleaned
    }

    var sizeText: String? {
        guard let size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

enum MediaLibraryError: LocalizedError {
    case notConfigured
    case unauthorized
    case notFound
    case certificate
    case server(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Die Mediathek ist noch nicht eingerichtet (Einstellungen → Meine Mediathek)."
        case .unauthorized: return "Anmeldung am NAS fehlgeschlagen – Benutzername oder Passwort stimmen nicht (401)."
        case .notFound: return "Ordner nicht gefunden (404). Stimmt der Pfad in der Adresse, z. B. /video?"
        case .certificate: return "Das Zertifikat des NAS wird nicht akzeptiert. „Selbstsigniertes Zertifikat erlauben“ einschalten oder ein gültiges Zertifikat verwenden."
        case .server(let code): return "Das NAS antwortet mit Fehler \(code)."
        case .network(let message): return "NAS nicht erreichbar: \(message)"
        }
    }
}

/// Minimaler WebDAV-Client: `PROPFIND` (Tiefe 1) mit Basic-Auth, XML-Antwort per `XMLParser`.
final class WebDAVClient: NSObject, URLSessionDelegate {
    let config: MediaLibraryConfig
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(config: MediaLibraryConfig) {
        self.config = config
    }

    /// Inhalt eines Ordners (`href` relativ zum Server; `nil` = Startordner aus der Adresse).
    /// Ordner zuerst, dann Videos, jeweils alphabetisch; andere Dateien fallen weg.
    func fetchLibraryFiles(href: String? = nil) async throws -> [LibraryEntry] {
        guard config.isComplete, let base = config.baseURL else { throw MediaLibraryError.notConfigured }
        let folder = href.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL } ?? base
        var request = URLRequest(url: folder)
        request.httpMethod = "PROPFIND"
        request.timeoutInterval = 20
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
        """.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.serverCertificateUntrusted, .serverCertificateHasBadDate,
                                              .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                                              .secureConnectionFailed].contains(error.code) {
            #if DEBUG
            print("WebDAV TLS:", error, error.userInfo)
            #endif
            throw MediaLibraryError.certificate
        } catch {
            throw MediaLibraryError.network(error.localizedDescription)
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 207, 200: break
        case 401, 403: throw MediaLibraryError.unauthorized
        case 404: throw MediaLibraryError.notFound
        case let code: throw MediaLibraryError.server(code)
        }

        let ownPath = normalized(folder.path)
        let entries = MultiStatusParser.parse(data).filter { normalized(Self.decodedPath($0.href)) != ownPath }
        return entries
            .filter { $0.isFolder || $0.isVideo }
            .sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Direkte Streaming-Adresse für den Player. Die Zugangsdaten stehen in der Adresse
    /// (`https://user:pass@nas:5006/…`) – FFmpeg, Infuse und VLC melden sich damit selbst an.
    func getMediaUrl(_ entry: LibraryEntry) -> URL? {
        guard let base = config.baseURL, let file = URL(string: entry.href, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: file, resolvingAgainstBaseURL: false) else { return nil }
        components.user = config.username
        components.password = config.password
        return components.url
    }

    private var authorization: String {
        "Basic " + Data("\(config.username):\(config.password)".utf8).base64EncodedString()
    }

    private func normalized(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static func decodedPath(_ href: String) -> String {
        let path = URL(string: href)?.path ?? href
        return path.removingPercentEncoding ?? path
    }

    // MARK: - URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Selbstsigniertes Zertifikat nur für den eingetragenen NAS-Host akzeptieren.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           config.allowSelfSigned, challenge.protectionSpace.host == config.baseURL?.host,
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}

/// Liest eine WebDAV-`multistatus`-Antwort (Namensräume werden aufgelöst, Präfixe wie `D:` egal).
private final class MultiStatusParser: NSObject, XMLParserDelegate {
    private var entries: [LibraryEntry] = []
    private var current: [String: String] = [:]
    private var isCollection = false
    private var text = ""

    static func parse(_ data: Data) -> [LibraryEntry] {
        let delegate = MultiStatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "response":
            current = [:]
            isCollection = false
        case "collection":
            isCollection = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href", "displayname", "getcontentlength", "getlastmodified":
            if !value.isEmpty { current[elementName] = value }
        case "response":
            guard let href = current["href"] else { return }
            let fallback = (WebDAVClient.decodedPath(href) as NSString).lastPathComponent
            let name = current["displayname"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            entries.append(LibraryEntry(
                href: href,
                name: name,
                isFolder: isCollection,
                size: current["getcontentlength"].flatMap { Int64($0) },
                modified: current["getlastmodified"].flatMap(Self.httpDate)
            ))
        default:
            break
        }
        text = ""
    }

    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
