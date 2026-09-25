import Foundation
@testable import StoryCast

/// Responses recorded from a real Audiobookshelf server (v2.36.1) with three test
/// books: "Multi MP3 Book" (3 files: 95 s, 61 s, 127 s), "Multi M4A Book"
/// (3 files: 70 s, 45 s, 100 s) and "Single M4B Book" (one 150 s file).
nonisolated enum ABSFixtures {
    private final class BundleToken {}

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw NSError(domain: "ABSFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing fixture \(name).json"])
        }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(name))
    }

    static func playSession(_ name: String) throws -> ABSPlaybackSession {
        try decode(ABSPlaybackSession.self, from: name)
    }

    static func libraryItem(_ name: String) throws -> ABSLibraryItem {
        try decode(ABSLibraryItem.self, from: name)
    }
}
