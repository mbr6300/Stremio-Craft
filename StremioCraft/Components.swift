import Observation
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.24, green: 0.52, blue: 1.0)
    static let accentDeep = Color(red: 0.16, green: 0.24, blue: 0.78)
    static let background = Color(red: 0.035, green: 0.05, blue: 0.11)
    static let surface = Color.white.opacity(0.07)

    /// Masse sind für den Fernseher (1920 pt breit) entworfen; auf iPad und Mac werden sie verkleinert,
    /// auf dem iPhone noch etwas mehr.
    private static let baseScale: CGFloat = Platform.isTV ? 1 : (Platform.isPhone ? 0.5 : 0.62)

    /// Einstellbare Darstellungsgrösse auf iPad und Mac (1 = Standard des iPads).
    /// Wird nur vom `AppModel` gesetzt; die Oberfläche wird danach neu aufgebaut.
    nonisolated(unsafe) static var zoom: CGFloat = 1

    static var scale: CGFloat { Platform.isTV ? 1 : baseScale * zoom }

    /// Skaliert ein TV-Mass für die aktuelle Plattform (auf tvOS unverändert).
    static func s(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }

    static var posterSize: CGSize { CGSize(width: s(200), height: s(300)) }
    static var stillSize: CGSize { CGSize(width: s(352), height: s(198)) }
    static var pagePadding: CGFloat { Platform.isTV ? 80 : (Platform.isPhone ? 16 : s(38)) }
    /// Abstand zwischen Kopfbereich (Titel/Beschreibung) und den Regalen darunter.
    static var headerGap: CGFloat { s(22) }
    /// Innenhöhe der Pills oben rechts (Region, Profil), damit beide gleich hoch sind.
    static var pillContentHeight: CGFloat { s(34) }
}

/// Stufen der Darstellungsgrösse (iPad/Mac).
enum Zoom {
    static let steps: [Double] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.45, 1.6]
    /// Das Mac-Fenster ist breiter als ein iPad, daher dort grösser.
    static var standard: Double { Platform.isMac ? 1.3 : 1.0 }

    static func label(_ value: Double) -> String { "\(Int((value * 100).rounded())) %" }
}

/// Zuletzt fokussierter Titel. Nur der Hero-Bereich beobachtet ihn, die Regale nicht –
/// so löst ein Fokuswechsel keinen Neuaufbau der ganzen Startseite aus.
@MainActor
@Observable
final class HeroState {
    var item: MediaItem?
    /// Reihe, in der der Fokus gerade liegt; die Liste richtet sie oben aus.
    var shelfID: String?
    /// Zählt jeden Fokuswechsel in den Regalen – Anlass, die Reihe erneut auszurichten.
    var focusTick = 0
    /// Liste steht ganz oben (oberste Reihe ausgerichtet). Nur dann führt „hoch“ in die Kopfzeile.
    var atTop = true

    /// Von Postern und „Alle anzeigen“ aufgerufen, wenn sie den Fokus bekommen.
    func report(item: MediaItem?, shelfID: String?) {
        if let item, self.item?.id != item.id { self.item = item }
        if let shelfID, self.shelfID != shelfID { self.shelfID = shelfID }
        focusTick &+= 1
    }
}

private struct ShelfIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Kennung der umgebenden Reihe, damit Poster ihre Reihe melden können.
    var shelfID: String? {
        get { self[ShelfIDKey.self] }
        set { self[ShelfIDKey.self] = newValue }
    }
}

