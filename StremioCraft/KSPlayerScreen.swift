#if canImport(KSPlayer)
import KSPlayer
import SwiftUI

/// Integrierter Player auf Mac, iPad und Apple TV: KSPlayer (FFmpeg) spielt auch MKV, HEVC/HDR,
/// DTS/TrueHD sowie eingebettete Untertitel – anders als AVPlayer.
struct KSPlayerScreen: View {
    var url: URL
    var title: String
    var resume: Double
    var audioLanguage: String
    var subtitleLanguage: String
    /// Bereitgelegte nächste Folge, z. B. „S01E03 · Pilot“; `nil` = keine.
    var nextLabel: String?
    var onNext: () -> Void = {}
    var onProgress: (Double, Double) -> Void

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var lastSaved: Double = 0
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var nextDismissed = false
    @State private var countdown = 10

    /// Karte „Nächste Folge“ in den letzten 30 Sekunden (Abspann), sofern bereitgelegt.
    private var showsNext: Bool {
        nextLabel != nil && !nextDismissed && duration > 60 && duration - position <= 30
    }

    private var options: KSOptions {
        // FFmpeg für alle Formate, damit Ton- und Untertitelspuren überall gleich funktionieren.
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = nil
        let options = TrackOptions(audio: audioLanguage, subtitle: subtitleLanguage)
        options.autoSelectEmbedSubtitle = subtitleLanguage != PlaybackLanguage.off
        if resume > 1 { options.startPlayTime = resume }
        return options
    }

    var body: some View {
        KSVideoPlayerView(coordinator: coordinator, url: url, options: options, title: title)
            // Mac: unter der Titelleiste beginnen, damit der Schliessen-Knopf des Players
            // nicht unter den Fensterknöpfen (rot/gelb/grün) liegt.
            .padding(.top, Platform.isMac ? 30 : 0)
            .background(Color.black.ignoresSafeArea())
            .overlay(alignment: .bottomTrailing) {
                if showsNext, let nextLabel {
                    UpNextCard(label: nextLabel, countdown: countdown, onPlay: onNext) { nextDismissed = true }
                        .padding(Theme.s(60))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.3), value: showsNext)
            // Countdown ab dem Einblenden; bei 0 automatisch weiter.
            .task(id: showsNext) {
                guard showsNext else { return }
                countdown = 10
                while countdown > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, showsNext else { return }
                    countdown -= 1
                }
                onNext()
            }
            .onAppear {
                coordinator.onPlay = { current, total in
                    position = current
                    duration = total
                    // Seltener speichern: jeder Speichervorgang aktualisiert „Weiterschauen“.
                    if abs(current - lastSaved) >= 20 {
                        lastSaved = current
                        onProgress(current, total)
                    }
                }
            }
            .onDisappear {
                if position > 0 { onProgress(position, duration) }
                coordinator.resetPlayer()
            }
    }
}

/// „Nächste Folge in 10 s“ mit Sofort-Start und Abbrechen.
private struct UpNextCard: View {
    var label: String
    var countdown: Int
    var onPlay: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s(14)) {
            Text("Nächste Folge in \(countdown) s")
                .font(.system(size: Theme.s(20), weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
            Text(label)
                .font(.system(size: Theme.s(26), weight: .bold))
                .lineLimit(1)
            HStack(spacing: Theme.s(16)) {
                Button(action: onPlay) {
                    Label("Jetzt abspielen", systemImage: "play.fill")
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                Button("Abbrechen", action: onCancel)
                    .buttonStyle(PillButtonStyle())
            }
        }
        .padding(Theme.s(28))
        .frame(maxWidth: Theme.s(620), alignment: .leading)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: Theme.s(24)))
        .tvFocusSection()
    }
}

/// Startet mit Ton und Untertiteln in der Sprache des Profils, sofern vorhanden; sonst die
/// Standardwahl der Datei. Im Player-Menü lässt sich beides weiterhin umstellen.
private final class TrackOptions: KSOptions {
    private let audio: String
    private let subtitle: String

    init(audio: String, subtitle: String) {
        self.audio = audio
        self.subtitle = subtitle
        super.init()
    }

    override func wantedAudio(tracks: [MediaPlayerTrack]) -> Int? {
        audio == PlaybackLanguage.original ? nil : preferredAudioIndex(tracks, language: audio)
    }

    override func wantedSubtitle(infos: [any SubtitleInfo]) -> (any SubtitleInfo)? {
        subtitle == PlaybackLanguage.off ? nil : preferredSubtitle(infos, language: subtitle)
    }
}
#endif
