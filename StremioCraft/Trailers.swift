import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Trailer-Knopf der Detailseite. Ein Trailer → Knopf, mehrere → Menü zur Auswahl.
/// Abgespielt wird in der YouTube-App; ohne sie erscheint ein QR-Code fürs Handy.
struct TrailerButton: View {
    var trailers: [Trailer]
    @State private var qrTrailer: Trailer?

    var body: some View {
        Group {
            if trailers.count > 1 {
                Menu {
                    ForEach(trailers) { trailer in
                        Button(label(for: trailer)) { open(trailer) }
                    }
                } label: {
                    Label("Trailer", systemImage: "play.rectangle")
                }
            } else if let trailer = trailers.first {
                Button { open(trailer) } label: {
                    Label("Trailer", systemImage: "play.rectangle")
                }
            }
        }
        .buttonStyle(PillButtonStyle())
        .sheet(item: $qrTrailer) { trailer in
            TrailerQRView(trailer: trailer)
        }
    }

    private func label(for trailer: Trailer) -> String {
        let language = trailer.language == "de" ? "DE" : trailer.language.uppercased()
        return language.isEmpty ? trailer.name : "\(trailer.name) · \(language)"
    }

    /// Die YouTube-App auf tvOS dokumentiert kein URL-Schema; daher die üblichen Formate
    /// nacheinander probieren und erst dann auf den QR-Code ausweichen.
    private func open(_ trailer: Trailer) {
        let candidates = [
            "youtube://www.youtube.com/watch?v=\(trailer.key)",
            "youtube://watch?v=\(trailer.key)",
            "vnd.youtube://\(trailer.key)"
        ].compactMap(URL.init(string:))
        attempt(candidates, trailer: trailer)
    }

    private func attempt(_ urls: [URL], trailer: Trailer) {
        guard let url = urls.first else {
            qrTrailer = trailer
            return
        }
        UIApplication.shared.open(url, options: [:]) { success in
            Task { @MainActor in
                if !success { attempt(Array(urls.dropFirst()), trailer: trailer) }
            }
        }
    }
}

/// Fallback ohne YouTube-App: QR-Code mit dem Trailer-Link zum Scannen mit dem Handy.
private struct TrailerQRView: View {
    var trailer: Trailer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 36) {
            Text(trailer.name)
                .font(.system(size: 40, weight: .heavy))
                .multilineTextAlignment(.center)
            if let image = Self.qrCode(trailer.watchURL.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 420, height: 420)
                    .padding(24)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
            }
            Text("Die YouTube-App ist nicht installiert. Code mit dem Handy scannen, um den Trailer dort anzusehen.")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            Button("Schliessen") { dismiss() }
                .buttonStyle(PillButtonStyle(prominent: true))
        }
        .padding(60)
    }

    private static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
