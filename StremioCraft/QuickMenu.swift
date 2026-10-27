import SwiftUI
import UIKit

/// Erkennt langes Drücken nach links auf der Fernbedienung – überall in der App.
/// Der Recognizer hängt am Fenster, damit er Tastendrücke unabhängig vom fokussierten Element sieht.
/// Kurze Drücke laufen unverändert an die normale Fokus-Navigation weiter.
struct LongPressLeftDetector: UIViewRepresentable {
    var action: () -> Void

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.action = action
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.action = action
    }

    final class HostView: UIView {
        var action: (() -> Void)?
        private weak var attachedWindow: UIWindow?
        private lazy var recognizer: UILongPressGestureRecognizer = {
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue)]
            recognizer.minimumPressDuration = 0.6
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            return recognizer
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, window !== attachedWindow else { return }
            attachedWindow?.removeGestureRecognizer(recognizer)
            window.addGestureRecognizer(recognizer)
            attachedWindow = window
        }

        @objc private func handle(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { action?() }
        }
    }
}

/// Eigenes Menü, das von links einfährt (tvOS erlaubt nicht, die System-Seitenleiste per Code zu öffnen).
struct QuickMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    @FocusState private var focused: AppTab?

    private let entries: [(AppTab, String, String)] = [
        (.home, "Entdecken", "sparkles.tv"),
        (.categories, "Kategorien", "square.grid.2x2"),
        (.search, "Suche", "magnifyingglass"),
        (.library, "Bibliothek", "rectangle.stack"),
        (.mediaLibrary, "Meine Mediathek", "externaldrive.connected.to.line.below"),
        (.youtube, "YouTube", "play.rectangle"),
        (.settings, "Einstellungen", "gearshape")
    ]

    var body: some View {
        HStack(spacing: Theme.s(0)) {
            VStack(alignment: .leading, spacing: Theme.s(14)) {
                Button {
                    select(.profiles)
                } label: {
                    HStack(spacing: Theme.s(18)) {
                        AvatarView(avatar: model.activeProfile?.avatar, size: Theme.s(56))
                        VStack(alignment: .leading, spacing: Theme.s(2)) {
                            Text(model.activeProfile?.name ?? "Alle")
                                .font(.system(size: Theme.s(26), weight: .bold))
                            Text("Profil wechseln")
                                .font(.system(size: Theme.s(18)))
                                .opacity(0.6)
                        }
                    }
                }
                .buttonStyle(MenuEntryStyle(isCurrent: model.selectedTab == .profiles))
                .focused($focused, equals: .profiles)
                .padding(.bottom, Theme.s(16))

                ForEach(entries, id: \.0) { tab, title, symbol in
                    Button {
                        select(tab)
                    } label: {
                        Label(title, systemImage: symbol)
                            .font(.system(size: Theme.s(28), weight: .semibold))
                    }
                    .buttonStyle(MenuEntryStyle(isCurrent: model.selectedTab == tab))
                    .focused($focused, equals: tab)
                }
                Button {
                    isPresented = false
                    model.showHelp = true
                } label: {
                    Label("Hilfe & Tipps", systemImage: "questionmark.circle")
                        .font(.system(size: Theme.s(28), weight: .semibold))
                }
                .buttonStyle(MenuEntryStyle(isCurrent: false))
                .padding(.top, Theme.s(16))
                Spacer()
            }
            .padding(.horizontal, Theme.s(36))
            .padding(.vertical, Theme.s(60))
            .frame(width: Theme.s(480), alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .background(Theme.background.opacity(0.6))
            .tvFocusSection()

            // Rechts abdunkeln; ein Fokuswechsel dorthin gibt es nicht, das Menü bleibt bis Auswahl/Zurück offen.
            Color.black.opacity(0.45)
        }
        .ignoresSafeArea()
        .tvOnExitCommand { isPresented = false }
        .onAppear { focused = model.selectedTab }
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private func select(_ tab: AppTab) {
        model.selectedTab = tab
        isPresented = false
    }

    private struct MenuEntryStyle: ButtonStyle {
        var isCurrent: Bool

        func makeBody(configuration: Configuration) -> some View {
            Entry(configuration: configuration, isCurrent: isCurrent)
        }

        private struct Entry: View {
            let configuration: ButtonStyleConfiguration
            let isCurrent: Bool
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                configuration.label
                    .foregroundStyle(isFocused ? Color.black : .white.opacity(isCurrent ? 1 : 0.75))
                    .padding(.horizontal, Theme.s(22))
                    .padding(.vertical, Theme.s(14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        isFocused ? Color.white : (isCurrent ? Color.white.opacity(0.12) : .clear),
                        in: RoundedRectangle(cornerRadius: Theme.s(16), style: .continuous)
                    )
                    .scaleEffect(isFocused ? 1.04 : 1)
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
    }
}