/// Vertikale Regal-Liste unter einem festen Kopf. Die fokussierte Reihe wird immer
/// vollständig oben ausgerichtet, statt halb abgeschnitten zu sein.
struct ShelvesScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(HeroState.self) private var hero

    /// Wie weit der Scrollbereich unsichtbar hinter den Kopfbereich hinaufreicht.
    /// tvOS scrollt per Fokus nach, wenn ein Poster zu nah am oberen Rand der Liste liegt –
    /// das lief zeitverzögert nach der eigenen Ausrichtung und schob die Reihe nach unten.
    /// Mit diesem Vorlauf liegt die ausgerichtete Reihe weit genug vom Rand, tvOS hat nichts
    /// mehr zu korrigieren, und Hoch/Runter funktioniert trotzdem über das normale Fokus-Scrollen.
    static var overlap: CGFloat { 100 }

    @State private var viewportHeight: CGFloat = 0
    @State private var shelfHeights: [String: CGFloat] = [:]

    /// Ankerpunkt, der die Reihe mit ihrer Oberkante genau `overlap` unter den (versteckten)
    /// oberen Rand legt. `scrollTo` richtet den Punkt `y` der Reihe auf den Punkt `y` des
    /// Sichtbereichs aus: Oberkante = y · (Sichtbereich − Reihenhöhe).
    private func anchor(for id: String) -> UnitPoint {
        let rowHeight = shelfHeights[id] ?? 0
        let free = viewportHeight - rowHeight
        guard free > Self.overlap else { return .top }
        return UnitPoint(x: 0.5, y: Self.overlap / free)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Bewusst kein LazyVStack: der schätzt die Höhe noch nie gezeigter Reihen, und beim
                // ersten Aufbau verrutscht dann die Ausrichtung. Die Poster in jeder Reihe bleiben lazy.
                VStack(alignment: .leading, spacing: Theme.s(8)) {
                    content
                }
                .padding(.top, Self.overlap + 6)
                // Platz, damit auch die letzte Reihe nach oben rutschen kann.
                .padding(.bottom, Theme.s(520))
            }
            .environment(\.shelfHeights, $shelfHeights)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y < 40 } action: { _, top in hero.atTop = top }
            .topFadeMask(hidden: Self.overlap)
            .padding(.top, -Self.overlap)
            // Fokussierte Reihe immer an dieselbe Stelle, `overlap` unter dem versteckten Rand.
            .onChange(of: hero.focusTick) {
                guard let id = hero.shelfID else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: anchor(for: id)) }
            }
        }
    }
}

/// Fokus-Stil im Stil der Apple-TV-App: Poster hebt sich, Rahmen und Schatten nur im Fokus.
struct PosterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Knöpfe im Apple-TV-Stil: im Fokus weiss mit dunkler Schrift, sonst halbtransparent
/// (bzw. in Akzentfarbe für die Hauptaktion). Unabhängig von der globalen Tint-Farbe lesbar.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent, selected: selected)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let selected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: Theme.s(24), weight: .semibold))
                .padding(.horizontal, Theme.s(30))
                .padding(.vertical, Theme.s(16))
                .foregroundStyle(isFocused ? Color.black : .white)
                .background(background, in: Capsule())
                .scaleEffect(isFocused ? (configuration.isPressed ? 1.02 : 1.08) : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }

        private var background: Color {
            if isFocused { return .white }
            if prominent || selected { return Theme.accent }
            return .white.opacity(0.14)
        }
    }
}

struct PosterArtwork: View {
    var url: URL?
    var size: CGSize = Theme.posterSize
    var progress: Double?
    var symbol = "film"
    var watched = false
    var loved = false

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        RemoteImage(url: url, maxPoints: max(size.width, size.height) * 1.1, placeholderSymbol: symbol)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottom) {
                if let progress, progress > 0, !watched {
                    ProgressBar(value: progress)
                        .padding(Theme.s(10))
                }
            }
            .overlay(alignment: .topTrailing) {
                if watched { WatchedBadge().padding(Theme.s(10)) }
            }
            .overlay(alignment: .topLeading) {
                if loved { LovedBadge().padding(Theme.s(10)) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.s(14), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.s(14), style: .continuous)
                    .strokeBorder(.white.opacity(isFocused ? 0.9 : 0), lineWidth: 4)
            }
            // Kein animierter Schatten: der kostet pro Frame einen Offscreen-Pass.
            .scaleEffect(isFocused ? 1.1 : 1)
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

struct ProgressBar: View {
    var value: Double

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.3))
            .frame(height: Theme.s(6))
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: geo.size.width * min(max(value, 0), 1))
                }
            }
    }
}

