import SwiftUI

struct Avatar: Codable, Hashable {
    var emoji: String
    var hue: Double

    /// Lustige Motive; Emojis brauchen keine Bilddateien und sehen auf dem Fernseher scharf aus.
    static let all: [Avatar] = [
        Avatar(emoji: "🦊", hue: 0.07), Avatar(emoji: "🐼", hue: 0.55), Avatar(emoji: "🦄", hue: 0.85),
        Avatar(emoji: "🐸", hue: 0.33), Avatar(emoji: "🐙", hue: 0.92), Avatar(emoji: "🦖", hue: 0.40),
        Avatar(emoji: "🐯", hue: 0.10), Avatar(emoji: "🐵", hue: 0.04), Avatar(emoji: "🐧", hue: 0.60),
        Avatar(emoji: "🦁", hue: 0.12), Avatar(emoji: "👽", hue: 0.30), Avatar(emoji: "🤖", hue: 0.58),
        Avatar(emoji: "🐨", hue: 0.65), Avatar(emoji: "🐶", hue: 0.05), Avatar(emoji: "🐱", hue: 0.15),
        Avatar(emoji: "🍕", hue: 0.02), Avatar(emoji: "🚀", hue: 0.70), Avatar(emoji: "🐝", hue: 0.14),
        Avatar(emoji: "🦉", hue: 0.75), Avatar(emoji: "🐳", hue: 0.56), Avatar(emoji: "🦩", hue: 0.95),
        Avatar(emoji: "🐢", hue: 0.36), Avatar(emoji: "🦥", hue: 0.09), Avatar(emoji: "🎃", hue: 0.06)
    ]
}

struct Profile: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var avatar: Avatar
    /// Vorlieben für die Empfehlungen; fehlt bei älteren Profilen.
    var preferences: TastePreferences?
    /// Startwahl im integrierten Player (ISO 639-1); `nil` = Englisch. Ton "original" = Spur der Datei,
    /// Untertitel "off" = keine.
    var audioLanguage: String?
    var subtitleLanguage: String?

    static let maxCount = 6
}

/// Sprachwahl für Ton und Untertitel im integrierten Player.
enum PlaybackLanguage {
    static let defaultCode = "en"
    static let original = "original"
    static let off = "off"
    static let choices: [(code: String, name: String)] = [
        ("de", "Deutsch"), ("en", "Englisch"), ("fr", "Französisch"), ("es", "Spanisch"), ("it", "Italienisch")
    ]
}

