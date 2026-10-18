import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var country = "CH"
    @State private var tmdbKey = ""
    @State private var providers = ""
    @State private var sort = ""
    @State private var qualityFilter = ""
    @State private var language = ""
    @State private var tokenDraft = ""
    @State private var status = ""
    @State private var isBusy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Einstellungen")
                    .font(.system(size: 52, weight: .bold))

                section("TMDB") {
                    Text("Gleicher Schlüssel wie tmdb_api_key in Stremio-VMB. Leer lassen, wenn die lokale Übernahme aus LocalSecrets.plist reicht.")
                        .foregroundStyle(.secondary)
                    Text(model.hasTMDBKey ? "Schlüssel ist hinterlegt." : "Kein Schlüssel hinterlegt. Kataloge bleiben leer.")
                    TextField("TMDB-API-Schlüssel", text: $tmdbKey)
                        .frame(maxWidth: 900)
                }

                section("Region") {
                    Text("Entspricht discover_country in Stremio-VMB. Standard ist CH.")
                        .foregroundStyle(.secondary)
                    Picker("Region", selection: $country) {
                        Text("Schweiz").tag("CH")
                        Text("Deutschland").tag("DE")
                        Text("Österreich").tag("AT")
                        Text("USA").tag("US")
                    }
                    .frame(maxWidth: 900)
                }

                section("Real-Debrid") {
                    Text(model.hasRealDebridToken ? "Token liegt im Schlüsselbund." : "Kein Token. Wiedergabe bleibt stehen, bis ein API-Token gespeichert ist.")
                    SecureField("API-Token", text: $tokenDraft)
                        .frame(maxWidth: 900)
                    HStack(spacing: 16) {
                        Button("Token prüfen und sichern") {
                            Task { await saveToken() }
                        }
                        .disabled(isBusy)
                        Button("Token entfernen") {
                            do {
                                try model.setRealDebridToken(nil)
                                tokenDraft = ""
                                status = "Token aus dem Schlüsselbund entfernt."
                            } catch {
                                status = error.localizedDescription
                            }
                        }
                    }
                }

                section("Torrentio") {
                    Text("Ohne Optionen und ohne Token ist die Adresse https://torrentio.strem.fun/stream/… wie in Stremio-VMB. Mit Optionen oder Token wird der Präfix vor manifest.json und stream gesetzt. Der Token steht nur im Schlüsselbund und wird erst in der Anfrage als realdebrid= angehängt.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1100, alignment: .leading)
                    TextField("Anbieter, z. B. yts,eztv,rarbg", text: $providers)
                    Picker("Sortierung", selection: $sort) {
                        Text("Keine, wie VMB").tag("")
                        Text("Qualität und Grösse").tag("qualitysize")
                        Text("Qualität").tag("quality")
                        Text("Grösse").tag("size")
                        Text("Seeder").tag("seeders")
                    }
                    TextField("Qualitätsfilter, z. B. scr,cam", text: $qualityFilter)
                    TextField("Sprache, z. B. german", text: $language)
                    Text(maskedURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1100, alignment: .leading)
                    Button("Manifest prüfen") {
                        Task { await checkManifest() }
                    }
                    .disabled(isBusy)
                }

                Button("Einstellungen sichern") {
                    saveOptions()
                }
                .disabled(isBusy)

                if isBusy {
                    ProgressView()
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.title3)
                        .foregroundStyle(.yellow)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
            }
            .padding(48)
        }
        .background(Color.black)
        .onAppear(perform: load)
    }

    private var maskedURL: String {
        let options = currentOptions
        let token = KeychainStore.loadToken()
        return TorrentioConfig.maskedManifest(options: options, realDebridToken: token)
    }

    private var currentOptions: TorrentioOptions {
        TorrentioOptions(
            providers: providers,
            sort: sort,
            qualityFilter: qualityFilter,
            language: language
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.semibold))
            content()
        }
    }

    private func load() {
        country = model.country
        tmdbKey = model.tmdbKeyOverride
        providers = model.torrentio.providers
        sort = model.torrentio.sort
        qualityFilter = model.torrentio.qualityFilter
        language = model.torrentio.language
    }

    private func saveOptions() {
        model.saveSettings(country: country, tmdbKey: tmdbKey, torrentio: currentOptions)
        status = "Gespeichert. Kataloge werden beim nächsten Öffnen der Startseite neu geladen."
        Task { await model.loadCatalogs() }
    }

    private func saveToken() async {
        let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            status = "Bitte den Real-Debrid API-Token einfügen."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let name = try await RealDebridClient.validate(token: token)
            try model.setRealDebridToken(token)
            tokenDraft = ""
            status = "Token gespeichert. Angemeldet als \(name)."
        } catch {
            status = error.localizedDescription
        }
    }

    private func checkManifest() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let name = try await TorrentioClient.manifestName(
                options: currentOptions,
                token: KeychainStore.loadToken()
            )
            status = "Manifest erreichbar: \(name)."
        } catch {
            status = error.localizedDescription
        }
    }
}

