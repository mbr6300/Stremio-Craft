import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var country = "CH"
    @State private var tmdbKey = ""
    @State private var providers = ""
    @State private var sort = ""
    @State private var qualityFilter = ""
    @State private var language = ""
    @State private var player: PlayerChoice = .infuse
    @State private var autoPlay = true
    @State private var tokenDraft = ""
    @State private var status = ""
    @State private var isBusy = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Startseite") {
                NavigationLink(value: AppRoute.lists) {
                    LabeledContent("Listen & Reihen", value: "\(model.catalogs.filter(\.enabled).count) aktiv")
                }
                Picker("Region", selection: $country) {
                    Text("Schweiz").tag("CH")
                    Text("Deutschland").tag("DE")
                    Text("Österreich").tag("AT")
                    Text("USA").tag("US")
                }
            }

            Section {
                Picker("Player", selection: $player) {
                    ForEach(PlayerChoice.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Besten sofort verfügbaren Stream automatisch starten", isOn: $autoPlay)
            } header: {
                Text("Wiedergabe")
            } footer: {
                Text("Infuse spielt MKV, HDR/Dolby Vision und Atmos. Beim Schliessen meldet Infuse die Position zurück, damit „Weiterschauen“ stimmt.")
            }

            Section {
                LabeledContent("Status", value: model.hasRealDebridToken ? "Token im Schlüsselbund" : "Kein Token")
                SecureField("API-Token einfügen", text: $tokenDraft)
                Button("Token prüfen und sichern") { Task { await saveToken() } }
                    .disabled(isBusy)
                if model.hasRealDebridToken {
                    Button("Token entfernen", role: .destructive) {
                        try? model.setRealDebridToken(nil)
                        tokenDraft = ""
                        status = "Token entfernt."
                    }
                }
            } header: {
                Text("Real-Debrid")
            } footer: {
                Text("Token unter real-debrid.com/apitoken. Am einfachsten mit der Tastatur auf dem iPhone einfügen.")
            }

            Section {
                TextField("Anbieter, z. B. yts,eztv", text: $providers)
                Picker("Sortierung", selection: $sort) {
                    Text("Standard").tag("")
                    Text("Qualität und Grösse").tag("qualitysize")
                    Text("Qualität").tag("quality")
                    Text("Grösse").tag("size")
                    Text("Seeder").tag("seeders")
                }
                TextField("Qualitätsfilter, z. B. scr,cam", text: $qualityFilter)
                TextField("Sprache, z. B. german", text: $language)
                Button("Manifest prüfen") { Task { await checkManifest() } }
                    .disabled(isBusy)
            } header: {
                Text("Torrentio")
            } footer: {
                Text(TorrentioConfig.maskedManifest(options: currentOptions, realDebridToken: KeychainStore.loadToken()))
            }

            Section {
                TextField("TMDB-API-Schlüssel (optional)", text: $tmdbKey)
                LabeledContent("Status", value: model.hasTMDBKey ? "Schlüssel vorhanden" : "Fehlt – Kataloge bleiben leer")
            } header: {
                Text("TMDB")
            } footer: {
                Text("Leer lassen, wenn LocalSecrets.plist einen Schlüssel enthält.")
            }

            if isBusy || !status.isEmpty {
                Section {
                    HStack(spacing: 16) {
                        if isBusy { ProgressView() }
                        Text(status).foregroundStyle(.yellow)
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear(perform: saveOptions)
        .onChange(of: country) { saveOptions() }
        .onChange(of: sort) { saveOptions() }
        .onChange(of: player) { model.savePlayer(player, autoPlay: autoPlay) }
        .onChange(of: autoPlay) { model.savePlayer(player, autoPlay: autoPlay) }
        .onSubmit(saveOptions)
    }

    private var currentOptions: TorrentioOptions {
        TorrentioOptions(providers: providers, sort: sort, qualityFilter: qualityFilter, language: language)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        country = model.country
        tmdbKey = model.tmdbKeyOverride
        providers = model.torrentio.providers
        sort = model.torrentio.sort
        qualityFilter = model.torrentio.qualityFilter
        language = model.torrentio.language
        player = model.player
        autoPlay = model.autoPlayBest
    }

    private func saveOptions() {
        guard loaded else { return }
        model.saveSettings(country: country, tmdbKey: tmdbKey, torrentio: currentOptions)
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
            let name = try await TorrentioClient.manifestName(options: currentOptions, token: KeychainStore.loadToken())
            status = "Manifest erreichbar: \(name)."
        } catch {
            status = error.localizedDescription
        }
    }
}

/// Reihen der Startseite verwalten und eigene Listen per URL hinzufügen.
struct ListsView: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var title = ""
    @State private var status = ""
    @State private var isAdding = false

    var body: some View {
        Form {
            Section {
                TextField("Adresse der Liste", text: $url)
                TextField("Name (optional)", text: $title)
                Button {
                    Task { await add() }
                } label: {
                    HStack(spacing: 14) {
                        if isAdding { ProgressView() }
                        Text(isAdding ? "Liste wird geladen…" : "Liste hinzufügen")
                    }
                }
                .disabled(isAdding)
                if !status.isEmpty {
                    Text(status).foregroundStyle(.yellow)
                }
            } header: {
                Text("Eigene Liste hinzufügen")
            } footer: {
                Text("""
                Unterstützt: IMDb-Listen (imdb.com/list/ls…) und Charts (imdb.com/chart/top, /toptv, /moviemeter, /tvmeter), \
                MDBList (mdblist.com/lists/…), TMDB-Listen (themoviedb.org/list/…), Stremio-Addon-Kataloge (…/manifest.json \
                oder …/catalog/…json) sowie jede Seite mit IMDb-IDs. Maximal \(ListClient.maxItems) Titel pro Liste.
                """)
            }

            Section {
                ForEach(model.catalogs) { entry in
                    Button {
                        model.toggleCatalog(entry)
                    } label: {
                        HStack(spacing: 20) {
                            Image(systemName: entry.enabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(entry.enabled ? Theme.accent : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title)
                                Text(sourceText(entry.source))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Nach oben") { model.moveCatalog(entry, by: -1) }
                        Button("Nach unten") { model.moveCatalog(entry, by: 1) }
                        if !entry.isBuiltIn {
                            Button("Entfernen", role: .destructive) { model.removeCatalog(entry) }
                        }
                    }
                }
            } header: {
                Text("Reihen")
            } footer: {
                Text("Klicken blendet eine Reihe ein oder aus. Gedrückt halten zum Verschieben oder Entfernen.")
            }

            Section {
                Button("Standardreihen wiederherstellen", role: .destructive) { model.resetCatalogs() }
            }
        }
        .navigationTitle("Listen & Reihen")
    }

    private func sourceText(_ source: CatalogSource) -> String {
        switch source {
        case .tmdbTrending: return "TMDB · Trend der Woche"
        case .provider: return "TMDB · Streaming-Anbieter"
        case .url(let url): return url
        }
    }

    private func add() async {
        isAdding = true
        status = ""
        defer { isAdding = false }
        do {
            let entry = try await model.addList(url: url, title: title)
            let count = model.rows.first { $0.id == entry.id }?.items.count ?? 0
            status = "„\(entry.title)“ mit \(count) Titeln hinzugefügt."
            url = ""
            title = ""
        } catch {
            status = error.localizedDescription
        }
    }
}