struct AvatarView: View {
    /// `nil` zeigt das „Alle“-Symbol (Familie).
    var avatar: Avatar?
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.65, brightness: 0.95),
                        Color(hue: (hue + 0.05).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            if let avatar {
                Text(avatar.emoji)
                    .font(.system(size: size * 0.55))
            } else {
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    private var hue: Double { avatar?.hue ?? 0.6 }
}

/// „Wer schaut?“ – Profil wählen, anlegen und verwalten.
struct ProfilesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var editTarget: Profile?

    var body: some View {
        VStack(spacing: Theme.s(60)) {
            Spacer(minLength: 0)
            Text(editing ? "Profile verwalten" : "Wer schaut?")
                .font(.system(size: Theme.s(60), weight: .heavy))
            // Passt die Reihe nicht (iPad hochkant, viele Profile), wird sie seitlich scrollbar.
            ViewThatFits(in: .horizontal) {
                tiles
                ScrollView(.horizontal, showsIndicators: false) {
                    tiles
                        .padding(.horizontal, Theme.pagePadding)
                        .padding(.vertical, Theme.s(30))
                }
            }
            Text(subtitle)
                .font(.system(size: Theme.s(22)))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: Theme.s(1100))
            if !model.profiles.isEmpty {
                Button(editing ? "Fertig" : "Profile verwalten") { editing.toggle() }
                    .buttonStyle(PillButtonStyle(selected: editing))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .navigationDestination(item: $editTarget) { profile in
            ProfileEditView(profile: profile, isNew: !model.profiles.contains { $0.id == profile.id })
        }
    }

    private var tiles: some View {
        HStack(alignment: .top, spacing: Theme.s(56)) {
            if !editing {
                ProfileTile(name: "Alle", avatar: nil, isActive: model.activeProfileID == nil, editing: false) {
                    choose(nil)
                }
            }
            ForEach(model.profiles) { profile in
                ProfileTile(name: profile.name, avatar: profile.avatar, isActive: model.activeProfileID == profile.id, editing: editing) {
                    if editing { editTarget = profile } else { choose(profile.id) }
                }
                .contextMenu {
                    Button("Bearbeiten") { editTarget = profile }
                    Button("Löschen", role: .destructive) { model.deleteProfile(profile) }
                }
            }
            if model.profiles.count < Profile.maxCount {
                AddProfileTile {
                    editTarget = Profile(name: "", avatar: Avatar.all[model.profiles.count % Avatar.all.count])
                }
            }
        }
        .tvFocusSection()
    }

    private var subtitle: String {
        if editing { return "Profil auswählen, um Name und Avatar zu ändern." }
        return "Jedes Profil hat eigene Favoriten, „Weiterschauen“, Empfehlungen und einen eigenen Suchverlauf. „Alle“ zeigt alles zusammen."
    }

    private func choose(_ id: String?) {
        model.switchProfile(to: id)
        model.selectedTab = .home
    }
}

private struct ProfileTile: View {
    var name: String
    var avatar: Avatar?
    var isActive: Bool
    var editing: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            TileLabel(name: name, avatar: avatar, isActive: isActive, editing: editing)
        }
        .buttonStyle(PosterButtonStyle())
    }

    private struct TileLabel: View {
        var name: String
        var avatar: Avatar?
        var isActive: Bool
        var editing: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            VStack(spacing: Theme.s(20)) {
                AvatarView(avatar: avatar, size: Theme.s(200))
                    .overlay {
                        Circle().strokeBorder(.white.opacity(isFocused ? 1 : (isActive ? 0.5 : 0)), lineWidth: isFocused ? 6 : 4)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if editing {
                            badge("pencil", color: .white, foreground: .black)
                        } else if isActive {
                            badge("checkmark", color: Theme.accent, foreground: .white)
                        }
                    }
                    .scaleEffect(isFocused ? 1.1 : 1)
                Text(name)
                    .font(.system(size: Theme.s(28), weight: isFocused || isActive ? .bold : .medium))
                    .foregroundStyle(isFocused ? .white : .white.opacity(0.7))
                    .lineLimit(1)
                    .frame(width: Theme.s(220))
            }
            .animation(.easeOut(duration: 0.18), value: isFocused)
        }

        private func badge(_ symbol: String, color: Color, foreground: Color) -> some View {
            Image(systemName: symbol)
                .font(.system(size: Theme.s(26), weight: .heavy))
                .foregroundStyle(foreground)
                .frame(width: Theme.s(54), height: Theme.s(54))
                .background(color, in: Circle())
        }
    }
}

