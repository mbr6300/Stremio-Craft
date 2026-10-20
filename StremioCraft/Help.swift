import SwiftUI

/// Eine Seite der Hilfe. Die Bedienung unterscheidet sich je Gerät, daher drei Varianten.
struct HelpPage: Identifiable {
    var id: String { title }
    var symbol: String
    var title: String
    var text: String
    /// Kurzer Bedienhinweis, hervorgehoben unter dem Text.
    var gesture: String?

    /// Wählt den passenden Text für Apple TV, iPad bzw. Mac.
    static func pick(tv: String, pad: String, mac: String? = nil) -> String {
        if Platform.isTV { return tv }
        if Platform.isMac { return mac ?? pad }
        return pad
    }

    private static var holdTitle: String {
        pick(tv: "Touchfläche gedrückt halten", pad: "Lange tippen", mac: "Rechtsklick (oder lange klicken)")
    }

    static var all: [HelpPage] {
        var pages = [
            HelpPage(
                symbol: "sparkles",
                title: "Willkommen bei Stremio Craft",
                text: "Stremio Craft zeigt dir Filme und Serien aus TMDB und IMDb, findet passende Streams über Torrentio und schaltet sie mit Real-Debrid frei. Abgespielt wird im integrierten Player, in Infuse oder in VLC.\n\nDiese Tipps zeigen die wichtigsten – und ein paar gut versteckte – Funktionen.",
                gesture: pick(tv: "Mit „Weiter“ blättern, Menü-Taste schliesst.", pad: "Mit „Weiter“ blättern.", mac: "Mit „Weiter“ blättern, Esc schliesst.")
            ),
            HelpPage(
                symbol: "sidebar.left",
                title: "Menü – von überall",
                text: pick(
                    tv: "Ganz links in einer Reihe öffnet ein weiterer Druck nach links die Seitenleiste mit Entdecken, Kategorien, Suche, Bibliothek und Einstellungen.\n\nVersteckt: Halte die Links-Taste gedrückt – das Menü öffnet sich sofort, egal wo du gerade bist.",
                    pad: "Über die Leiste oben (bzw. die Seitenleiste) wechselst du zwischen Entdecken, Kategorien, Suche, Bibliothek und Einstellungen. Das Symbol links blendet die Seitenleiste ein und aus.",
                    mac: "Die Seitenleiste links führt zu Entdecken, Kategorien, Suche, Bibliothek und Einstellungen. Ganz oben steht das aktive Profil."
                ),
                gesture: pick(tv: "Links-Taste gedrückt halten = Menü", pad: "Leiste oben antippen")
            ),
            HelpPage(
                symbol: "hand.tap",
                title: "Titel gedrückt halten",
                text: "Auf jedem Poster öffnet sich ein Menü mit Extras:\n• ♥ Lieben – fliesst stark in „Empfohlen für dich“ ein\n• Als gesehen markieren\n• Zu „Meine Liste“ hinzufügen\n• Ganzes Angebot bzw. ganze Liste anzeigen",
                gesture: holdTitle + " auf einem Poster"
            ),
            HelpPage(
                symbol: "square.grid.3x3.fill",
                title: "Ganze Listen & Plattformen",
                text: "Jede Reihe zeigt nur eine Auswahl. Die letzte Kachel am Ende der Reihe öffnet alles – zum Beispiel das ganze Netflix-, Disney+- oder HBO-Angebot, aufgebaut wie auf der jeweiligen Plattform.\n\nDen gleichen Weg gibt es im Menü „Titel gedrückt halten“.",
                gesture: pick(tv: "Ans Ende einer Reihe nach rechts", pad: "Reihe bis ans Ende wischen", mac: "Reihe bis ans Ende scrollen")
            ),
            HelpPage(
                symbol: "play.circle",
                title: "Weiterschauen",
                text: "Ein Titel in „Weiterschauen“ startet direkt an der gemerkten Stelle. Ist eine Folge fertig, steht automatisch die nächste dort.\n\nWillst du stattdessen zur Detailseite (Trailer, andere Folge, Streams wählen), halte den Titel gedrückt und wähle „Details anzeigen“.",
                gesture: holdTitle + " → „Details anzeigen“"
            ),
            HelpPage(
                symbol: "list.number",
                title: "Serien & Folgen",
                text: "Auf der Detailseite einer Serie blätterst du durch die Folgen – am Ende einer Staffel geht es automatisch mit der nächsten weiter.\n\nEine Folge gedrückt halten markiert sie als gesehen: nur diese Folge oder diese und alle vorherigen auf einmal.",
                gesture: holdTitle + " auf einer Folge"
            ),
            HelpPage(
                symbol: "person.2.circle",
                title: "Profile & Region",
                text: "Oben rechts wählst du das Profil. Jedes Familienmitglied hat eigene „Meine Liste“, Lieblingstitel, „Weiterschauen“, Empfehlungen und einen eigenen Suchverlauf – „Alle“ zeigt alles zusammen. Profile mit lustigem Avatar legst du unter „Wer schaut?“ an.\n\nDie Bubble links daneben wechselt die Region und damit das Angebot der Plattformen.",
                gesture: pick(tv: "Ganz nach oben, dann nach rechts", pad: "Oben rechts antippen", mac: "Oben rechts klicken")
            ),
            HelpPage(
                symbol: "line.3.horizontal.decrease.circle",
                title: "Filtern, Kategorien & Suche",
                text: "„Alle / Filme / Serien“ oben filtert die Startseite. Unter „Kategorien“ findest du Filme und Serien nach Genre – Komödie, Drama, Krieg, Thriller und mehr.\n\nDie Suche merkt sich deine letzten zehn Anfragen, damit du sie schnell wieder aufrufen kannst.",
                gesture: nil
            ),
            HelpPage(
                symbol: "play.rectangle.on.rectangle",
                title: "Wiedergabe",
                text: "Den Player wählst du in den Einstellungen. Der integrierte Player spielt MKV und MP4, merkt sich die Position und zeigt nach dem Schliessen die Detailseite. Ton- und Untertitelspur wählst du über die Symbole oben rechts – mit klarer Sprache und Tonformat.\n\n„Streams wählen“ auf der Detailseite zeigt alle gefundenen Quellen; ⚡ heisst sofort verfügbar.",
                gesture: pick(tv: "Play/Pause-Taste, Menü-Taste schliesst", pad: "Antippen blendet die Steuerung ein", mac: "Leertaste pausiert, ✕ oben links schliesst")
            )
        ]
        if !Platform.isTV {
            pages.append(HelpPage(
                symbol: "textformat.size",
                title: "Darstellungsgrösse",
                text: "Zu klein oder zu gross? Unter Einstellungen → Darstellungsgrösse passt du die Grösse der Poster an – kleiner zeigt mehr Titel pro Reihe.",
                gesture: pick(tv: "", pad: "Mit Tastatur: ⌘+ und ⌘−", mac: "⌘+ grösser, ⌘− kleiner, ⌘0 Standard")
            ))
        }
        return pages
    }
}

