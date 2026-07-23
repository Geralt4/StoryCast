import Foundation
import os
import UIKit

/// In-memory cache for cover art images, keyed by the bare filename stored on
/// `Book.coverArtFileName`. Reads are first satisfied from the `NSCache`, then
/// from a verified local file. Cloud materialization is coordinated separately
/// before this cache is asked to load an image.
actor CoverArtCache {
    static let shared = CoverArtCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 100
        cache.totalCostLimit = 50 * 1024 * 1024
    }

    /// Returns the cover art image for a local verified URL. Returns nil if no
    /// image can be loaded (file missing or unsupported format).
    func image(for fileName: String, url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: fileName as NSString) {
            return cached
        }

        // Offload the synchronous file read from the actor's serial executor so
        // concurrent callers don't serialize behind it.
        let image = await Task.detached(priority: .utility) {
            UIImage(contentsOfFile: url.path)
        }.value
        guard let image else {
            return nil
        }
        let cost = Int((image.size.width * image.size.height) * 4 * image.scale * image.scale)
        cache.setObject(image, forKey: fileName as NSString, cost: cost)
        return image
    }
}
