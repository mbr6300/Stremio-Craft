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
    }
}

/// Seitenleiste wie in der Apple-TV-App (tvOS 18): am linken Rand nach links öffnet das Menü.
/// Jeder Bereich hat seinen eigenen Navigationsstapel.
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Entdecken", systemImage: "sparkles.tv") {
                NavigationTab(handlesDeepLinks: true) { HomeView() }
            }
            Tab("Kategorien", systemImage: "square.grid.2x2") {
                NavigationTab { CategoriesView() }
            }
            Tab("Suche", systemImage: "magnifyingglass", role: .search) {
                NavigationTab { SearchView() }
            }
            Tab("Bibliothek", systemImage: "rectangle.stack") {
                NavigationTab { LibraryView() }
            }
            Tab("Einstellungen", systemImage: "gearshape") {
                NavigationTab { SettingsView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

private struct NavigationTab<Root: View>: View {
    var handlesDeepLinks = false
    @ViewBuilder var root: Root

    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()

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
        .onAppear(perform: openDeepLink)
        .onChange(of: model.deepLink) { openDeepLink() }
    }

    private func openDeepLink() {
        guard handlesDeepLinks, let route = model.deepLink else { return }
        model.deepLink = nil
        path.append(route)
    }
}
