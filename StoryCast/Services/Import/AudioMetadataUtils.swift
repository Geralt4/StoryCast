import Foundation
import AVFoundation
import os

enum AudioMetadataUtils {
    static func author(from metadata: [AVMetadataItem]) async -> String? {
        let candidateKeys: Set<String> = ["author", "artist", "albumartist", "creator"]
        for item in metadata {
            guard let key = item.commonKey?.rawValue.lowercased(), candidateKeys.contains(key) else { continue }
            if let value = try? await item.load(.stringValue) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let value = try? await item.load(.value), let stringValue = value as? String {
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    static func fileSizeInBytes(at url: URL) -> Int64? {
        if let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = resourceValues.fileSize {
            return Int64(fileSize)
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let sizeNumber = attributes[.size] as? NSNumber {
            return sizeNumber.int64Value
        }
        return nil
    }
}