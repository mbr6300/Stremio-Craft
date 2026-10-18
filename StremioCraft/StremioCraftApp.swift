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
        }
    }
}

/// Tab-Leiste oben wie in tvOS üblich; jeder Tab hat seinen eigenen Navigationsstapel.
struct RootView: View {
    var body: some View {
        TabView {
            NavigationTab { HomeView() }
                .tabItem { Label("Entdecken", systemImage: "sparkles.tv") }
            NavigationTab { SearchView() }
                .tabItem { Label("Suche", systemImage: "magnifyingglass") }
            NavigationTab { LibraryView() }
                .tabItem { Label("Bibliothek", systemImage: "rectangle.stack") }
            NavigationTab { SettingsView() }
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
        }
    }
}

private struct NavigationTab<Root: View>: View {
    @ViewBuilder var root: Root

    var body: some View {
        NavigationStack {
            root
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .detail(let item):
                        DetailView(item: item)
                    case .play(let request):
                        PlaybackView(request: request)
                    case .lists:
                        ListsView()
                    }
                }
        }
    }
}