/// Kennzeichnung „gesehen“ auf Postern und Folgenbildern.
struct WatchedBadge: View {
    var body: some View {
        HStack(spacing: Theme.s(6)) {
            Image(systemName: "checkmark")
                .font(.system(size: Theme.s(16), weight: .black))
            Text("Gesehen")
                .font(.system(size: Theme.s(16), weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.s(10))
        .padding(.vertical, Theme.s(5))
        .background(Theme.accent, in: Capsule())
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }
}

/// Rotes Herz für Lieblingstitel.
struct LovedBadge: View {
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: Theme.s(18), weight: .bold))
            .foregroundStyle(.white)
            .frame(width: Theme.s(36), height: Theme.s(36))
            .background(Color(red: 0.93, green: 0.2, blue: 0.33), in: Circle())
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }
}

struct PosterCard: View {
    var title: String
    var subtitle: String?
    var posterURL: URL?
    var progress: Double?
    var watched = false
    var loved = false

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s(14)) {
            PosterArtwork(url: posterURL, progress: progress, watched: watched, loved: loved)
            VStack(alignment: .leading, spacing: Theme.s(2)) {
                Text(title)
                    .font(.system(size: Theme.s(22), weight: .semibold))
                    .foregroundStyle(isFocused ? .white : .white.opacity(0.7))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: Theme.s(18)))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .frame(width: Theme.posterSize.width, alignment: .leading)
            .offset(y: isFocused ? 16 : 0)
            .animation(.easeOut(duration: 0.2), value: isFocused)
        }
    }
}

/// Poster, das zur Detailseite führt und dem Hero-Bereich meldet, wenn es fokussiert ist.
struct MediaLink: View {
    var item: MediaItem
    var subtitle: String?
    var progress: Double?
    /// Ziel für „Ganzes …-Angebot / Ganze Liste … anzeigen“ im Kontextmenü (gedrückt halten).
    var listRoute: AppRoute?

    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        NavigationLink(value: AppRoute.detail(item)) {
            FocusReporter(item: item) {
                PosterCard(
                    title: item.title,
                    subtitle: subtitle ?? item.yearText,
                    posterURL: item.posterURL,
                    progress: progress,
                    watched: model.isWatched(item),
                    loved: model.isLoved(item)
                )
            }
        }
        .buttonStyle(PosterButtonStyle())
        .contextMenu {
            Button {
                model.toggleLoved(item)
            } label: {
                Label(model.isLoved(item) ? "Nicht mehr lieben" : "Lieben ♥",
                      systemImage: model.isLoved(item) ? "heart.slash" : "heart")
            }
            Button {
                model.toggleDisliked(item)
            } label: {
                Label(model.isDisliked(item) ? "Doch interessant" : "Kein Interesse",
                      systemImage: model.isDisliked(item) ? "hand.thumbsup" : "hand.thumbsdown")
            }
            if item.normalizedType == "movie" {
                let watched = model.isWatched(item)
                Button {
                    model.setWatched([AppModel.movieKey(item.tmdbId)], !watched)
                    if !watched { model.clearProgressIfWatched(item) }
                } label: {
                    Label(watched ? "Als ungesehen markieren" : "Als gesehen markieren",
                          systemImage: watched ? "eye.slash" : "checkmark.circle")
                }
            }
            if let listRoute {
                // NavigationLink im Kontextmenü ist auf tvOS unzuverlässig; daher über `openRoute`.
                Button {
                    openRoute(listRoute)
                } label: {
                    Label(listRoute.seeAllTitle(catalogs: model.catalogs), systemImage: "square.grid.3x3")
                }
            }
            Button {
                model.toggleFavorite(item)
            } label: {
                Label(
                    model.isFavorite(item) ? "Aus Meine Liste entfernen" : "Zu Meine Liste hinzufügen",
                    systemImage: model.isFavorite(item) ? "minus" : "plus"
                )
            }
        }
    }
}

/// Letzte Kachel eines Regals: führt zur vollständigen Liste.
struct SeeAllCard: View {
    var route: AppRoute

    var body: some View {
        NavigationLink(value: route) {
            SeeAllLabel(route: route)
        }
        .buttonStyle(PosterButtonStyle())
    }

    private struct SeeAllLabel: View {
        var route: AppRoute
        @Environment(AppModel.self) private var model
        @Environment(\.isFocused) private var isFocused
        @Environment(\.shelfID) private var shelfID
        @Environment(HeroState.self) private var hero: HeroState?

