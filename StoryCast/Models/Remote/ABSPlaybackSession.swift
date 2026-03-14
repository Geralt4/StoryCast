import Foundation
#if os(iOS)
import UIKit
#endif

// MARK: - Start Playback Session

nonisolated struct ABSPlayRequest: Encodable {
    let deviceInfo: ABSDeviceInfo
    let forceDirectPlay: Bool
    let forceTranscode: Bool
    let supportedMimeTypes: [String]
    let mediaPlayer: String

    static func makeDefault() async -> ABSPlayRequest {
        await MainActor.run {
            let deviceId: String
            if let existingId = UserDefaults.standard.string(forKey: "StoryCast.DeviceID") {
                deviceId = existingId
            } else {
                let newId = UUID().uuidString
                UserDefaults.standard.set(newId, forKey: "StoryCast.DeviceID")
                deviceId = newId
            }
            
            let deviceModel = UIDevice.current.model
            
            return ABSPlayRequest(
                deviceInfo: ABSDeviceInfo(
                    clientName: "StoryCast",
                    deviceId: deviceId,
                    clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                    manufacturer: "Apple",
                    model: deviceModel
                ),
                forceDirectPlay: true,
                forceTranscode: false,
                supportedMimeTypes: [
                    "audio/mpeg",
                    "audio/mp4",
                    "audio/m4b",
                    "audio/m4a",
                    "audio/flac",
                    "audio/ogg",
                    "audio/aac",
                    "audio/x-m4b"
                ],
                mediaPlayer: "StoryCast"
            )
        }
    }
}

nonisolated struct ABSDeviceInfo: Encodable {
    let clientName: String
    let deviceId: String
    let clientVersion: String
    let manufacturer: String
    let model: String
}

// MARK: - Playback Session Response

nonisolated struct ABSPlaybackSession: Decodable {
    let id: String
    let libraryItemId: String
    let episodeId: String?
    let mediaType: String?
    let playMethod: Int         // 0=directPlay, 1=directStream, 2=transcode, 3=local
    let startTime: Double?
    let currentTime: Double?
    let duration: Double?
    let audioTracks: [ABSAudioTrack]
    let chapters: [ABSChapter]?
    let mediaMetadata: ABSBookMetadata?
    let coverPath: String?
    let userId: String?
    let serverVersion: String?

    /// Play method constants
    enum PlayMethod: Int {
        case directPlay = 0
        case directStream = 1
        case transcode = 2
        case local = 3
    }

    var resolvedPlayMethod: PlayMethod {
        PlayMethod(rawValue: playMethod) ?? .directPlay
    }
}

// MARK: - Progress Sync

nonisolated struct ABSSessionSyncRequest: Encodable {
    let currentTime: Double
    let timeListened: Double
    let duration: Double
}

nonisolated struct ABSMediaProgress: Decodable {
    let id: String?
    let libraryItemId: String
    let episodeId: String?
    let duration: Double?
    let progress: Double?       // 0.0 – 1.0
    let currentTime: Double?
    let isFinished: Bool?
    let lastUpdate: Double?     // milliseconds epoch
    let startedAt: Double?
    let finishedAt: Double?
}

nonisolated struct ABSProgressUpdateRequest: Encodable {
    let duration: Double?
    let progress: Double?
    let currentTime: Double?
    let isFinished: Bool?
}

// MARK: - Local Progress Sync

struct ABSSyncLocalProgressRequest: Encodable {
    let localMediaProgress: [ABSLocalProgress]
}

struct ABSLocalProgress: Encodable {
    let id: String
    let libraryItemId: String
    let episodeId: String?
    let duration: Double
    let progress: Double
    let currentTime: Double
    let isFinished: Bool
    let lastUpdate: Double      // milliseconds epoch
    let startedAt: Double?
    let finishedAt: Double?
}

struct ABSSyncLocalProgressResponse: Decodable {
    let numServerProgressUpdates: Int?
    let localProgressUpdates: [ABSMediaProgress]?
}
