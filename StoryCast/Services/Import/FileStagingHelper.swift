import Foundation

enum FileStagingHelper {
    static func makeStagingURL(for sourceURL: URL) throws -> URL {
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoryCastImportStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let fileExtension = sourceURL.pathExtension
        let fileName = UUID().uuidString + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        return stagingDirectory.appendingPathComponent(fileName)
    }

    static func copyFileToStagingURL(at sourceURL: URL, destinationURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var hasResumed = false

            coordinator.coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
                do {
                    let fileManager = FileManager.default
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.copyItem(at: coordinatedURL, to: destinationURL)
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(returning: ())
                    }
                } catch {
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(throwing: error)
                    }
                }
            }

            if let coordinationError, !hasResumed {
                hasResumed = true
                continuation.resume(throwing: coordinationError)
            }
        }
    }
}