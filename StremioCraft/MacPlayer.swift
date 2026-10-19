#if targetEnvironment(macCatalyst) && canImport(KSPlayer)
import KSPlayer
import SwiftUI

/// Integrierter Player auf dem Mac: KSPlayer (FFmpeg) spielt auch MKV, HEVC/HDR,
/// DTS/TrueHD sowie eingebettete Untertitel – anders als AVPlayer.
struct MacPlayerScreen: View {
    var url: URL
    var title: String
    var resume: Double
    var onProgress: (Double, Double) -> Void

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var lastSaved: Double = 0
    @State private var position: Double = 0
    @State private var duration: Double = 0

    private var options: KSOptions {
        // FFmpeg für alle Formate, damit Ton- und Untertitelspuren überall gleich funktionieren.
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = nil
        let options = KSOptions()
        if resume > 1 { options.startPlayTime = resume }
        return options
    }

    var body: some View {
        KSVideoPlayerView(coordinator: coordinator, url: url, options: options, title: title)
            .ignoresSafeArea()
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
#endif
