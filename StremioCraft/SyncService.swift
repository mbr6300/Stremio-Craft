import CryptoKit
import Foundation
import Observation

/// Geräte-Sync über einen eigenen Cloudflare-Worker (siehe `cloudflare/sync-worker`).
/// Kein Login: Alle Geräte mit demselben Sync-Code teilen sich einen verschlüsselten Datenblock.
@MainActor
@Observable
final class SyncService {
    enum Phase: Equatable {
        case off
        case idle
        case syncing
        case failed(String)
    }

    private(set) var code: SyncCode?
    private(set) var phase: Phase = .off
    private(set) var lastSync: Date?
    /// PIN, die dieses Gerät zum Koppeln anzeigt (während es auf den Code wartet).
    private(set) var pairingPIN: String?
    var serverOverride: String {
        didSet { defaults.set(serverOverride.trimmingCharacters(in: .whitespacesAndNewlines), forKey: serverKey) }
    }

    var isEnabled: Bool { code != nil }

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let serverKey = "syncServerURL"
    @ObservationIgnored private let versionKey = "syncVersion"
    @ObservationIgnored private let lastSyncKey = "syncLastDate"
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var pendingRun = false

    init(model: AppModel) {
        self.model = model
        serverOverride = defaults.string(forKey: serverKey) ?? ""
        lastSync = defaults.object(forKey: lastSyncKey) as? Date
        if let stored = KeychainStore.load(account: KeychainStore.syncCodeAccount), let code = SyncCode(input: stored) {
            self.code = code
            phase = .idle
            startLoop()
        }
    }

    /// Adresse des Workers: Einstellung, sonst `SYNC_URL` aus LocalSecrets.plist.
    var serverURL: URL? {
        let text = serverOverride.isEmpty ? Self.bundledServer : serverOverride
        guard !text.isEmpty, let url = URL(string: text), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    // MARK: - Einrichten & Beenden

    /// Neues Konto: zufälliger Code, aktueller Stand dieses Geräts wird hochgeladen.
    func createAccount() async {
        await connect(SyncCode.generate())
    }

    /// Mit vorhandenem Code verbinden; lokale Daten werden mit dem Konto zusammengeführt.
    func join(codeInput: String) async -> Bool {
        guard let code = SyncCode(input: codeInput) else {
            phase = .failed("Der Code hat nicht das richtige Format (20 Zeichen).")
            return false
        }
        await connect(code)
        return phase != .off && !isFailed
    }

    private func connect(_ code: SyncCode) async {
        guard serverURL != nil else {
            phase = .failed(SyncError.noServer.localizedDescription)
            return
        }
        do {
            try KeychainStore.save(code.raw, account: KeychainStore.syncCodeAccount)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        self.code = code
        clearBase()
        await syncNow()
        startLoop()
    }

    /// Sync auf diesem Gerät beenden; die lokalen Daten bleiben, das Konto auf dem Server auch.
    func disconnect() {
        loop?.cancel()
        loop = nil
        cancelPairing()
        KeychainStore.delete(account: KeychainStore.syncCodeAccount)
        clearBase()
        code = nil
        lastSync = nil
        defaults.removeObject(forKey: lastSyncKey)
        phase = .off
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: - Synchronisieren

    /// Regelmässig abgleichen, solange die App läuft (Änderungen lokal oder auf anderen Geräten).
    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self, !Task.isCancelled else { return }
                await self.syncNow()
            }
        }
    }

    /// Beim Start, beim Zurückkehren in die App und auf Knopfdruck.
    func syncNow() async {
        guard code != nil else { return }
        if running {
            pendingRun = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            pendingRun = false
            await runOnce()
        } while pendingRun
    }

