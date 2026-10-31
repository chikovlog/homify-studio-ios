import AVFoundation
import UIKit
import HomifyCore

/// Small, cached timeline thumbnails. Generation is asynchronous and uses a
/// generous time tolerance so the decoder can return the nearest keyframe
/// instead of decoding a whole GOP. NSCache evicts automatically under memory
/// pressure.
@MainActor
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSString, UIImage>()
    private var generators: [URL: AVAssetImageGenerator] = [:]
    private var inFlight: [NSString: Task<UIImage?, Never>] = [:]
    /// Thumbnails are quantised to this step so zooming reuses cached frames.
    static let quantum: Double = 0.25

    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    private func generator(for url: URL) -> AVAssetImageGenerator {
        if let g = generators[url] { return g }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 220, height: 220)
        let tol = CMTime(seconds: ThumbnailProvider.quantum, preferredTimescale: 600)
        g.requestedTimeToleranceBefore = tol
        g.requestedTimeToleranceAfter = tol
        generators[url] = g
        return g
    }

    func cached(url: URL, seconds: Double) -> UIImage? {
        cache.object(forKey: key(url, seconds))
    }

    func image(url: URL, seconds: Double) async -> UIImage? {
        let k = key(url, seconds)
        if let img = cache.object(forKey: k) { return img }
        if let t = inFlight[k] { return await t.value }
        let q = (max(0, seconds) / ThumbnailProvider.quantum).rounded() * ThumbnailProvider.quantum
        let gen = generator(for: url)
        let task = Task<UIImage?, Never> {
            guard let result = try? await gen.image(at: CMTime(seconds: q, preferredTimescale: 600)) else { return nil }
            return UIImage(cgImage: result.image)
        }
        inFlight[k] = task
        let img = await task.value
        inFlight[k] = nil
        if let img {
            let cost = Int(img.size.width * img.size.height * 4)
            cache.setObject(img, forKey: k, cost: cost)
        }
        return img
    }

    func purge() {
        cache.removeAllObjects()
        generators.removeAll()
    }

    private func key(_ url: URL, _ seconds: Double) -> NSString {
        let q = Int((max(0, seconds) / ThumbnailProvider.quantum).rounded())
        return "\(url.lastPathComponent)#\(q)" as NSString
    }
}