private struct AddProfileTile: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            AddLabel()
        }
        .buttonStyle(PosterButtonStyle())
    }

    private struct AddLabel: View {
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            VStack(spacing: Theme.s(20)) {
                Image(systemName: "plus")
                    .font(.system(size: Theme.s(70), weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white.opacity(0.7))
                    .frame(width: Theme.s(200), height: Theme.s(200))
                    .background(isFocused ? Color.white : Theme.surface, in: Circle())
                    .scaleEffect(isFocused ? 1.1 : 1)
                Text("Profil hinzufügen")
                    .font(.system(size: Theme.s(28), weight: .medium))
                    .foregroundStyle(.white.opacity(isFocused ? 1 : 0.7))
                    .frame(width: Theme.s(240))
            }
            .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}

/// Name und Avatar eines Profils bearbeiten oder ein neues anlegen.
struct ProfileEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: Profile
    var isNew: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s(40)) {
                HStack(spacing: Theme.s(40)) {
                    AvatarView(avatar: profile.avatar, size: Theme.s(180))
                    VStack(alignment: .leading, spacing: Theme.s(16)) {
                        Text(isNew ? "Neues Profil" : "Profil bearbeiten")
                            .font(.system(size: Theme.s(52), weight: .heavy))
                        TextField("Name", text: $profile.name)
                            .frame(width: Theme.s(700))
                    }
                }
                .tvFocusSection()
                Text("Avatar wählen")
                    .font(.system(size: Theme.s(30), weight: .bold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.s(130)), spacing: Theme.s(30))], alignment: .leading, spacing: Theme.s(30)) {
                    ForEach(Avatar.all, id: \.self) { avatar in
                        Button {
                            profile.avatar = avatar
                        } label: {
                            AvatarChoice(avatar: avatar, selected: profile.avatar == avatar)
                        }
                        .buttonStyle(PosterButtonStyle())
                    }
                }
                .tvFocusSection()
                LanguageChoices(
                    title: "Ton im integrierten Player",
                    extra: (PlaybackLanguage.original, "Original"),
                    selection: $profile.audioLanguage
                )
                LanguageChoices(
                    title: "Untertitel",
                    extra: (PlaybackLanguage.off, "Aus"),
                    selection: $profile.subtitleLanguage
                )
                TastePreferencesEditor(preferences: Binding(
                    get: { profile.preferences ?? TastePreferences() },
                    set: { profile.preferences = $0 }
                ))
                HStack(spacing: Theme.s(24)) {
                    Button(isNew ? "Profil anlegen" : "Sichern") {
                        let saved = model.saveProfile(profile)
                        if isNew { model.switchProfile(to: saved.id) }
                        dismiss()
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    if !isNew {
                        Button("Profil löschen") {
                            model.deleteProfile(profile)
                            dismiss()
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }
                .tvFocusSection()
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, Theme.s(60))
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
    }

    private struct AvatarChoice: View {
        var avatar: Avatar
        var selected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            AvatarView(avatar: avatar, size: Theme.s(120))
                .overlay {
                    Circle().strokeBorder(.white.opacity(isFocused ? 1 : (selected ? 0.8 : 0)), lineWidth: 5)
                }
                .scaleEffect(isFocused ? 1.12 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// Startsprache für Ton bzw. Untertitel; `nil` steht für Englisch (bisheriges Verhalten).
private struct LanguageChoices: View {
    var title: String
    var extra: (code: String, name: String)
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s(14)) {
            Text(title)
                .font(.system(size: Theme.s(30), weight: .bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.s(230)), spacing: Theme.s(16))], alignment: .leading, spacing: Theme.s(16)) {
                ForEach(PlaybackLanguage.choices + [extra], id: \.code) { choice in
                    let current = selection ?? PlaybackLanguage.defaultCode
                    Button {
                        selection = choice.code == PlaybackLanguage.defaultCode ? nil : choice.code
                    } label: {
                        Text(choice.name).lineLimit(1)
                    }
                    .buttonStyle(PillButtonStyle(selected: current == choice.code))
                }
            }
        }
        .tvFocusSection()
    }
}

