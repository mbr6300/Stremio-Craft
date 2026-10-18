import SwiftUI

@main
struct StremioCraftApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            HomeView()
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .detail(let item):
                        DetailView(item: item)
                    case .play(let request):
                        PlaybackView(request: request)
                    case .settings:
                        SettingsView()
                    case .search:
                        SearchView()
                    }
                }
        }
    }
}