/// Hilfe als Ebene über der App: eine Karte pro Funktion, blätterbar.
struct HelpOverlay: View {
    @Environment(AppModel.self) private var model
    @State private var index = 0
    @FocusState private var focus: Control?
    @Namespace private var focusScope

    private enum Control: Hashable { case back, next, close }
    private let pages = HelpPage.all

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture { if !Platform.isTV { close() } }
            card
                .padding(Theme.s(40))
        }
        .tvOnExitCommand { close() }
        .tvFocusScope(focusScope)
        .onAppear {
            focus = .next
            // Beim App-Start ist die Fokus-Engine noch nicht bereit; dann nachträglich setzen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focus = .next }
        }
        .transition(.opacity)
    }

    private var card: some View {
        let page = pages[index]
        return VStack(alignment: .leading, spacing: Theme.s(26)) {
            HStack(alignment: .center, spacing: Theme.s(24)) {
                Image(systemName: page.symbol)
                    .font(.system(size: Theme.s(54), weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: Theme.s(90), height: Theme.s(90))
                    .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.s(22), style: .continuous))
                VStack(alignment: .leading, spacing: Theme.s(6)) {
                    Text("Tipp \(index + 1) von \(pages.count)")
                        .font(.system(size: Theme.s(20), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(page.title)
                        .font(.system(size: Theme.s(44), weight: .heavy))
                }
            }
            Text(page.text)
                .font(.system(size: Theme.s(26)))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if let gesture = page.gesture, !gesture.isEmpty {
                Label(gesture, systemImage: "hand.point.up.left")
                    .font(.system(size: Theme.s(22), weight: .semibold))
                    .padding(.horizontal, Theme.s(18))
                    .padding(.vertical, Theme.s(10))
                    .background(.white.opacity(0.1), in: Capsule())
            }
            Spacer(minLength: 0)
            HStack(spacing: Theme.s(10)) {
                ForEach(pages.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? Theme.accent : .white.opacity(0.25))
                        .frame(width: i == index ? Theme.s(30) : Theme.s(10), height: Theme.s(10))
                }
                Spacer()
                Button("Schliessen") { close() }
                    .buttonStyle(PillButtonStyle())
                    .focused($focus, equals: .close)
                    .keyShortcut(.cancel)
                if index > 0 {
                    Button("Zurück") { go(-1) }
                        .buttonStyle(PillButtonStyle())
                        .focused($focus, equals: .back)
                }
                Button(index == pages.count - 1 ? "Los geht’s" : "Weiter") {
                    if index == pages.count - 1 { close() } else { go(1) }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .focused($focus, equals: .next)
                .tvPrefersDefaultFocus(in: focusScope)
                .keyShortcut(.confirm)
            }
            .tvFocusSection()
        }
        .padding(Theme.s(48))
        // Feste Höhe (passend für die längste Seite), damit die Karte beim Blättern nicht springt.
        .frame(maxWidth: Theme.s(1200))
        .frame(height: Theme.s(660), alignment: .topLeading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.s(32), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.s(32), style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: Theme.s(40))
        .animation(.easeOut(duration: 0.2), value: index)
    }

    private func go(_ step: Int) {
        index = min(max(index + step, 0), pages.count - 1)
        if index == 0 { focus = .next }
    }

    private func close() {
        model.closeHelp()
    }
}
