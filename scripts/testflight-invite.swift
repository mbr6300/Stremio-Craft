// Lädt jemanden als internen TestFlight-Tester für Stremio Craft ein.
//   swift scripts/testflight-invite.swift "Vorname Nachname" email@example.com
//
// Interne Tester müssen zum App-Store-Connect-Team gehören. Die Person bekommt deshalb zuerst eine
// Team-Einladung (Rolle „Marketing“ – die schwächste für TestFlight erlaubte –, nur Zugriff auf
// Stremio Craft). Nach dem Annehmen trägt `testflight-setup.swift` sie in die Gruppe „Familie“ ein
// (läuft auch automatisch am Ende von scripts/testflight.sh); dann folgt die TestFlight-Einladung.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2, let email = arguments.last, email.contains("@") else {
    print("Nutzung: swift scripts/testflight-invite.swift \"Vorname Nachname\" email@example.com")
    exit(1)
}
let nameParts = arguments.first!.split(separator: " ", maxSplits: 1).map(String.init)
let firstName = nameParts.first ?? ""
let lastName = nameParts.count > 1 ? nameParts[1] : "-"

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

func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
    var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com" + path)!)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
}

let (_, appsJSON) = try await call("GET", "/v1/apps?filter[bundleId]=com.stremio.craft")
guard let appID = (appsJSON["data"] as? [[String: Any]])?.first?["id"] as? String else {
    print("App com.stremio.craft nicht gefunden.")
    exit(1)
}

// Schon im Team? Dann reicht der Eintrag in die Gruppe.
let (_, usersJSON) = try await call("GET", "/v1/users?filter[username]=\(email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email)")
if let users = usersJSON["data"] as? [[String: Any]], !users.isEmpty {
    print("\(email) ist bereits im Team – führe jetzt `swift scripts/testflight-setup.swift` aus, um die Person in „Familie“ einzutragen.")
    exit(0)
}

let (status, result) = try await call("POST", "/v1/userInvitations", ["data": [
    "type": "userInvitations",
    "attributes": [
        "email": email,
        "firstName": firstName,
        "lastName": lastName,
        "roles": ["MARKETING"],
        "allAppsVisible": false,
        "provisioningAllowed": false
    ],
    "relationships": ["visibleApps": ["data": [["type": "apps", "id": appID]]]]
]])
guard (200..<300).contains(status) else {
    let detail = ((result["errors"] as? [[String: Any]])?.first?["detail"] as? String) ?? "\(result)"
    print("Einladung fehlgeschlagen (\(status)): \(detail)")
    exit(1)
}
print("✓ Team-Einladung an \(email) verschickt (Rolle Marketing, nur Stremio Craft).")
print("  Nach dem Annehmen: `swift scripts/testflight-setup.swift` (oder beim nächsten Upload automatisch).")
