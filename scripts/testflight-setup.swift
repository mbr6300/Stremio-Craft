// Richtet TestFlight für Stremio Craft ein (mehrfach ausführbar):
//  • offene Exportkonformität der Builds: „keine meldepflichtige Verschlüsselung“
//  • interne Testgruppe „Familie“ mit Zugriff auf alle Builds
//  • alle App-Store-Connect-Benutzer des Teams als Tester in dieser Gruppe
//   swift scripts/testflight-setup.swift
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
let claims = try JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"])
let signingInput = base64URL(header) + "." + base64URL(claims)
let token = signingInput + "." + base64URL(try key.signature(for: Data(signingInput.utf8)).rawRepresentation)

@discardableResult
func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com" + path)!)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        throw NSError(domain: "ASC", code: status, userInfo: [NSLocalizedDescriptionKey: "\(method) \(path) → \(status): \(String(decoding: data, as: UTF8.self))"])
    }
    return data.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
}

func items(_ json: [String: Any]) -> [[String: Any]] { json["data"] as? [[String: Any]] ?? [] }
func attr(_ item: [String: Any]) -> [String: Any] { item["attributes"] as? [String: Any] ?? [:] }

// App
guard let app = items(try await call("GET", "/v1/apps?filter[bundleId]=com.stremio.craft")).first,
      let appID = app["id"] as? String else {
    print("App com.stremio.craft nicht gefunden.")
    exit(1)
}

// 1. Exportkonformität
for build in items(try await call("GET", "/v1/builds?filter[app]=\(appID)&limit=50&fields[builds]=version,usesNonExemptEncryption,processingState")) {
    guard attr(build)["usesNonExemptEncryption"] == nil || attr(build)["usesNonExemptEncryption"] is NSNull,
          attr(build)["processingState"] as? String == "VALID", let id = build["id"] as? String else { continue }
    try await call("PATCH", "/v1/builds/\(id)", ["data": ["type": "builds", "id": id, "attributes": ["usesNonExemptEncryption": false]]])
    print("✓ Exportkonformität gesetzt: Build \(attr(build)["version"] ?? id)")
}

// 2. Interne Gruppe „Familie“
let groups = items(try await call("GET", "/v1/apps/\(appID)/betaGroups"))
let groupID: String
if let existing = groups.first(where: { attr($0)["name"] as? String == "Familie" }), let id = existing["id"] as? String {
    groupID = id
    print("• Gruppe „Familie“ existiert bereits")
} else {
    let created = try await call("POST", "/v1/betaGroups", ["data": [
        "type": "betaGroups",
        "attributes": ["name": "Familie", "isInternalGroup": true, "hasAccessToAllBuilds": true],
        "relationships": ["app": ["data": ["type": "apps", "id": appID]]]
    ]])
    groupID = (created["data"] as? [String: Any])?["id"] as? String ?? ""
    print("✓ Interne Gruppe „Familie“ angelegt (Zugriff auf alle Builds)")
}

// 3. Teammitglieder als Tester
let existingTesters = Set(items(try await call("GET", "/v1/betaGroups/\(groupID)/betaTesters?limit=200")).compactMap { attr($0)["email"] as? String }.map { $0.lowercased() })
for user in items(try await call("GET", "/v1/users?limit=200")) {
    let a = attr(user)
    guard let email = a["username"] as? String, !existingTesters.contains(email.lowercased()) else { continue }
    try await call("POST", "/v1/betaTesters", ["data": [
        "type": "betaTesters",
        "attributes": ["email": email, "firstName": a["firstName"] as? String ?? "", "lastName": a["lastName"] as? String ?? ""],
        "relationships": ["betaGroups": ["data": [["type": "betaGroups", "id": groupID]]]]
    ]])
    print("✓ Tester hinzugefügt: \(a["firstName"] ?? "") \(a["lastName"] ?? "")")
}
print("Fertig.")
