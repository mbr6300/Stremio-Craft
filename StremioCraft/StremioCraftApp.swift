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

/// Seitenleiste wie in der Apple-TV-App (tvOS 18): am linken Rand nach links öffnet das Menü.
/// Jeder Bereich hat seinen eigenen Navigationsstapel.
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Entdecken", systemImage: "sparkles.tv") {
                NavigationTab { HomeView() }
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
