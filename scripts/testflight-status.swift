// Zeigt die letzten Builds in App Store Connect mit Verarbeitungsstatus.
//   swift scripts/testflight-status.swift
// Nutzt dieselben Zugangsdaten wie testflight.sh (BuildSupport/testflight.env).
import CryptoKit
import Foundation

func env() -> [String: String] {
    let text = (try? String(contentsOfFile: "BuildSupport/testflight.env", encoding: .utf8)) ?? ""
    var values: [String: String] = [:]
    for line in text.split(separator: "\n") where line.contains("=") && !line.hasPrefix("#") {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        values[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
    }
    return values
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

let config = env()
guard let keyID = config["ASC_KEY_ID"], let issuer = config["ASC_ISSUER_ID"], let path = config["ASC_KEY_PATH"],
      let pem = try? String(contentsOfFile: path, encoding: .utf8),
      let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
    print("Zugangsdaten fehlen (BuildSupport/testflight.env).")
    exit(1)
}

let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
let now = Int(Date().timeIntervalSince1970)
let payload = try JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"])
let signingInput = base64URL(header) + "." + base64URL(payload)
let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
let token = signingInput + "." + base64URL(signature)

func get(_ path: String) async throws -> (Data, Int) {
    var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com" + path)!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
}

// Nur Builds von Stremio Craft (das Team kann weitere Apps haben).
let (appData, _) = try await get("/v1/apps?filter[bundleId]=com.stremio.craft&fields[apps]=name")
guard let apps = (try JSONSerialization.jsonObject(with: appData) as? [String: Any])?["data"] as? [[String: Any]],
      let appID = apps.first?["id"] as? String else {
    print("App com.stremio.craft nicht in App Store Connect gefunden.")
    exit(1)
}
let (groupData, _) = try await get("/v1/apps/\(appID)/betaGroups?fields[betaGroups]=name,isInternalGroup,hasAccessToAllBuilds")
let groups = ((try JSONSerialization.jsonObject(with: groupData) as? [String: Any])?["data"] as? [[String: Any]]) ?? []
print("Testgruppen: " + (groups.isEmpty ? "keine" : groups.map { group in
    let a = group["attributes"] as? [String: Any] ?? [:]
    return "\(a["name"] ?? "?") (\((a["isInternalGroup"] as? Bool) == true ? "intern" : "extern"), alle Builds: \((a["hasAccessToAllBuilds"] as? Bool) == true ? "ja" : "nein"))"
}.joined(separator: ", ")))

let (data, status) = try await get("/v1/builds?filter[app]=\(appID)&sort=-uploadedDate&limit=10&include=preReleaseVersion,buildBetaDetail&fields[builds]=version,processingState,uploadedDate,usesNonExemptEncryption,preReleaseVersion,buildBetaDetail&fields[preReleaseVersions]=platform,version&fields[buildBetaDetails]=internalBuildState")
let response = HTTPURLResponse(url: URL(string: "https://api.appstoreconnect.apple.com")!, statusCode: status, httpVersion: nil, headerFields: nil)
guard (response as? HTTPURLResponse)?.statusCode == 200,
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let builds = json["data"] as? [[String: Any]] else {
    print("Fehler:", String(decoding: data, as: UTF8.self))
    exit(1)
}
let included = (json["included"] as? [[String: Any]]) ?? []
var platforms: [String: String] = [:]
var betaStates: [String: String] = [:]
for item in included {
    guard let id = item["id"] as? String, let attributes = item["attributes"] as? [String: Any] else { continue }
    if let platform = attributes["platform"] as? String { platforms[id] = platform }
    if let state = attributes["internalBuildState"] as? String { betaStates[id] = state }
}
func related(_ build: [String: Any], _ name: String) -> String? {
    (((build["relationships"] as? [String: Any])?[name] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String
}
for build in builds {
    let attributes = build["attributes"] as? [String: Any] ?? [:]
    let platform = related(build, "preReleaseVersion").flatMap { platforms[$0] } ?? "?"
    let beta = related(build, "buildBetaDetail").flatMap { betaStates[$0] } ?? "?"
    let encryption = (attributes["usesNonExemptEncryption"] as? Bool).map { $0 ? "ja" : "nein" } ?? "offen"
    print("\(platform.padding(toLength: 8, withPad: " ", startingAt: 0)) Build \(attributes["version"] ?? "?")  \(attributes["processingState"] ?? "?")  intern: \(beta)  Verschlüsselung: \(encryption)")
}
