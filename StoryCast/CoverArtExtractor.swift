import AVFoundation
import Foundation
import os

struct CoverArtExtractor {
    func extractCoverArt(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)

        do {
            let commonMetadata = try await asset.load(.commonMetadata)
            if let data = await artworkData(in: commonMetadata) {
                return data
            }

            let fullMetadata = try await asset.load(.metadata)
            return await artworkData(in: fullMetadata)
        } catch {
            AppLogger.metadata.warning("Failed to extract cover art: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    private func artworkData(in metadata: [AVMetadataItem]) async -> Data? {
        let commonArtworkItems = AVMetadataItem.metadataItems(
            from: metadata,
            withKey: AVMetadataKey.commonKeyArtwork,
            keySpace: .common
        )

        if let item = commonArtworkItems.first {
            do {
                if let data = try await item.load(.dataValue) {
                    return data
                }
            } catch {
                AppLogger.metadata.warning("Failed to load common artwork data: \(error.localizedDescription, privacy: .private)")
            }
        }

        let id3ArtworkItems = AVMetadataItem.metadataItems(
            from: metadata,
            withKey: AVMetadataKey.id3MetadataKeyAttachedPicture,
            keySpace: .id3
        )

        if let item = id3ArtworkItems.first {
            do {
                if let data = try await item.load(.dataValue) {
                    return data
                }
            } catch {
                AppLogger.metadata.warning("Failed to load ID3 artwork data: \(error.localizedDescription, privacy: .private)")
            }
        }

        return nil
    }
}
