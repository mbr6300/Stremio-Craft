import AVKit
import SwiftUI

/// Menüpunkt „YouTube“: Suche, Abos und neueste Videos – ohne Werbung, Shorts und Vorschläge.
/// Auf iPhone, iPad und Mac zusätzlich die echte YouTube-Seite mit Werbeblocker (`YouTubeWebView`).
struct YouTubeView: View {
    @AppStorage("youtubeMode") private var mode = "app"

    var body: some View {
        #if os(tvOS)
        YouTubeHome()
        #else
        VStack(spacing: 0) {
            Picker("Ansicht", selection: $mode) {
                Text("App").tag("app")
                Text("Web").tag("web")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 8)
            if mode == "web" {
                YouTubeWebScreen()
            } else {
                YouTubeHome()
            }
        }
        .background(Theme.background.ignoresSafeArea())
        #endif
    }
}

private struct YouTubeHome: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: (channels: [YouTubeChannel], videos: [YouTubeVideo])?
    @State private var feed: [YouTubeVideo] = []
    @State private var isLoading = false
    @State private var message: String?
    @State private var playing: YouTubeVideo?
    /// Kanal-ID für „nur dieser Kanal“; `nil` = alle Abos.
    @State private var filter: String?
    @Environment(\.openRoute) private var openRoute

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s(36)) {
                HStack(spacing: Theme.s(20)) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white.opacity(0.6))
                    TextField("YouTube durchsuchen", text: $query)
                        .onSubmit { Task { await search() } }
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                }
                .font(.system(size: Theme.s(28)))
                .padding(Theme.s(18))
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.s(16)))
                .tvFocusSection()

                if let message {
                    EmptyHint(text: message, symbol: "exclamationmark.triangle")
                }
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let results, !trimmed.isEmpty {
                    searchResults(results)
                } else {
                    subscriptions
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, Theme.s(40))
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
        .onChange(of: trimmed) { if trimmed.isEmpty { results = nil } }
        .task(id: model.youtubeChannels.map(\.id)) { await loadFeed() }
        .youtubePlayer($playing)
    }

    @ViewBuilder
    private func searchResults(_ results: (channels: [YouTubeChannel], videos: [YouTubeVideo])) -> some View {
        HStack(spacing: Theme.s(24)) {
            Text("Suche „\(trimmed)“")
                .font(.system(size: Theme.s(26), weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                query = ""
                self.results = nil
            } label: {
                Label("Zurück zu den Abos", systemImage: "xmark")
            }
            .buttonStyle(PillButtonStyle())
        }
        .tvFocusSection()
        if !results.channels.isEmpty {
            section("Kanäle") {
                ChannelRow(channels: results.channels)
            }
        }
        section("Videos") {
            if results.videos.isEmpty {
                EmptyHint(text: "Nichts gefunden für „\(trimmed)“.", symbol: "magnifyingglass")
            } else {
                VideoGrid(videos: results.videos, playing: $playing)
            }
        }
    }

    @ViewBuilder
    private var subscriptions: some View {
        if model.youtubeChannels.isEmpty {
            EmptyHint(
                text: "Suche einen Kanal und tippe auf „Abonnieren“ – seine neuen Videos erscheinen dann hier.",
                symbol: "person.crop.rectangle.stack"
            )
        } else {
            section("Abos (\(model.youtubeChannels.count))") {
                channelFilter
            }
            if let channel = selectedChannel {
                HStack(spacing: Theme.s(24)) {
                    NavigationLink(value: AppRoute.youtubeChannel(channel)) {
                        Label("Kanalseite öffnen", systemImage: "person.crop.rectangle")
                    }
                    Button {
                        filter = nil
                        model.toggleSubscription(channel)
                    } label: {
                        Label("Abo beenden", systemImage: "minus.circle")
                    }
                }
                .buttonStyle(PillButtonStyle())
                .tvFocusSection()
            }
            section(selectedChannel.map { "Neueste Videos von \($0.title)" } ?? "Neu von deinen Abos") {
                let videos = selectedChannel.map { channel in feed.filter { $0.channelID == channel.id } } ?? Array(feed.prefix(120))
                if videos.isEmpty, !isLoading {
                    EmptyHint(text: "Noch keine Videos geladen.", symbol: "play.rectangle")
                } else {
                    VideoGrid(videos: videos, playing: $playing)
                }
            }
        }
    }

    private var selectedChannel: YouTubeChannel? {
        filter.flatMap { id in model.youtubeChannels.first { $0.id == id } }
    }

    /// „Alle Kanäle“ oder ein einzelner Kanal – filtert die Videos darunter.
    private var channelFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Theme.s(20)) {
                Button { filter = nil } label: {
                    ChannelChip(title: "Alle Kanäle", channel: nil, selected: selectedChannel == nil)
                }
                .buttonStyle(PosterButtonStyle())
                ForEach(model.youtubeChannels) { channel in
                    Button { filter = channel.id } label: {
                        ChannelChip(title: channel.title, channel: channel, selected: filter == channel.id)
                    }
                    .buttonStyle(PosterButtonStyle())
                    .contextMenu {
                        Button { openRoute(.youtubeChannel(channel)) } label: {
                            Label("Kanalseite öffnen", systemImage: "person.crop.rectangle")
                        }
                        Button(role: .destructive) {
                            if filter == channel.id { filter = nil }
                            model.toggleSubscription(channel)
                        } label: {
                            Label("Abo beenden", systemImage: "minus.circle")
                        }
                    }
                }
            }
            .padding(.vertical, Theme.s(12))
        }
        .scrollClipDisabled()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.s(20)) {
            Text(title)
                .font(.system(size: Theme.s(34), weight: .bold))
            content()
        }
        .tvFocusSection()
    }

    private func search() async {
        guard trimmed.count >= 2 else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            results = try await YouTubeClient.search(trimmed)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadFeed() async {
        guard !model.youtubeChannels.isEmpty else { feed = []; return }
        isLoading = feed.isEmpty
        defer { isLoading = false }
        feed = await YouTubeClient.feed(model.youtubeChannels)
    }
}

