import SwiftUI
import UIKit

/// „Meine Mediathek“: Ordner und Videos von NAS, Mac mini usw. (WebDAV). Mit mehreren Quellen zeigt
/// die Startseite zuerst die Quellen; Ordner öffnen sich als neue Seite, Videos spielen direkt – im
/// gewählten Player, die Position wird pro Datei gemerkt.
struct MediaLibraryView: View {
    /// `nil` auf der Startseite: die einzige Quelle bzw. die Liste der Quellen.
    var sourceID: String?
    /// `nil` = Startordner aus der Adresse der Quelle.
    var href: String?
    var title = "Meine Mediathek"

    @Environment(AppModel.self) private var model
    @State private var entries: [LibraryEntry] = []
    @State private var message: String?
    @State private var isLoading = false
    @State private var playing: Playing?
    /// Hinweis zur letzten Übergabe an Infuse/VLC.
    @State private var notice: String?

    private struct Playing: Identifiable {
        var entry: LibraryEntry
        var url: URL
        var resume: Double
        var progressKey: String
        var id: String { entry.id }
    }

    /// Die angezeigte Quelle; auf der Startseite nur, wenn es genau eine gibt.
    private var source: MediaLibraryConfig? {
        if let sourceID { return model.mediaLibrary(id: sourceID) }
        let all = model.mediaLibraries
        return all.count == 1 ? all[0] : nil
    }