/// Vorlieben für „Empfohlen für dich“. Genres: einmal wählen = mag ich, nochmals = mag ich nicht.
struct TastePreferencesEditor: View {
    @Binding var preferences: TastePreferences
    @State private var peopleText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s(30)) {
            Text("Vorlieben für Empfehlungen")
                .font(.system(size: Theme.s(30), weight: .bold))
            Text("Alles freiwillig. Genres: einmal wählen = mag ich, nochmals = lieber nicht.")
                .font(.system(size: Theme.s(20)))
                .foregroundStyle(.white.opacity(0.55))

            section("Genres") {
                ForEach(TastePreferences.genres, id: \.id) { genre in
                    let liked = preferences.likedGenres.contains(genre.id)
                    let disliked = preferences.dislikedGenres.contains(genre.id)
                    Button { cycle(genre.id) } label: {
                        Label(genre.name, systemImage: liked ? "hand.thumbsup.fill" : (disliked ? "hand.thumbsdown.fill" : "circle"))
                            .opacity(disliked ? 0.6 : 1)
                    }
                    .buttonStyle(PillButtonStyle(selected: liked))
                }
            }
            section("Jahrzehnte") {
                ForEach(TastePreferences.decadeChoices, id: \.self) { decade in
                    let label = decade == 1960 ? "60er und älter" : (decade < 2000 ? "\(decade % 100)er" : "\(decade)er")
                    toggle(label, isOn: preferences.decades.contains(decade)) {
                        preferences.decades.toggle(decade)
                        // „und älter“: frühere Jahrzehnte mitnehmen.
                        if decade == 1960 {
                            for older in [1920, 1930, 1940, 1950] { preferences.decades.set(older, on: preferences.decades.contains(1960)) }
                        }
                    }
                }
            }
            section("Sprachen ohne Untertitel") {
                ForEach(TastePreferences.languageChoices, id: \.code) { language in
                    toggle(language.name, isOn: preferences.languages.contains(language.code)) {
                        preferences.languages.toggle(language.code)
                    }
                }
            }
            section("Höchstens so lang") {
                ForEach(TastePreferences.runtimeChoices, id: \.self) { minutes in
                    toggle(minutes.map { "\($0) Min." } ?? "Egal", isOn: preferences.maxRuntime == minutes) {
                        preferences.maxRuntime = minutes
                    }
                }
            }
            section("IMDb-Bewertung mindestens") {
                ForEach(TastePreferences.ratingChoices, id: \.self) { rating in
                    toggle(rating.map { String(format: "%.1f", $0) } ?? "Egal", isOn: preferences.minRating == rating) {
                        preferences.minRating = rating
                    }
                }
            }
            section("Altersfreigabe höchstens") {
                ForEach(TastePreferences.ageChoices, id: \.self) { age in
                    toggle(age.map { "FSK \($0)" } ?? "Alle", isOn: preferences.maxAge == age) {
                        preferences.maxAge = age
                    }
                }
            }
            VStack(alignment: .leading, spacing: Theme.s(14)) {
                Text("Lieblingsschauspieler und -regie")
                    .font(.system(size: Theme.s(24), weight: .semibold))
                TextField("z. B. Tom Hanks, Christopher Nolan", text: $peopleText)
                    .frame(maxWidth: Theme.s(900))
                    .onSubmit(applyPeople)
                    .onChange(of: peopleText) { applyPeople() }
            }
            .tvFocusSection()
        }
        .onAppear { peopleText = preferences.people.joined(separator: ", ") }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.s(14)) {
            Text(title)
                .font(.system(size: Theme.s(24), weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.s(230)), spacing: Theme.s(16))], alignment: .leading, spacing: Theme.s(16)) {
                content()
            }
        }
        .tvFocusSection()
    }

    private func toggle(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).lineLimit(1)
        }
        .buttonStyle(PillButtonStyle(selected: isOn))
    }

    /// Neutral → mag ich → mag ich nicht → neutral.
    private func cycle(_ genre: Int) {
        if preferences.likedGenres.contains(genre) {
            preferences.likedGenres.removeAll { $0 == genre }
            preferences.dislikedGenres.append(genre)
        } else if preferences.dislikedGenres.contains(genre) {
            preferences.dislikedGenres.removeAll { $0 == genre }
        } else {
            preferences.likedGenres.append(genre)
        }
    }

    private func applyPeople() {
        preferences.people = peopleText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

private extension Array where Element: Equatable {
    mutating func toggle(_ value: Element) {
        set(value, on: !contains(value))
    }

    mutating func set(_ value: Element, on: Bool) {
        removeAll { $0 == value }
        if on { append(value) }
    }
}

/// Aktives Profil oben rechts (Name links vom Avatar); führt zu „Wer schaut?“.
struct ActiveProfileBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.selectedTab = .profiles
        } label: {
            // Gleiche Pill-Höhe wie die Regionen-Bubble daneben.
            HStack(spacing: Theme.s(12)) {
                Text(model.activeProfile?.name ?? "Alle")
                AvatarView(avatar: model.activeProfile?.avatar, size: Theme.pillContentHeight)
            }
            .frame(height: Theme.pillContentHeight)
        }
        .buttonStyle(PillButtonStyle())
    }
}
