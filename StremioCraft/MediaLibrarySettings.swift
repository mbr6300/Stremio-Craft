import SwiftUI

/// Einstellungen → Meine Mediathek: alle Quellen (NAS, Mac mini …) mit Status, im Heimnetz
/// gefundene WebDAV-Server zum Übernehmen und „Quelle hinzufügen“.
struct MediaLibrarySettingsSection: View {
    /// Prüfergebnis je Quelle (ID → Status), von den Einstellungen geliefert.
    var statuses: [String: ConfigStatus]
    var onChange: () -> Void

    @Environment(AppModel.self) private var model
    @State private var browser = LocalServiceBrowser()

    private var newFinds: [DiscoveredLibrary] {
        let known = Set(model.mediaLibraries.map { $0.url.lowercased() })
        return browser.found.filter { !known.contains($0.url.lowercased()) }
    }

    var body: some View {
        Section {
            ForEach(model.mediaLibraries) { source in
                NavigationLink {
                    MediaSourceEditView(source: source, isNew: false, onSaved: onChange)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .foregroundStyle(Theme.accent)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                            Text(source.url)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let status = statuses[source.id] {
                            Image(systemName: status.symbol)
                                .foregroundStyle(status.color)
                                .accessibilityLabel(status.text)
                        }
                    }
                }
            }
            ForEach(newFinds) { found in
                NavigationLink {
                    MediaSourceEditView(
                        source: MediaLibraryConfig(name: found.name, url: found.url, username: "", password: ""),
                        isNew: true,
                        onSaved: onChange
                    )
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Im Netzwerk gefunden: \(found.name)")
                            Text(found.url)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "wifi")
                    }
                }
            }
            NavigationLink {
                MediaSourceEditView(
                    source: MediaLibraryConfig(name: "", url: "", username: "", password: ""),
                    isNew: true,
                    onSaved: onChange
                )
            } label: {
                Label("Quelle hinzufügen", systemImage: "plus.circle")
            }
        } header: {
            SettingsHeader(title: "Meine Mediathek", status: summary)
        } footer: {
            SettingsFooter("Eigene Filme und Serien per WebDAV, z. B. von einer Synology (Paketzentrum → WebDAV Server; HTTPS-Port 5006, HTTP 5005) oder vom Mac mini (Einrichtung mit scripts/mac-mini-webdav.sh). Server im Heimnetz erscheinen hier von selbst. Die Zugänge werden mit deinen anderen Geräten geteilt.")
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    /// Alle verbunden → ✓; mindestens eine fehlerhaft → ⚠︎; keine eingerichtet → ◌.
    private var summary: ConfigStatus {
        let sources = model.mediaLibraries
        guard !sources.isEmpty else { return .missing("Nicht eingerichtet") }
        let results = sources.map { statuses[$0.id] ?? .checking }
        if results.contains(.checking) { return .checking }
        let failed = results.filter { if case .failed = $0 { return true } else { return false } }.count
        if failed > 0 { return .failed(failed == 1 && sources.count == 1 ? results[0].text : "\(failed) von \(sources.count) nicht erreichbar") }
        return .ok(sources.count == 1 ? "Verbunden" : "\(sources.count) Quellen verbunden")
    }
}

/// Eine Quelle anlegen oder bearbeiten; gespeichert wird erst, wenn der Server antwortet.
struct MediaSourceEditView: View {
    @State var source: MediaLibraryConfig
    var isNew: Bool
    var onSaved: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var passwordDraft = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                TextField("Name, z. B. Mac mini oder Synology", text: $source.name)
                TextField("Adresse, z. B. https://192.168.1.10:5006/video", text: $source.url)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if !os(tvOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                TextField("Benutzer", text: $source.username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if !os(tvOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField(isNew ? "Passwort" : "Passwort (leer lassen = unverändert)", text: $passwordDraft)
                Toggle("Selbstsigniertes Zertifikat erlauben", isOn: $source.allowSelfSigned)
            } header: {
                SettingsHeader(title: isNew ? "Neue Quelle" : source.name)
            } footer: {
                SettingsFooter("Die Adresse enthält den freigegebenen Ordner, z. B. /video. Am besten einen eigenen Benutzer ohne Zwei-Faktor-Anmeldung und nur mit Lesezugriff verwenden.")
            }

            Section {
                Button("Verbindung prüfen und sichern") { Task { await save() } }
                    .disabled(busy)
                if !isNew {
                    Button("Quelle entfernen", role: .destructive) {
                        model.removeMediaLibrary(id: source.id)
                        onSaved()
                        dismiss()
                    }
                }
                if busy || message != nil {
                    HStack(spacing: 12) {
                        if busy { ProgressView() }
                        if let message { Text(message).foregroundStyle(.yellow) }
                    }
                }
            }
        }
        #if !os(tvOS)
        .listSectionSpacing(.custom(28))
        #endif
        .navigationTitle(isNew ? "Quelle hinzufügen" : source.name)
    }

    private func save() async {
        var config = source
        config.name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.name.isEmpty { config.name = config.baseURL?.host ?? "Mediathek" }
        config.url = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        config.username = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !passwordDraft.isEmpty { config.password = passwordDraft }
        guard config.isComplete else {
            message = "Bitte Adresse (mit http:// oder https://), Benutzer und Passwort eintragen."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let entries = try await WebDAVClient(config: config).fetchLibraryFiles()
            model.saveMediaLibrary(config)
            onSaved()
            message = "Verbunden – \(entries.count) Ordner und Videos im Startordner."
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