    /// Startseite mit mehreren Quellen: zuerst die Quellen als Kacheln.
    private var showsSources: Bool {
        sourceID == nil && model.mediaLibraries.count > 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s(28)) {
                HStack(spacing: Theme.s(20)) {
                    Text(title)
                        .font(.system(size: Theme.s(48), weight: .heavy))
                        .lineLimit(1)
                    if isLoading { ProgressView() }
                    Spacer(minLength: 0)
                    if source != nil {
                        Button { Task { await load() } } label: {
                            Label("Aktualisieren", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }
                .tvFocusSection()

                if let notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.system(size: Theme.s(22), weight: .semibold))
                        .foregroundStyle(.yellow)
                }

                if showsSources {
                    grid {
                        ForEach(model.mediaLibraries) { library in
                            NavigationLink(value: AppRoute.mediaFolder(library.id, nil, library.name)) {
                                LibraryTile(
                                    entry: LibraryEntry(href: library.url, name: library.name, isFolder: true),
                                    progress: nil,
                                    symbol: "externaldrive.connected.to.line.below"
                                )
                            }
                            .buttonStyle(PosterButtonStyle())
                        }
                    }
                } else if source == nil {
                    EmptyHint(text: "Noch keine Mediathek eingerichtet. Unter Einstellungen → „Meine Mediathek“ eine Quelle hinzufügen – Server im Heimnetz (z. B. dein Mac mini) erscheinen dort von selbst.", symbol: "externaldrive.badge.wifi")
                    Button("Zu den Einstellungen") { model.selectedTab = .settings }
                        .buttonStyle(PillButtonStyle(prominent: true))
                } else if let message {
                    EmptyHint(text: message, symbol: "exclamationmark.triangle")
                    Button("Erneut versuchen") { Task { await load() } }
                        .buttonStyle(PillButtonStyle(prominent: true))
                } else if entries.isEmpty && !isLoading {
                    EmptyHint(text: "In diesem Ordner liegen keine Videos.", symbol: "folder")
                } else {
                    grid {
                        ForEach(entries) { entry in
                            tile(entry)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, Theme.s(60))
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
        .task(id: source.map { "\($0.url)|\($0.username)" }) { await load() }
        .fullScreenCover(item: $playing) { item in
            KSPlayerScreen(
                url: item.url,
                title: item.entry.displayTitle,
                resume: item.resume,
                audioLanguage: model.playbackLanguages.audio,
                subtitleLanguage: model.playbackLanguages.subtitle
            ) { position, duration in
                model.saveLibraryPosition(item.progressKey, position: position, duration: duration)
            }
        }
    }

    private func grid(@ViewBuilder _ content: () -> some View) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Theme.s(340)), spacing: Theme.s(28))],
            alignment: .leading,
            spacing: Theme.s(28)
        ) {
            content()
        }
        .tvFocusSection()
    }

    /// Position je Quelle und Datei, damit gleiche Pfade auf zwei Servern sich nicht in die Quere kommen.
    private func progressKey(_ entry: LibraryEntry) -> String {
        "\(source?.id ?? "")|\(entry.href)"
    }

    @ViewBuilder
    private func tile(_ entry: LibraryEntry) -> some View {
        if entry.isFolder {
            NavigationLink(value: AppRoute.mediaFolder(source?.id ?? "", entry.href, entry.name)) {
                LibraryTile(entry: entry, progress: nil)
            }
            .buttonStyle(PosterButtonStyle())
        } else {
            let position = model.libraryPosition(progressKey(entry))
            Button { play(entry, with: model.player, resume: position ?? 0) } label: {
                LibraryTile(entry: entry, progress: position)
            }
            .buttonStyle(PosterButtonStyle())
            .contextMenu {
                if let position, position >= 15 {
                    Button { play(entry, with: model.player, resume: 0) } label: {
                        Label("Von vorne", systemImage: "arrow.counterclockwise")
                    }
                }
                Button("Im integrierten Player") { play(entry, with: .builtIn, resume: position ?? 0) }
                Button("In Infuse öffnen") { play(entry, with: .infuse, resume: position ?? 0) }
                Button("In VLC öffnen") { play(entry, with: .vlc, resume: 0) }
            }
        }
    }

    // MARK: - Laden & Abspielen

    private func load() async {
        guard let config = source else {
            entries = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await WebDAVClient(config: config).fetchLibraryFiles(href: href)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func play(_ entry: LibraryEntry, with choice: PlayerChoice, resume: Double) {
        guard let config = source, let url = WebDAVClient(config: config).getMediaUrl(entry) else {
            message = MediaLibraryError.notConfigured.localizedDescription
            return
        }
        switch choice {
        case .builtIn:
            playing = Playing(entry: entry, url: url, resume: resume, progressKey: progressKey(entry))
        case .infuse:
            if let target = PlaybackView.infuseURL(stream: url, filename: entry.name, position: resume) {
                openExternal(target, app: "Infuse")
            }
        case .vlc:
            #if targetEnvironment(macCatalyst)
            Platform.openInMacApp(bundleID: "org.videolan.vlc", url: url) { success in
                if !success { notice = "VLC liess sich nicht öffnen. Ist VLC im Programme-Ordner installiert?" }
            }
            #else
            if let target = PlaybackView.vlcURL(stream: url) { openExternal(target, app: "VLC") }
            #endif
        }
    }

    private func openExternal(_ target: URL, app: String) {
        notice = nil
        UIApplication.shared.open(target, options: [:]) { success in
            Task { @MainActor in
                if !success {
                    notice = "\(app) liess sich nicht öffnen – ist es installiert? Lange drücken bzw. Kontextmenü: „Im integrierten Player“."
                }
            }
        }
    }
}

/// Kachel für Ordner bzw. Video: Symbol, Name, Grösse und angefangener Fortschritt.
private struct LibraryTile: View {
    var entry: LibraryEntry
    var progress: Double?
    /// Eigenes Symbol, z. B. für eine Quelle statt eines Ordners.
    var symbol: String?
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: Theme.s(20)) {
            Image(systemName: symbol ?? (entry.isFolder ? "folder.fill" : "film"))
                .font(.system(size: Theme.s(40), weight: .semibold))
                .foregroundStyle(entry.isFolder ? Theme.accent : .white.opacity(0.8))
                .frame(width: Theme.s(64))
            VStack(alignment: .leading, spacing: Theme.s(6)) {
                Text(entry.displayTitle)
                    .font(.system(size: Theme.s(24), weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: Theme.s(10)) {
                    if let size = entry.sizeText { Text(size) }
                    if let progress, progress >= 15 {
                        Label("bei \(WatchProgress.clock(progress))", systemImage: "play.circle")
                            .foregroundStyle(Theme.accent)
                    }
                }
                .font(.system(size: Theme.s(18)))
                .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.s(22))
        .frame(maxWidth: .infinity, minHeight: Theme.s(120), alignment: .leading)
        .background(isFocused ? Color.white.opacity(0.22) : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.s(18)))
        .scaleEffect(isFocused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
