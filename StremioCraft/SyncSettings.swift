import SwiftUI

/// Einstellungen → Geräte-Sync: Konto anlegen, per Code oder PIN verbinden, Geräte hinzufügen.
struct SyncSettingsSection: View {
    @Environment(SyncService.self) private var sync
    @State private var codeDraft = ""
    @State private var pinDraft = ""
    @State private var message: String?
    @State private var busy = false
    @State private var showCode = false

    var body: some View {
        Section {
            if sync.isEnabled {
                connected
            } else if let pin = sync.pairingPIN {
                pairing(pin)
            } else {
                disconnected
            }
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Geräte-Sync")
        } footer: {
            Text("Meine Liste, Lieblingstitel, Gesehenes, „Weiterschauen“, Profile, Listen und der Real-Debrid-Token werden über alle Geräte mit demselben Sync-Code geteilt – ohne Login. Die Daten werden auf dem Gerät verschlüsselt; der Server sieht nur unlesbare Daten.")
        }

        Section {
            @Bindable var sync = sync
            TextField("Sync-Server (leer = Standard)", text: $sync.serverOverride)
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if !os(tvOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
        } footer: {
            Text(sync.serverURL.map { "Aktuell: \($0.absoluteString)" } ?? "Kein Server – SYNC_URL in LocalSecrets.plist eintragen oder hier die Worker-Adresse angeben.")
        }
    }

    // MARK: - Zustände

    @ViewBuilder
    private var connected: some View {
        LabeledContent("Status", value: statusText)
        if showCode, let code = sync.code {
            LabeledContent("Sync-Code", value: code.formatted)
                .monospaced()
        } else {
            Button("Sync-Code anzeigen") { showCode = true }
        }
        Button("Jetzt synchronisieren") {
            Task { await sync.syncNow() }
        }
        .disabled(sync.phase == .syncing)

        TextField("PIN des neuen Geräts", text: $pinDraft)
            #if !os(tvOS)
            .keyboardType(.numberPad)
            #endif
        Button("Neues Gerät hinzufügen") {
            run {
                if let error = await sync.sendCode(toPIN: pinDraft) {
                    message = error
                } else {
                    pinDraft = ""
                    message = "Code übermittelt – das neue Gerät verbindet sich jetzt."
                }
            }
        }
        .disabled(busy || pinDraft.filter(\.isNumber).count != 6)

        Button("Sync auf diesem Gerät beenden", role: .destructive) {
            sync.disconnect()
            showCode = false
            message = "Sync beendet. Die Daten auf diesem Gerät bleiben erhalten."
        }
    }

    private func pairing(_ pin: String) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("Auf einem bereits verbundenen Gerät unter Einstellungen → Geräte-Sync diese PIN eingeben:")
                Text(pin.prefix(3) + " " + pin.suffix(3))
                    .font(.system(size: Theme.s(64), weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("Die PIN gilt 10 Minuten.")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            Button("Abbrechen") { sync.cancelPairing() }
        }
    }

    @ViewBuilder
    private var disconnected: some View {
        Button("Mit anderem Gerät koppeln (PIN anzeigen)") {
            run { await sync.startPairing() }
        }
        .disabled(busy)

        TextField("Sync-Code eingeben", text: $codeDraft)
            .autocorrectionDisabled()
            #if !os(tvOS)
            .textInputAutocapitalization(.characters)
            #endif
        Button("Mit Code verbinden") {
            run {
                if await sync.join(codeInput: codeDraft) {
                    codeDraft = ""
                    message = "Verbunden – die Daten wurden zusammengeführt."
                }
            }
        }
        .disabled(busy || codeDraft.isEmpty)

        Button("Neues Sync-Konto einrichten") {
            run {
                await sync.createAccount()
                if sync.isEnabled { message = "Eingerichtet. Weitere Geräte per PIN oder Sync-Code hinzufügen." }
            }
        }
        .disabled(busy)
    }

    private var statusText: String {
        switch sync.phase {
        case .off: return "Aus"
        case .syncing: return "Synchronisiert …"
        case .failed(let text): return text
        case .idle:
            guard let date = sync.lastSync else { return "Bereit" }
            return "Zuletzt " + date.formatted(.relative(presentation: .named))
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        message = nil
        Task {
            await work()
            if case .failed(let text) = sync.phase { message = text }
            busy = false
        }
    }
}