/// Seite eines Kanals: Abo-Knopf und neueste Videos.
struct YouTubeChannelView: View {
    var channel: YouTubeChannel
    @Environment(AppModel.self) private var model
    @State private var videos: [YouTubeVideo] = []
    @State private var message: String?
    @State private var isLoading = true
    @State private var playing: YouTubeVideo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s(32)) {
                HStack(spacing: Theme.s(24)) {
                    ChannelAvatar(channel: channel, size: Theme.s(90))
                    Text(channel.title)
                        .font(.system(size: Theme.s(44), weight: .heavy))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                Button {
                    model.toggleSubscription(channel)
                } label: {
                    let subscribed = model.isSubscribed(channel.id)
                    Label(subscribed ? "Abonniert" : "Abonnieren", systemImage: subscribed ? "checkmark" : "plus")
                }
                .buttonStyle(PillButtonStyle(prominent: !model.isSubscribed(channel.id)))
                .tvFocusSection()

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let message {
                    EmptyHint(text: message, symbol: "exclamationmark.triangle")
                } else if videos.isEmpty {
                    EmptyHint(text: "Keine Videos gefunden.", symbol: "play.rectangle")
                } else {
                    VideoGrid(videos: videos, playing: $playing)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, Theme.s(40))
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
        .task {
            defer { isLoading = false }
            do {
                videos = try await YouTubeClient.channelVideos(channel.id)
            } catch {
                message = error.localizedDescription
            }
        }
        .youtubePlayer($playing)
    }
}

// MARK: - Bausteine

/// Kanäle aus der Suche: öffnen die Kanalseite (dort „Abonnieren“); abonnierte mit Häkchen.
private struct ChannelRow: View {
    var channels: [YouTubeChannel]
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Theme.s(24)) {
                ForEach(channels) { channel in
                    NavigationLink(value: AppRoute.youtubeChannel(channel)) {
                        ChannelChip(title: channel.title, channel: channel, subscribed: model.isSubscribed(channel.id))
                    }
                    .buttonStyle(PosterButtonStyle())
                }
            }
            .padding(.vertical, Theme.s(12))
        }
        .scrollClipDisabled()
    }
}

private struct ChannelChip: View {
    var title: String
    /// `nil` = Eintrag „Alle Kanäle“.
    var channel: YouTubeChannel?
    var selected = false
    var subscribed = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: Theme.s(14)) {
            if let channel {
                ChannelAvatar(channel: channel, size: Theme.s(52))
            } else {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: Theme.s(26)))
                    .frame(width: Theme.s(52), height: Theme.s(52))
            }
            Text(title)
                .font(.system(size: Theme.s(22), weight: .semibold))
                .lineLimit(1)
            if subscribed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: Theme.s(22)))
                    .foregroundStyle(isFocused ? Theme.accentDeep : Theme.accent)
            }
        }
        .padding(.leading, Theme.s(10))
        .padding(.trailing, Theme.s(22))
        .padding(.vertical, Theme.s(10))
        .foregroundStyle(isFocused ? Color.black : .white)
        .background(isFocused ? Color.white : (selected ? Theme.accent : Theme.surface), in: Capsule())
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

private struct ChannelAvatar: View {
    var channel: YouTubeChannel
    var size: CGFloat