        var body: some View {
            VStack(spacing: Theme.s(18)) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: Theme.s(46)))
                Text(route.seeAllTitle(catalogs: model.catalogs))
                    .font(.system(size: Theme.s(24), weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, Theme.s(14))
            }
            .foregroundStyle(isFocused ? Color.black : .white)
            .frame(width: Theme.posterSize.width, height: Theme.posterSize.height)
            .background(isFocused ? Color.white : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.s(14), style: .continuous))
            .scaleEffect(isFocused ? 1.1 : 1)
            .animation(.easeOut(duration: 0.18), value: isFocused)
            .onChange(of: isFocused) { _, focused in
                if focused { hero?.report(item: nil, shelfID: shelfID) }
            }
        }
    }
}

extension View {
    /// Schneidet nur oben ab (mit weichem Übergang), seitlich und unten darf Inhalt über den Rand.
    /// Nötig für vertikale Regal-Listen unter einem festen Kopfbereich.
    /// `hidden`: oberer Bereich, der komplett unsichtbar bleibt (Vorlauf hinter dem Kopf).
    func topFadeMask(hidden: CGFloat = 0) -> some View {
        mask {
            VStack(spacing: Theme.s(0)) {
                Color.clear.frame(height: hidden)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: Theme.s(14))
                Color.black
            }
            .padding(.horizontal, -400)
            .padding(.bottom, -400)
        }
    }
}

struct FocusReporter<Content: View>: View {
    var item: MediaItem
    @ViewBuilder var content: Content

    @Environment(\.isFocused) private var isFocused
    @Environment(\.shelfID) private var shelfID
    @Environment(HeroState.self) private var hero: HeroState?

    var body: some View {
        content
            .onChange(of: isFocused) { _, focused in
                if focused { hero?.report(item: item, shelfID: shelfID) }
            }
    }
}

/// Horizontales Regal mit Titel. Lazy, damit nur sichtbare Poster existieren.
struct Shelf<Content: View>: View {
    var title: String
    /// Kennung für das Ausrichten in `ShelvesScroll`; muss zur Identität in der Liste passen.
    var shelfID: String?
    var isLoading = false
    /// Hängt am Ende eine „Alle anzeigen“-Kachel an.
    var seeAll: AppRoute?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s(4)) {
            HStack(spacing: Theme.s(14)) {
                Text(title)
                    .font(.system(size: Theme.s(30), weight: .bold))
                if isLoading {
                    ProgressView().scaleEffect(0.6)
                }
            }
            .padding(.leading, Theme.pagePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.s(36)) {
                    content
                    if let seeAll {
                        SeeAllCard(route: seeAll)
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, Theme.s(26))
                .padding(.bottom, Theme.s(44))
            }
            .scrollClipDisabled()
        }
        // Luft über dem Titel, damit er auch oben ausgerichtet nicht in der Ausblendkante liegt.
        .padding(.top, Theme.s(14))
        // Höhe melden: `ShelvesScroll` braucht sie, um die Reihe exakt auszurichten.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            guard let shelfID else { return }
            shelfHeights?.wrappedValue[shelfID] = height
        }
        .tvFocusSection()
        .environment(\.shelfID, shelfID)
    }

    @Environment(\.shelfHeights) private var shelfHeights}

private struct ShelfHeightsKey: EnvironmentKey {
    static let defaultValue: Binding<[String: CGFloat]>? = nil
}

extension EnvironmentValues {
    /// Gemessene Höhen der Regale, von `ShelvesScroll` bereitgestellt.
    var shelfHeights: Binding<[String: CGFloat]>? {
        get { self[ShelfHeightsKey.self] }
        set { self[ShelfHeightsKey.self] = newValue }
    }
}

struct PlaceholderShelfItems: View {
    var count = 7

    var body: some View {
        ForEach(0..<count, id: \.self) { _ in
            VStack(alignment: .leading, spacing: Theme.s(14)) {
                RoundedRectangle(cornerRadius: Theme.s(14), style: .continuous)
                    .fill(Theme.surface)
                    .frame(width: Theme.posterSize.width, height: Theme.posterSize.height)
                RoundedRectangle(cornerRadius: Theme.s(4))
                    .fill(Theme.surface)
                    .frame(width: Theme.s(140), height: Theme.s(18))
            }
        }
    }
}

struct EmptyHint: View {
    var text: String
    var symbol = "sparkles"