    private func runOnce() async {
        guard let code, let server = serverURL else {
            if code != nil { phase = .failed(SyncError.noServer.localizedDescription) }
            return
        }
        phase = .syncing
        do {
            for _ in 0..<3 {
                if try await attempt(code: code, server: server) {
                    lastSync = Date()
                    defaults.set(lastSync, forKey: lastSyncKey)
                    phase = .idle
                    return
                }
            }
            throw SyncError.conflict
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Ein Durchgang; `false` bei Konflikt (ein anderes Gerät war schneller) → erneut versuchen.
    private func attempt(code: SyncCode, server: URL) async throws -> Bool {
        let local = model.syncSnapshot()
        let base = loadBase()
        let baseVersion = base == nil ? 0 : defaults.integer(forKey: versionKey)
        let client = SyncClient(server: server)

        let remote: SyncSnapshot?
        let remoteVersion: Int
        switch try await client.fetch(space: code.spaceID, knownVersion: base == nil ? nil : baseVersion) {
        case .missing:
            remote = nil
            remoteVersion = 0
        case .unchanged:
            remote = base
            remoteVersion = baseVersion
        case .data(let version, let blob):
            remote = try JSONDecoder().decode(SyncSnapshot.self, from: code.open(blob))
            remoteVersion = version
        }

        let merged = remote.map { SyncMerge.merge(base: base, local: local, remote: $0) } ?? local
        if merged != local { model.applySyncSnapshot(merged) }

        guard merged != remote else {
            saveBase(merged, version: remoteVersion)
            return true
        }
        let blob = try code.seal(JSONEncoder().encode(merged))
        guard let newVersion = try await client.store(space: code.spaceID, expectedVersion: remoteVersion, blob: blob) else {
            return false
        }
        saveBase(merged, version: newVersion)
        return true
    }

    // MARK: - Basis (zuletzt gemeinsamer Stand)

    private static var baseURL: URL {
        URL.applicationSupportDirectory.appending(path: "StremioCraft/sync-base.json")
    }

    private func loadBase() -> SyncSnapshot? {
        guard let data = try? Data(contentsOf: Self.baseURL) else { return nil }
        return try? JSONDecoder().decode(SyncSnapshot.self, from: data)
    }

    private func saveBase(_ snapshot: SyncSnapshot, version: Int) {
        let url = Self.baseURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Enthält den Real-Debrid-Token – wo möglich mit Dateischutz ablegen.
        if let data = try? JSONEncoder().encode(snapshot),
           (try? data.write(to: url, options: [.atomic, .completeFileProtection])) == nil {
            try? data.write(to: url, options: .atomic)
        }
        defaults.set(version, forKey: versionKey)
    }

    private func clearBase() {
        try? FileManager.default.removeItem(at: Self.baseURL)
        defaults.removeObject(forKey: versionKey)
    }

    // MARK: - Kopplung per PIN

    /// Neues Gerät: PIN anzeigen und warten, bis ein verbundenes Gerät den Code schickt.
    func startPairing() async {
        guard let server = serverURL else {
            phase = .failed(SyncError.noServer.localizedDescription)
            return
        }
        cancelPairing()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let client = SyncClient(server: server)
        do {
            let pin = try await client.createPairing(publicKey: key.publicKey.rawRepresentation.base64EncodedString())
            pairingPIN = pin
            pairingTask = Task { [weak self] in
                let deadline = Date().addingTimeInterval(10 * 60)
                while !Task.isCancelled, Date() < deadline {
                    // Alle 3 s – bleibt unter der Ratenbegrenzung des Workers (60/min pro IP).
                    try? await Task.sleep(for: .seconds(3))
                    guard let payload = try? await client.pairingPayload(pin: pin) else { continue }
                    guard let self else { return }
                    await client.deletePairing(pin: pin)
                    if let code = try? PairingCrypto.open(payload, with: key, pin: pin) {
                        self.pairingPIN = nil
                        await self.connect(code)
                    } else {
                        self.pairingPIN = nil
                        self.phase = .failed("Die Kopplung ist fehlgeschlagen. Bitte erneut versuchen.")
                    }
                    return
                }
                self?.pairingPIN = nil
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        if let pin = pairingPIN, let server = serverURL {
            Task { await SyncClient(server: server).deletePairing(pin: pin) }
        }
        pairingPIN = nil
    }

    /// Verbundenes Gerät: PIN des neuen Geräts eingeben und den Code verschlüsselt übergeben.
    func sendCode(toPIN input: String) async -> String? {
        let pin = input.filter(\.isNumber)
        guard pin.count == 6 else { return "Die PIN hat 6 Ziffern." }
        guard let code, let server = serverURL else { return SyncError.noServer.localizedDescription }
        let client = SyncClient(server: server)
        do {
            let publicKey = try await client.pairingPublicKey(pin: pin)
            let payload = try PairingCrypto.seal(code, for: publicKey, pin: pin)
            try await client.answerPairing(pin: pin, payload: payload)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static let bundledServer: String = {
        guard let url = Bundle.main.url(forResource: "LocalSecrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = object["SYNC_URL"] as? String else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
}

// MARK: - Kopplung: Code verschlüsselt für den Schlüssel des neuen Geräts

enum PairingCrypto {
    private struct Payload: Codable {
        var ephemeralKey: String
        var sealed: String
    }

    static func seal(_ code: SyncCode, for publicKeyBase64: String, pin: String) throws -> String {
        guard let keyData = Data(base64Encoded: publicKeyBase64) else { throw SyncError.crypto }
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let key = try symmetricKey(ephemeral.sharedSecretFromKeyAgreement(with: recipient), pin: pin)
        guard let sealed = try AES.GCM.seal(Data(code.raw.utf8), using: key).combined else { throw SyncError.crypto }
        let payload = Payload(ephemeralKey: ephemeral.publicKey.rawRepresentation.base64EncodedString(), sealed: sealed.base64EncodedString())
        return String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }

    static func open(_ text: String, with key: Curve25519.KeyAgreement.PrivateKey, pin: String) throws -> SyncCode {
        let payload = try JSONDecoder().decode(Payload.self, from: Data(text.utf8))
        guard let ephemeralData = Data(base64Encoded: payload.ephemeralKey),
              let sealedData = Data(base64Encoded: payload.sealed) else { throw SyncError.crypto }
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralData)
        let symmetric = try symmetricKey(key.sharedSecretFromKeyAgreement(with: ephemeral), pin: pin)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealedData), using: symmetric)
        guard let code = SyncCode(input: String(decoding: plain, as: UTF8.self)) else { throw SyncError.crypto }
        return code
    }

    private static func symmetricKey(_ secret: SharedSecret, pin: String) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("stremiocraft-pair".utf8),
            sharedInfo: Data(pin.utf8),
            outputByteCount: 32
        )
    }
}

// MARK: - HTTP

struct SyncClient {
    enum FetchResult {
        case missing
        case unchanged
        case data(version: Int, blob: String)
    }

    var server: URL

    private func url(_ path: String) -> URL { server.appending(path: path) }

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil, headers: [String: String] = [:]) async throws -> (Data, Int) {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func fetch(space: String, knownVersion: Int?) async throws -> FetchResult {
        let headers = knownVersion.map { ["If-None-Match": "\"\($0)\""] } ?? [:]
        let (data, status) = try await send("GET", "v1/space/\(space)", headers: headers)
        switch status {
        case 404: return .missing
        case 304: return .unchanged
        case 200:
            let json = object(data)
            guard let version = json["version"] as? Int, let blob = json["blob"] as? String else { throw SyncError.server(status) }
            return .data(version: version, blob: blob)
        default: throw SyncError.server(status)
        }
    }

    /// Neue Version oder `nil` bei Konflikt.
    func store(space: String, expectedVersion: Int, blob: String) async throws -> Int? {
        let (data, status) = try await send("PUT", "v1/space/\(space)", body: ["version": expectedVersion, "blob": blob])
        switch status {
        case 200: return object(data)["version"] as? Int
        case 409: return nil
        default: throw SyncError.server(status)
        }
    }

    func createPairing(publicKey: String) async throws -> String {
        let (data, status) = try await send("POST", "v1/pair", body: ["publicKey": publicKey])
        guard status == 201, let pin = object(data)["pin"] as? String else { throw SyncError.server(status) }
        return pin
    }

    func pairingPublicKey(pin: String) async throws -> String {
        let (data, status) = try await send("GET", "v1/pair/\(pin)")
        if status == 404 { throw SyncError.pairingExpired }
        guard status == 200, let key = object(data)["publicKey"] as? String else { throw SyncError.server(status) }
        return key
    }

    func pairingPayload(pin: String) async throws -> String? {
        let (data, status) = try await send("GET", "v1/pair/\(pin)")
        guard status == 200 else { return nil }
        return object(data)["payload"] as? String
    }

    func answerPairing(pin: String, payload: String) async throws {
        let (_, status) = try await send("PUT", "v1/pair/\(pin)", body: ["payload": payload])
        switch status {
        case 204: return
        case 404: throw SyncError.pairingExpired
        case 409: throw AppFailure.message("Diese PIN wurde bereits verwendet.")
        default: throw SyncError.server(status)
        }
    }

    func deletePairing(pin: String) async {
        _ = try? await send("DELETE", "v1/pair/\(pin)")
    }
}