    var body: some View {
        Group {
            if let thumbnail = channel.thumbnail {
                RemoteImage(url: thumbnail, maxPoints: size, placeholderSymbol: "person.fill")
            } else {
                Text(channel.title.prefix(1).uppercased())
                    .font(.system(size: size * 0.45, weight: .bold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.accentDeep)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct VideoGrid: View {
    var videos: [YouTubeVideo]
    @Binding var playing: YouTubeVideo?
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var openRoute

    private var columns: [GridItem] {
        Platform.isPhone
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: Theme.s(400), maximum: Theme.s(480)), spacing: Theme.s(40))]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.s(48)) {
            ForEach(videos) { video in
                Button { playing = video } label: {
                    VideoTile(video: video, position: model.youtubePosition(video.id))
                }
                .buttonStyle(PosterButtonStyle())
                .contextMenu {
                    if !video.channelID.isEmpty {
                        Button {
                            openRoute(.youtubeChannel(YouTubeChannel(id: video.channelID, title: video.channelTitle)))
                        } label: {
                            Label("Kanal öffnen", systemImage: "person.crop.rectangle")
                        }
                        let channel = YouTubeChannel(id: video.channelID, title: video.channelTitle)
                        Button { model.toggleSubscription(channel) } label: {
                            model.isSubscribed(channel.id)
                                ? Label("Abo beenden", systemImage: "minus.circle")
                                : Label("Kanal abonnieren", systemImage: "plus.circle")
                        }
                    }
                    if (model.youtubePosition(video.id) ?? 0) >= 15 {
                        Button {
                            model.saveYouTubePosition(video.id, position: 0, duration: 0)
                            playing = video
                        } label: {
                            Label("Von vorne", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
            }
        }
        .tvFocusSection()
    }
}

private struct VideoTile: View {
    var video: YouTubeVideo
    var position: Double?
    @Environment(\.isFocused) private var isFocused

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de")
        return formatter
    }()

    private var meta: String {
        var parts = [video.channelTitle]
        if let published = video.published {
            parts.append(Self.relative.localizedString(for: published, relativeTo: .now))
        } else if let text = video.publishedText {
            parts.append(text)
        }
        if let views = video.viewsText { parts.append(views) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s(12)) {
            // Vorschaubilder sind 4:3 mit schwarzen Balken; auf 16:9 zuschneiden.
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    RemoteImage(url: video.thumbnail, maxPoints: Theme.s(480), placeholderSymbol: "play.rectangle")
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if let duration = video.durationText {
                        Text(duration)
                            .font(.system(size: Theme.s(18), weight: .bold).monospacedDigit())
                            .padding(.horizontal, Theme.s(8))
                            .padding(.vertical, Theme.s(3))
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: Theme.s(6)))
                            .padding(Theme.s(10))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let position, position >= 15 {
                        Label("bei \(WatchProgress.clock(position))", systemImage: "play.circle")
                            .font(.system(size: Theme.s(18), weight: .bold))
                            .padding(.horizontal, Theme.s(8))
                            .padding(.vertical, Theme.s(3))
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.s(6)))
                            .padding(Theme.s(10))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.s(14), style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.s(14), style: .continuous)
                        .strokeBorder(.white.opacity(isFocused ? 0.9 : 0), lineWidth: 4)
                }
            Text(video.title)
                .font(.system(size: Theme.s(22), weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.white)
            Text(meta)
                .font(.system(size: Theme.s(17)))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

// MARK: - Player

private extension View {
    func youtubePlayer(_ playing: Binding<YouTubeVideo?>) -> some View {
        fullScreenCover(item: playing) { video in
            YouTubePlayerScreen(video: video)
        }
    }
}

/// Holt die Streams und spielt sie mit AVPlayer (HLS: Qualität passt sich an, Tonsprachen wählbar).
private struct YouTubePlayerScreen: View {
    var video: YouTubeVideo
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = PlayerController()
    @State private var loader: HLSPlaylistLoader?
    @State private var failure: String?
    @State private var isLoading = true
    @State private var notice: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: controller.player)
                .ignoresSafeArea()
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let failure {
                VStack(alignment: .leading, spacing: Theme.s(20)) {
                    Text(failure)
                        .font(.headline)
                    Button("Schliessen") { dismiss() }
                        .buttonStyle(PillButtonStyle(prominent: true))
                }
                .padding(Theme.s(28))
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: Theme.s(16)))
                .padding(Theme.s(60))
            } else if let notice {
                Text(notice)
                    .font(.system(size: Theme.s(20), weight: .semibold))
                    .padding(Theme.s(14))
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.s(12)))
                    .padding(Theme.s(50))
                    .allowsHitTesting(false)
            }
        }
        .task {
            await start()
            // Hinweis auf geringere Qualität nach ein paar Sekunden wieder ausblenden.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            notice = nil
        }
        .onDisappear { controller.teardown() }
    }

    private func start() async {
        defer { isLoading = false }
        do {
            let stream = try await YouTubeClient.stream(video.id)
            let asset: AVURLAsset
            switch stream.source {
            case .hls(let url), .progressive(let url):
                asset = AVURLAsset(url: url)
            case .playlists(let playlists):
                let loader = HLSPlaylistLoader(playlists: playlists)
                asset = AVURLAsset(url: loader.masterURL)
                asset.resourceLoader.setDelegate(loader, queue: loader.queue)
                self.loader = loader
            }
            if stream.isReducedQuality { notice = "YouTube gibt dieses Video gerade nur in 360p frei." }
            let item = AVPlayerItem(asset: asset)
            #if os(tvOS)
            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.value = video.title as NSString
            item.externalMetadata = [title]
            #endif
            controller.onProgress = { position, duration in
                model.saveYouTubePosition(video.id, position: position, duration: duration)
            }
            controller.onFailure = { failure = $0 }
            controller.load(item: item, resume: model.youtubePosition(video.id) ?? 0)
        } catch {
            failure = error.localizedDescription
        }
    }
}
