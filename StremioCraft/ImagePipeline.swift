import ImageIO
import SwiftUI
import UIKit

/// Lädt Bilder einmal, dekodiert sie im Hintergrund auf Zielgrösse herunter und hält sie im Speicher.
/// `AsyncImage` cached nicht und dekodiert TMDB-Poster in voller Grösse auf dem Main Thread – das war
/// die Hauptursache fürs Ruckeln in den Regalen.
actor ImagePipeline {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private var running: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    init() {
        memory.totalCostLimit = 160 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
    }

    nonisolated func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        memory.object(forKey: Self.key(url, maxPixel))
    }

    func image(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = Self.key(url, maxPixel)
        if let hit = memory.object(forKey: key) { return hit }
        if let task = running[key as String] { return await task.value }
        let session = session
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        running[key as String] = task
        let result = await task.value
        running[key as String] = nil
        if let result {
            let cost = Int(result.size.width * result.size.height * result.scale * result.scale * 4)
            memory.setObject(result, forKey: key, cost: cost)
        }
        return result
    }

    private static func key(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        "\(Int(maxPixel))|\(url.absoluteString)" as NSString
    }

    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Ersetzt `AsyncImage`: zeigt sofort einen Platzhalter und blendet das gecachte Bild weich ein.
struct RemoteImage: View {
    var url: URL?
    /// Längste Kante in Punkten; wird mit der Bildschirmskala in Pixel umgerechnet.
    var maxPoints: CGFloat
    var placeholderSymbol = "film"

    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(Theme.surface)
                    .overlay {
                        Image(systemName: placeholderSymbol)
                            .font(.system(size: 38))
                            .foregroundStyle(.white.opacity(0.25))
                    }
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            let pixels = maxPoints * scale
            if let hit = ImagePipeline.shared.cached(url, maxPixel: pixels) {
                image = hit
                return
            }
            let loaded = await ImagePipeline.shared.image(url, maxPixel: pixels)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}
