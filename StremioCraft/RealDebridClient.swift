import Foundation

/// Real-Debrid wie `src-tauri/src/services/rd_streams.rs`:
/// `addMagnet` → `torrents/info` → `selectFiles` → `unrestrict/link`.
enum RealDebridClient {
    private static let rest = "https://api.real-debrid.com/rest/1.0"

    static func validate(token: String) async throws -> String {
        let payload: UserPayload = try await send(path: "/user", method: "GET", token: token, form: nil)
        let name = payload.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            throw AppFailure.message("Real-Debrid hat keinen Benutzer zurückgegeben.")
        }
        return name
    }

    static func resolve(token: String, infoHash: String, fileIndex: Int) async throws -> URL {
        let magnet = "magnet:?xt=urn:btih:\(infoHash.lowercased())"
        let added: AddedTorrent = try await send(
            path: "/torrents/addMagnet",
            method: "POST",
            token: token,
            form: ["magnet": magnet]
        )
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try Task.checkCancellation()
            let info: TorrentInfo = try await send(
                path: "/torrents/info/\(added.id)",
                method: "GET",
                token: token,
                form: nil
            )
            switch info.status {
            case "downloaded":
                guard let link = pickLink(info, fileIndex: fileIndex) else {
                    throw AppFailure.message("Real-Debrid hat keine Datei zum Abspielen geliefert.")
                }
                let open: UnrestrictPayload = try await send(
                    path: "/unrestrict/link",
                    method: "POST",
                    token: token,
                    form: ["link": link]
                )
                guard let url = URL(string: open.download) else {
                    throw AppFailure.message("Real-Debrid-Link ist ungültig.")
                }
                return url
            case "waiting_files_selection", "magnet_conversion":
                if let fileId = pickFileID(info.files, fileIndex: fileIndex) {
                    let _: IgnoredPayload = try await send(
                        path: "/torrents/selectFiles/\(added.id)",
                        method: "POST",
                        token: token,
                        form: ["files": fileId]
                    )
                }
            case "error", "dead", "virus", "magnet_error":
                throw AppFailure.message("Real-Debrid: Torrent nicht verfügbar (\(info.status)).")
            default:
                continue
            }
        }
        throw AppFailure.message("Real-Debrid hat den Stream nicht freigeschaltet. Der Titel liegt vermutlich nicht im Cache.")
    }

    private static func pickFileID(_ files: [RDFile]?, fileIndex: Int) -> String? {
        guard let files, !files.isEmpty else { return nil }
        if let video = videoFile(files, preferredIndex: fileIndex) {
            return String(video.id)
        }
        let index = min(max(fileIndex, 0), files.count - 1)
        return String(files[index].id)
    }

    private static func pickLink(_ info: TorrentInfo, fileIndex: Int) -> String? {
        guard let links = info.links, !links.isEmpty else { return nil }
        if let files = info.files, let video = videoFile(files, preferredIndex: fileIndex) {
            if let position = files.firstIndex(where: { $0.id == video.id }), position < links.count {
                return links[position]
            }
        }
        let index = min(max(fileIndex, 0), links.count - 1)
        return links[index]
    }

    private static func videoFile(_ files: [RDFile], preferredIndex: Int) -> RDFile? {
        let videos = files.filter { isVideo($0.path) }
        guard !videos.isEmpty else { return nil }
        let index = min(max(preferredIndex, 0), files.count - 1)
        let preferred = files[index]
        if isVideo(preferred.path) { return preferred }
        return videos.max { $0.bytes < $1.bytes }
    }

    private static func isVideo(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["mkv", "mp4", "avi", "m4v", "mov", "wmv", "ts", "m2ts", "mpg", "mpeg"].contains(ext)
    }

    private static func send<T: Decodable>(
        path: String,
        method: String,
        token: String,
        form: [String: String]?
    ) async throws -> T {
        guard let url = URL(string: rest + path) else {
            throw AppFailure.message("Ungültige Real-Debrid-Adresse.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var components = URLComponents()
            components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppFailure.message("Real-Debrid hat nicht geantwortet.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? JSONDecoder().decode(RDError.self, from: data))?.error
            if http.statusCode == 401 || body == "bad_token" {
                throw AppFailure.message("Real-Debrid-Token ist ungültig. Bitte in den Einstellungen neu eintragen.")
            }
            throw AppFailure.message("Real-Debrid-Fehler \(http.statusCode)\(body.map { ": \($0)" } ?? "").")
        }
        if T.self == IgnoredPayload.self {
            return IgnoredPayload() as! T
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AppFailure.message("Real-Debrid-Antwort konnte nicht gelesen werden.")
        }
    }
}

private struct UserPayload: Decodable {
    var username: String?
}

private struct AddedTorrent: Decodable {
    var id: String
}

private struct TorrentInfo: Decodable {
    var status: String
    var links: [String]?
    var files: [RDFile]?
}

private struct RDFile: Decodable {
    var id: Int
    var path: String
    var bytes: Int
}

private struct UnrestrictPayload: Decodable {
    var download: String
}

private struct RDError: Decodable {
    var error: String?
}

private struct IgnoredPayload: Decodable {}
