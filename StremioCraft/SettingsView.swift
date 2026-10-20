import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var country = "CH"
    @State private var tmdbKey = ""
    @State private var providers = ""
    @State private var sort = ""
    @State private var qualityFilter = ""
    @State private var language = ""
    @State private var player: PlayerChoice = .platformDefault
    @State private var autoPlay = true
    @State private var tokenDraft = ""
    @State private var status = ""
    @State private var isBusy = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Hilfe") {
                Button {
                    model.showHelp = true
                } label: {
                    Label("Tipps & versteckte Funktionen anzeigen", systemImage: "questionmark.circle")
                }
            }

            SyncSettingsSection()

            Section("Startseite") {
                NavigationLink(value: AppRoute.lists) {
                    LabeledContent("Listen & Reihen", value: "\(model.catalogs.filter(\.enabled).count) aktiv")
                }
                Picker("Region", selection: $country) {
                    ForEach(Region.all) { Text("\($0.flag)  \($0.name)").tag($0.id) }
                }
                if !Platform.isTV {
                    zoomControl
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
                Text("Der integrierte Player spielt MKV und MP4 mit allen Ton- und Untertitelspuren und merkt sich die Position für „Weiterschauen“ selbst. Infuse kann zusätzlich Dolby Vision und Atmos am besten ausgeben und meldet die Position beim Schliessen zurück. VLC spielt fast alle Formate, startet aber immer von vorne und meldet keine Position.")
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
                    HStack(spacing: Theme.s(16)) {
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

    /// Grösse der Poster und Texte: mehr oder weniger Titel pro Reihe (iPad/Mac).
    private var zoomControl: some View {
        LabeledContent {
            HStack(spacing: 12) {
                Button { model.stepZoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(model.zoom <= Zoom.steps.first!)
                Text(Zoom.label(model.zoom))
                    .monospacedDigit()
                    .frame(minWidth: 52)
                Button { model.stepZoom(1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(model.zoom >= Zoom.steps.last!)
                if model.zoom != Zoom.standard {
                    Button("Standard") { model.setZoom(Zoom.standard) }
                }
            }
            .buttonStyle(.borderless)
        } label: {
            Text("Darstellungsgrösse")
            Text(Platform.isMac ? "Auch mit ⌘+ und ⌘− im Menü „Darstellung“." : "Kleiner zeigt mehr Titel pro Reihe.")
        }
    }

    private var currentOptions: TorrentioOptions {
        TorrentioOptions(providers: providers, sort: sort, qualityFilter: qualityFilter, language: language)
    }

    private func load() {
        // Region immer frisch übernehmen: sie kann auf der Startseite gewechselt worden sein
        // und darf beim Verlassen der Einstellungen nicht mit einem alten Wert überschrieben werden.
        country = model.country
        guard !loaded else { return }
        loaded = true
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
///
/// Verschieben wie auf dem Apple-TV-Homescreen: Reihe anheben, mit ↑/↓ bewegen, mit Klick ablegen.
/// Während eine Reihe angehoben ist, sind alle anderen gesperrt – so landen die Pfeiltasten
/// als Verschiebebefehl bei ihr, statt den Fokus weiterzuschieben.
struct ListsView: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var title = ""
    @State private var status = ""
    @State private var isAdding = false
    /// Im Reihenfolge-Modus hebt ein Klick eine Reihe an, statt sie ein-/auszublenden.
    @State private var reorderMode = false
    @State private var picked: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s(36)) {
                    Text("Listen & Reihen")
                        .font(.system(size: Theme.s(52), weight: .heavy))
                    rowsSection(proxy)
                    addSection
                        .disabled(picked != nil)
                    Button("Standardreihen wiederherstellen") { model.resetCatalogs() }
                        .buttonStyle(PillButtonStyle())
                        .disabled(picked != nil)
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, Theme.s(50))
            }
            .scrollClipDisabled()
        }
        .background(Theme.background.ignoresSafeArea())
    }

    // MARK: - Reihen

    private func rowsSection(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: Theme.s(18)) {
            HStack(spacing: Theme.s(24)) {
                Text("Reihen auf der Startseite")
                    .font(.system(size: Theme.s(32), weight: .bold))
                Spacer()
                Button(reorderMode ? "Fertig" : "Reihenfolge ändern") {
                    reorderMode.toggle()
                    picked = nil
                }
                .buttonStyle(PillButtonStyle(selected: reorderMode))
                .disabled(picked != nil)
            }
            Text(hint)
                .font(.system(size: Theme.s(21)))
                .foregroundStyle(picked == nil ? .white.opacity(0.55) : Theme.accent)
            VStack(spacing: Theme.s(12)) {
                ForEach(model.catalogs) { entry in
                    CatalogRowButton(
                        entry: entry,
                        source: sourceText(entry.source),
                        reorderMode: reorderMode,
                        isPicked: picked == entry.id,
                        isLocked: picked != nil && picked != entry.id
                    ) {
                        if picked == entry.id {
                            picked = nil
                        } else if reorderMode {
                            picked = entry.id
                        } else {
                            model.toggleCatalog(entry)
                        }
                    } onMove: { offset in
                        withAnimation(.easeInOut(duration: 0.2)) { model.moveCatalog(entry, by: offset) }
                        proxy.scrollTo(entry.id, anchor: .center)
                    } onDrop: {
                        picked = nil
                    }
                    .id(entry.id)
                    .contextMenu {
                        Button("Verschieben") {
                            reorderMode = true
                            picked = entry.id
                        }
                        Button("Ganz nach oben") { withAnimation { model.moveCatalog(entry, toTop: true) } }
                        Button("Ganz nach unten") { withAnimation { model.moveCatalog(entry, toTop: false) } }
                        if !entry.isBuiltIn {
                            Button("Entfernen", role: .destructive) { model.removeCatalog(entry) }
                        }
                    }
                }
            }
            .tvFocusSection()
        }
    }

    private var hint: String {
        if picked != nil { return "Mit ↑ und ↓ verschieben, mit Klick oder Zurück ablegen." }
        if reorderMode { return "Reihe auswählen, die du verschieben möchtest." }
        return "Klick blendet eine Reihe ein oder aus. Gedrückt halten für Verschieben, ganz nach oben/unten oder Entfernen."
    }

    // MARK: - Eigene Liste

    private var addSection: some View {
        VStack(alignment: .leading, spacing: Theme.s(18)) {
            Text("Eigene Liste hinzufügen")
                .font(.system(size: Theme.s(32), weight: .bold))
            TextField("Adresse der Liste", text: $url)
                .frame(maxWidth: Theme.s(1200))
            TextField("Name (optional)", text: $title)
                .frame(maxWidth: Theme.s(1200))
            HStack(spacing: Theme.s(18)) {
                Button {
                    Task { await add() }
                } label: {
                    HStack(spacing: Theme.s(14)) {
                        if isAdding { ProgressView() }
                        Text(isAdding ? "Liste wird geladen…" : "Liste hinzufügen")
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(isAdding)
                if !status.isEmpty {
                    Text(status).foregroundStyle(.yellow)
                }
            }
            Text("""
            Unterstützt: IMDb-Listen (imdb.com/list/ls…) und Charts (imdb.com/chart/top, /toptv, /moviemeter, /tvmeter), \
            MDBList (mdblist.com/lists/…), TMDB-Listen (themoviedb.org/list/…), Stremio-Addon-Kataloge (…/manifest.json \
            oder …/catalog/…json) sowie jede Seite mit IMDb-IDs. Maximal \(ListClient.maxItems) Titel pro Liste.
            """)
            .font(.system(size: Theme.s(19)))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: Theme.s(1300), alignment: .leading)
        }
        .tvFocusSection()
    }

    private func sourceText(_ source: CatalogSource) -> String {
        switch source {
        case .tmdbTrending: return "TMDB · Trend der Woche"
        case .trending(let type): return type == "tv" ? "TMDB · Trend der Woche, Serien" : "TMDB · Trend der Woche, Filme"
        case .favorites: return "Deine Merkliste"
        case .loved: return "Titel, die du mit ♥ markiert hast"
        case .newOnProviders: return "TMDB · Neue Titel auf Netflix, Disney+, Prime, HBO, Paramount+"
        case .recommendations: return "TMDB-Empfehlungen zu deinen Lieblingstiteln (♥) und deiner Merkliste"
        case .provider(let id):
            let region = TMDBClient.providers.first { $0.id == id }?.region
            return "TMDB · Streaming-Anbieter" + (region.map { " · \($0)-Katalog" } ?? "")
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

/// Eine Reihe in der Verwaltung. Angehoben fängt sie ↑/↓ und Zurück ab.
private struct CatalogRowButton: View {
    var entry: CatalogEntry
    var source: String
    var reorderMode: Bool
    var isPicked: Bool
    var isLocked: Bool
    var action: () -> Void
    var onMove: (Int) -> Void
    var onDrop: () -> Void

    var body: some View {
        #if os(tvOS)
        Button(action: action) {
            RowLabel(entry: entry, source: source, reorderMode: reorderMode, isPicked: isPicked)
        }
        .buttonStyle(RowButtonStyle(isPicked: isPicked))
        .disabled(isLocked)
        .opacity(isLocked ? 0.45 : 1)
        .onMoveCommand { direction in
            guard isPicked else { return }
            switch direction {
            case .up: onMove(-1)
            case .down: onMove(1)
            default: break
            }
        }
        .tvOnExitCommand(perform: isPicked ? onDrop : nil)
        #else
        // iPad: keine Pfeiltasten – die angehobene Reihe bekommt Knöpfe zum Verschieben.
        HStack(spacing: Theme.s(12)) {
            Button(action: action) {
                RowLabel(entry: entry, source: source, reorderMode: reorderMode, isPicked: isPicked)
            }
            .buttonStyle(RowButtonStyle(isPicked: isPicked))
            if isPicked {
                Button { onMove(-1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(PillButtonStyle())
                Button { onMove(1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .disabled(isLocked)
        .opacity(isLocked ? 0.45 : 1)
        #endif
    }

    private struct RowLabel: View {
        var entry: CatalogEntry
        var source: String
        var reorderMode: Bool
        var isPicked: Bool

        var body: some View {
            HStack(spacing: Theme.s(22)) {
                Image(systemName: entry.enabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Theme.s(30)))
                    .foregroundStyle(entry.enabled ? Theme.accent : .white.opacity(0.4))
                VStack(alignment: .leading, spacing: Theme.s(4)) {
                    Text(entry.title)
                        .font(.system(size: Theme.s(26), weight: .semibold))
                    Text(source)
                        .font(.system(size: Theme.s(18)))
                        .opacity(0.6)
                        .lineLimit(1)
                }
                Spacer(minLength: 20)
                if isPicked {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: Theme.s(28), weight: .bold))
                } else if reorderMode {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: Theme.s(28), weight: .semibold))
                        .opacity(0.6)
                }
            }
            .padding(.horizontal, Theme.s(28))
            .padding(.vertical, Theme.s(16))
            .frame(maxWidth: Theme.s(1400), alignment: .leading)
        }
    }

    private struct RowButtonStyle: ButtonStyle {
        var isPicked: Bool

        func makeBody(configuration: Configuration) -> some View {
            StyledRow(configuration: configuration, isPicked: isPicked)
        }

        private struct StyledRow: View {
            let configuration: ButtonStyleConfiguration
            let isPicked: Bool
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                configuration.label
                    .foregroundStyle(isFocused && !isPicked ? Color.black : .white)
                    .background(background, in: RoundedRectangle(cornerRadius: Theme.s(16), style: .continuous))
                    .scaleEffect(isPicked ? 1.04 : (isFocused ? 1.02 : 1))
                    .shadow(color: .black.opacity(isPicked ? 0.5 : 0), radius: 16, y: 8)
                    .animation(.easeOut(duration: 0.15), value: isFocused)
                    .animation(.easeOut(duration: 0.15), value: isPicked)
            }

            private var background: Color {
                if isPicked { return Theme.accent }
                return isFocused ? .white : .white.opacity(0.08)
            }
        }
    }
}
