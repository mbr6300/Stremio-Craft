import SwiftUI

@main
struct StremioCraftApp: App {
    @State private var model: AppModel
    @State private var sync: SyncService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _sync = State(initialValue: SyncService(model: model))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(sync)
                // Geräte-Sync: beim Start, beim Zurückkehren und beim Verlassen der App abgleichen.
                .task { await sync.syncNow() }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .inactive { Task { await sync.syncNow() } }
                }
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                // x-callback von Infuse: stremiocraft://infuse-success?position=…
                .onOpenURL { model.handleCallback($0) }
                #if DEBUG
                // Zum Testen ohne Fernbedienung: `simctl launch … -openURL stremiocraft://detail/movie/155`
                .onAppear {
                    if let link = UserDefaults.standard.string(forKey: "openURL"), let url = URL(string: link) {
                        model.handleCallback(url)
                    }
                    // Sync-Tests: `-debugRemoveProgress Sherlock` entfernt einen Titel aus „Weiterschauen“.
                    if let title = UserDefaults.standard.string(forKey: "debugRemoveProgress"),
                       let entry = model.continueWatching.first(where: { $0.title == title }) {
                        model.removeProgress(entry)
                        print("debugRemoveProgress: entfernt", title)
                    }
                    // Sync-Tests: `-syncReset YES` beendet den Sync auf diesem Gerät.
                    if UserDefaults.standard.bool(forKey: "syncReset") { Task { await sync.leave() } }
                    // Kopplung ohne Fernbedienung testen: `-syncStartPairing YES` zeigt sofort eine PIN.
                    if UserDefaults.standard.bool(forKey: "syncStartPairing"), !sync.isEnabled {
                        Task { await sync.startPairing() }
                    }
                    // Gegenstück: `-syncSendPIN 123456` übergibt den Code an das wartende Gerät.
                    if let pin = UserDefaults.standard.string(forKey: "syncSendPIN"), sync.isEnabled {
                        Task { print("syncSendPIN:", await sync.sendCode(toPIN: pin) ?? "ok") }
                    }
                }
                #endif
        }
        #if !os(tvOS)
        .commands {
            // Mac-Menü „Darstellung“ bzw. Tastenkürzel auf dem iPad.
            CommandGroup(after: .toolbar) {
                Button("Grösser") { model.stepZoom(1) }
                    .keyboardShortcut("+")
                Button("Kleiner") { model.stepZoom(-1) }
                    .keyboardShortcut("-")
                Button("Standardgrösse") { model.setZoom(Zoom.standard) }
                    .keyboardShortcut("0")
            }
            CommandGroup(replacing: .help) {
                Button("Tipps & Funktionen von Stremio Craft") { model.showHelp = true }
                    .keyboardShortcut("?")
            }
        }
        #endif
    }
}

enum AppTab: String, Hashable {
    case profiles, home, categories, search, library, settings
}

/// Seitenleiste wie in der Apple-TV-App (tvOS 18): am linken Rand nach links öffnet das Menü.
/// Jeder Bereich hat seinen eigenen Navigationsstapel.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var quickMenu = false

    var body: some View {
        #if os(tvOS)
        ZStack(alignment: .leading) {
            tabs
                // Solange Schnellmenü oder Hilfe offen sind, bekommen nur sie den Fokus.
                .disabled(quickMenu || model.showHelp)
            if quickMenu {
                QuickMenu(isPresented: $quickMenu)
                    .zIndex(1)
            }
            if model.showHelp {
                HelpOverlay()
                    .zIndex(2)
            }
        }
        .animation(.easeOut(duration: 0.25), value: quickMenu)
        .animation(.easeOut(duration: 0.25), value: model.showHelp)
        .background(LongPressLeftDetector { if !model.showHelp { quickMenu = true } })
        #else
        // iPad: Tab-Leiste bzw. Seitenleiste des Systems, kein Fernbedienungs-Schnellmenü nötig.
        // Neuaufbau bei geänderter Darstellungsgrösse, da die Masse statisch berechnet werden.
        ZStack {
            tabs
                .id(model.zoom)
            if model.showHelp {
                HelpOverlay()
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.showHelp)
        #endif
    }

    private var tabs: some View {
        @Bindable var model = model
        return TabView(selection: $model.selectedTab) {
            // Oben wie in der Apple-TV-App: aktives Profil, führt zu „Wer schaut?“.
            Tab(model.activeProfile?.name ?? "Alle", systemImage: "person.crop.circle", value: AppTab.profiles) {
                NavigationTab { ProfilesView() }
            }
            Tab("Entdecken", systemImage: Platform.isTV ? "sparkles.tv" : "sparkles", value: AppTab.home) {
                NavigationTab(handlesDeepLinks: true) { HomeView() }
            }
            Tab("Kategorien", systemImage: "square.grid.2x2", value: AppTab.categories) {
                NavigationTab { CategoriesView() }
            }
            Tab("Suche", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationTab { SearchView() }
            }
            Tab("Bibliothek", systemImage: "rectangle.stack", value: AppTab.library) {
                NavigationTab { LibraryView() }
            }
            Tab("Einstellungen", systemImage: "gearshape", value: AppTab.settings) {
                NavigationTab { SettingsView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

/// Öffnet eine Ansicht im Navigationsstapel des aktuellen Bereichs.
struct OpenRouteAction {
    var action: (AppRoute) -> Void
    func callAsFunction(_ route: AppRoute) { action(route) }
}

private struct OpenRouteKey: EnvironmentKey {
    static let defaultValue = OpenRouteAction { _ in }
}

extension EnvironmentValues {
    var openRoute: OpenRouteAction {
        get { self[OpenRouteKey.self] }
        set { self[OpenRouteKey.self] = newValue }
    }
}

private struct NavigationTab<Root: View>: View {
    var handlesDeepLinks = false
    @ViewBuilder var root: Root

    @Environment(AppModel.self) private var model
    @State private var path: [AppRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .detail(let item):
                        DetailView(item: item)
                    case .play(let request):
                        PlaybackView(request: request)
                    case .lists:
                        ListsView()
                    case .discover(let query):
                        DiscoverGridView(query: query)
                    case .provider(let id):
                        ProviderView(providerId: id)
                    case .row(let id):
                        RowGridView(rowId: id)
                    }
                }
        }
        // Öffnet Ansichten im Stapel *dieses* Bereichs (z. B. aus Kontextmenüs, wo NavigationLink unzuverlässig ist).
        .environment(\.openRoute, OpenRouteAction { path.append($0) })
        .onAppear(perform: openDeepLink)
        .onChange(of: model.deepLink) { openDeepLink() }
        .onChange(of: model.finishedPlayback) { showDetailAfterPlayback() }
    }

    /// Nach dem Schliessen des Players die Streamliste durch die Detailseite ersetzen.
    /// Über das Modell statt per Environment: auf tvOS kam die Aktion in der Wiedergabe nicht an.
    private func showDetailAfterPlayback() {
        guard let media = model.finishedPlayback,
              case .play(let request)? = path.last, request.media.id == media.id else { return }
        model.finishedPlayback = nil
        path.removeLast()
        // Kam die Wiedergabe von der Detailseite, genügt das Zurückgehen; sonst (z. B. aus
        // „Weiterschauen“) die Detailseite öffnen.
        if case .detail(let shown)? = path.last, shown.id == media.id { return }
        path.append(.detail(media))
    }

    private func openDeepLink() {
        guard handlesDeepLinks, let route = model.deepLink else { return }
        model.deepLink = nil
        path.append(route)
    }
}