    var body: some View {
        HStack(spacing: Theme.s(16)) {
            Image(systemName: symbol)
                .font(.system(size: Theme.s(30)))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: Theme.s(24)))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.vertical, Theme.s(20))
    }
}

/// Bildschirmfüllender, abgedunkelter Hintergrund. Das alte Bild bleibt stehen, bis das neue
/// fertig dekodiert ist, dann wird direkt überblendet – kein Zwischenzustand mit Platzhalter.
struct BackdropLayer: View {
    var url: URL?

    /// TMDB liefert Hintergründe mit 1280 px; für ein abgedunkeltes Bild reicht das.
    static let maxPixel: CGFloat = 1280

    @State private var image: UIImage?
    @State private var imageURL: URL?

    var body: some View {
        ZStack {
            Theme.background
            if let image {
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .opacity(0.55)
                    .id(imageURL)
                    .transition(.opacity)
            }
            LinearGradient(
                colors: [Theme.background.opacity(0.95), Theme.background.opacity(0.55), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                colors: [.clear, Theme.background.opacity(0.85), Theme.background],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .task(id: url) {
            guard let url else {
                withAnimation(.easeInOut(duration: 0.4)) { image = nil }
                return
            }
            guard url != imageURL else { return }
            let next: UIImage?
            if let hit = ImagePipeline.shared.cached(url, maxPixel: Self.maxPixel) {
                next = hit
            } else {
                next = await ImagePipeline.shared.image(url, maxPixel: Self.maxPixel)
            }
            guard !Task.isCancelled, let next else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                image = next
                imageURL = url
            }
        }
    }
}

/// Gelbes IMDb-Logo mit Bewertung, wie man es von IMDb kennt.
struct IMDbBadge: View {
    var rating: Double

    var body: some View {
        HStack(spacing: Theme.s(8)) {
            Text("IMDb")
                .font(.system(size: Theme.s(17), weight: .black))
                .foregroundStyle(.black)
                .padding(.horizontal, Theme.s(7))
                .padding(.vertical, Theme.s(2))
                .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: Theme.s(5)))
            Text(String(format: "%.1f", rating))
                .font(.system(size: Theme.s(22), weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
        }
    }
}

/// Metazeile: Typ, Jahr, IMDb-Bewertung (sonst TMDB), Metascore, Freigabe.
struct MetaLine: View {
    var item: MediaItem
    var imdb: IMDbInfo?
    var extra: [String] = []

    var body: some View {
        HStack(spacing: Theme.s(14)) {
            Text([item.normalizedType == "tv" ? "Serie" : "Film", item.yearText].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                .foregroundStyle(Theme.accent)
            if let rating = imdb?.rating {
                IMDbBadge(rating: rating)
                if let votes = imdb?.votesText {
                    Text(votes).foregroundStyle(.white.opacity(0.55))
                }
            } else if let rating = item.rating, rating > 0 {
                Text(String(format: "★ %.1f", rating)).foregroundStyle(Theme.accent)
            }
            if let score = imdb?.metascore {
                Text("\(score)")
                    .font(.system(size: Theme.s(18), weight: .heavy))
                    .padding(.horizontal, Theme.s(6))
                    .padding(.vertical, Theme.s(1))
                    .background(score >= 61 ? Color.green : score >= 40 ? Color.yellow : Color.red, in: RoundedRectangle(cornerRadius: Theme.s(4)))
                    .foregroundStyle(.black)
            }
            if let certificate = imdb?.certificate {
                Text(certificate)
                    .font(.system(size: Theme.s(17), weight: .bold))
                    .padding(.horizontal, Theme.s(6))
                    .padding(.vertical, Theme.s(1))
                    .overlay(RoundedRectangle(cornerRadius: Theme.s(4)).strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
                    .foregroundStyle(.white.opacity(0.8))
            }
            ForEach(extra, id: \.self) { text in
                Text(text).foregroundStyle(.white.opacity(0.7))
            }
        }
        .font(.system(size: Theme.s(22), weight: .semibold))
        .lineLimit(1)
    }
}

extension MediaItem {
    var metaText: String {
        let kind = normalizedType == "tv" ? "Serie" : "Film"
        let rating = rating.flatMap { $0 > 0 ? String(format: "★ %.1f", $0) : nil } ?? ""
        return [kind, yearText, rating].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }
}
