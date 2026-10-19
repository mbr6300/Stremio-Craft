import SwiftUI

@main
struct StremioCraftApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
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
                // Solange das Schnellmenü offen ist, bekommt nur es den Fokus.
                .disabled(quickMenu)
            if quickMenu {
                QuickMenu(isPresented: $quickMenu)
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.25), value: quickMenu)
        .background(LongPressLeftDetector { quickMenu = true })
        #else
        // iPad: Tab-Leiste bzw. Seitenleiste des Systems, kein Fernbedienungs-Schnellmenü nötig.
        // Neuaufbau bei geänderter Darstellungsgrösse, da die Masse statisch berechnet werden.
        tabs
            .id(model.zoom)
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

/// Nach dem Schliessen des Players: Streamliste verlassen und die Detailseite des Titels zeigen.
struct FinishPlaybackAction {
    var action: (MediaItem) -> Void
    func callAsFunction(_ media: MediaItem) { action(media) }
}

private struct FinishPlaybackKey: EnvironmentKey {
    static let defaultValue = FinishPlaybackAction { _ in }
}

extension EnvironmentValues {
    var openRoute: OpenRouteAction {
        get { self[OpenRouteKey.self] }
        set { self[OpenRouteKey.self] = newValue }
    }

    var finishPlayback: FinishPlaybackAction {
        get { self[FinishPlaybackKey.self] }
        set { self[FinishPlaybackKey.self] = newValue }
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
        .environment(\.finishPlayback, FinishPlaybackAction { media in
            if case .play = path.last { path.removeLast() }
            // Kam die Wiedergabe von der Detailseite, genügt das Zurückgehen; sonst (z. B. aus
            // „Weiterschauen“) die Detailseite öffnen.
            if case .detail(let shown)? = path.last, shown.id == media.id { return }
            path.append(.detail(media))
        })
        .onAppear(perform: openDeepLink)
        .onChange(of: model.deepLink) { openDeepLink() }
    }

    private func openDeepLink() {
        guard handlesDeepLinks, let route = model.deepLink else { return }
        model.deepLink = nil
        path.append(route)
    }
}
