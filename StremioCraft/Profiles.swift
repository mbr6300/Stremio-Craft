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

    static let maxCount = 6
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
