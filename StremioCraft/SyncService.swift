import CryptoKit
import Foundation
import Observation
import UIKit

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
    /// Mit dem Konto verbundene Geräte, dieses zuerst.
    private(set) var devices: [SyncDevice] = []
    /// Name, unter dem dieses Gerät bei den anderen erscheint.
    private(set) var deviceName: String
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
    /// Geräte, die beim nächsten Abgleich aus der Liste entfernt werden.
    @ObservationIgnored private var pendingRemovals: Set<String> = []
    /// Eindeutige ID dieser Installation (nicht geheim, nur für die Geräteliste).
    let deviceID: String

    init(model: AppModel) {
        self.model = model
        serverOverride = defaults.string(forKey: serverKey) ?? ""
        lastSync = defaults.object(forKey: lastSyncKey) as? Date
        if let id = defaults.string(forKey: "syncDeviceID") {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "syncDeviceID")
        }
        deviceName = defaults.string(forKey: "syncDeviceName") ?? Self.defaultDeviceName
        if let stored = KeychainStore.load(account: KeychainStore.syncCodeAccount), let code = SyncCode(input: stored) {
            self.code = code
            phase = .idle
            devices = sorted(loadBase()?.devices ?? [])
            startLoop()
        }
    }

    /// Adresse des Workers: Einstellung, sonst `SYNC_URL` aus LocalSecrets.plist.
    var serverURL: URL? { Self.serverURL(override: serverOverride) }

    /// Dieselbe Adresse ohne laufenden Sync – der Worker liefert auch die Empfehlungen.
    nonisolated static var configuredServerURL: URL? {
        serverURL(override: UserDefaults.standard.string(forKey: "syncServerURL") ?? "")
    }

    private nonisolated static func serverURL(override: String) -> URL? {
        let text = override.isEmpty ? bundledServer : override
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

    /// Sync beenden und dieses Gerät vorher aus der Geräteliste des Kontos austragen.
    func leave() async {
        pendingRemovals.insert(deviceID)
        await syncNow()
        disconnect()
    }

    /// Sync auf diesem Gerät beenden; die lokalen Daten bleiben, das Konto auf dem Server auch.
    func disconnect() {
        devices = []
        pendingRemovals = []
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

    /// Lokale Änderungen (z. B. aus „Weiterschauen“ entfernt) sofort weitergeben, sonst alle 45 s
    /// nach Änderungen anderer Geräte schauen. Je schneller eine Änderung oben ist, desto seltener
    /// überschreibt ein anderes Gerät sie mit seinem älteren Stand.
    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            var lastLocal = self?.model.syncSnapshot().sharedData
            var idle: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                idle += 5
                let current = self.model.syncSnapshot().sharedData
                guard current != lastLocal || idle >= 45 else { continue }
                idle = 0
                await self.syncNow()
                lastLocal = self.model.syncSnapshot().sharedData
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
        let base = loadBase()
        var local = model.syncSnapshot()
        local.devices = deviceList(from: base?.devices ?? [])
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
        // Hat sich lokal etwas geändert, während die Anfragen liefen (z. B. Titel entfernt), würde das
        // Übernehmen von `merged` die Änderung überschreiben – dann mit frischem Stand neu beginnen.
        guard model.syncSnapshot().sharedData == local.sharedData else { return false }
        if merged.sharedData != local.sharedData { model.applySyncSnapshot(merged) }

        if merged != remote {
            let blob = try code.seal(JSONEncoder().encode(merged))
            guard let newVersion = try await client.store(space: code.spaceID, expectedVersion: remoteVersion, blob: blob) else {
                return false
            }
            try saveBase(merged, version: newVersion)
        } else {
            try saveBase(merged, version: remoteVersion)
        }
        devices = sorted(merged.devices ?? [])
        pendingRemovals = []
        return true
    }

    // MARK: - Geräteliste

    /// Liste wie zuletzt gemeinsam gesehen, mit aktuellem Eintrag dieses Geräts. „Zuletzt aktiv“
    /// wird nur stündlich erneuert, damit nicht jeder Abgleich einen Schreibvorgang auslöst.
    private func deviceList(from known: [SyncDevice]) -> [SyncDevice] {
        var list = known.filter { !pendingRemovals.contains($0.id) }
        guard !pendingRemovals.contains(deviceID) else { return list }
        let kind: SyncDevice.Kind = Platform.isTV ? .tv : (Platform.isMac ? .mac : .ipad)
        if let index = list.firstIndex(where: { $0.id == deviceID }) {
            let current = list[index]
            if current.name != deviceName || current.kind != kind || current.lastSeen < Date().addingTimeInterval(-3600) {
                list[index] = SyncDevice(id: deviceID, name: deviceName, kind: kind, lastSeen: Date())
            }
        } else {
            list.append(SyncDevice(id: deviceID, name: deviceName, kind: kind, lastSeen: Date()))
        }
        return list
    }

    private func sorted(_ list: [SyncDevice]) -> [SyncDevice] {
        list.sorted { lhs, rhs in
            if lhs.id == deviceID { return true }
            if rhs.id == deviceID { return false }
            return lhs.lastSeen > rhs.lastSeen
        }
    }

    func renameDevice(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != deviceName else { return }
        deviceName = trimmed
        defaults.set(trimmed, forKey: "syncDeviceName")
        await syncNow()
    }

    /// Altes Gerät aus der Liste nehmen. Hat es den Code noch, trägt es sich beim nächsten Start
    /// wieder ein – aussperren lässt es sich nur mit einem neuen Sync-Konto.
    func removeDevice(_ id: String) async {
        guard id != deviceID else { return }
        pendingRemovals.insert(id)
        devices.removeAll { $0.id == id }
        await syncNow()
    }

    private static var defaultDeviceName: String {
        #if targetEnvironment(macCatalyst)
        // UIDevice liefert auf dem Mac keinen sinnvollen Namen; der Rechnername schon.
        let host = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: "-", with: " ")
        return host.isEmpty ? "Mac" : host
        #else
        return UIDevice.current.name
        #endif
    }

    // MARK: - Basis (zuletzt gemeinsamer Stand)

    private static var baseURL: URL {
        #if os(tvOS)
        // Auf dem Apple TV dürfen Apps nur in den Cache-Ordner schreiben; „Application Support“
        // klappt nur im Simulator. Ohne gespeicherte Basis galt jeder Abgleich als erstes
        // Verbinden – entfernte Titel kamen dann vom Server zurück.
        URL.cachesDirectory.appending(path: "StremioCraft/sync-base.json")
        #else
        URL.applicationSupportDirectory.appending(path: "StremioCraft/sync-base.json")
        #endif
    }

    private func loadBase() -> SyncSnapshot? {
        guard let data = try? Data(contentsOf: Self.baseURL) else { return nil }
        return try? JSONDecoder().decode(SyncSnapshot.self, from: data)
    }

    /// Ohne gespeicherte Basis kann kein Entfernen erkannt werden – Fehler deshalb nicht verschlucken.
    private func saveBase(_ snapshot: SyncSnapshot, version: Int) throws {
        let url = Self.baseURL
        let data = try JSONEncoder().encode(snapshot)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Enthält den Real-Debrid-Token – wo möglich mit Dateischutz ablegen.
            if (try? data.write(to: url, options: [.atomic, .completeFileProtection])) == nil {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            throw AppFailure.message("Sync-Stand konnte nicht gespeichert werden: \(error.localizedDescription)")
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

    private nonisolated static let bundledServer: String = {
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
