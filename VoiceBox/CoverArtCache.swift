import Foundation
#if os(iOS)
import UIKit
#endif

actor CoverArtCache {
    static let shared = CoverArtCache()

    #if os(iOS)
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 100
        cache.totalCostLimit = 50 * 1024 * 1024
    }

    func image(for fileName: String, url: URL) -> UIImage? {
        if let cached = cache.object(forKey: fileName as NSString) {
            return cached
        }

        let image = UIImage(contentsOfFile: url.path)
        if let image {
            let cost = Int((image.size.width * image.size.height) * 4 * image.scale * image.scale)
            cache.setObject(image, forKey: fileName as NSString, cost: cost)
        }

        return image
    }
    #else
    private init() {}
    #endif
}
