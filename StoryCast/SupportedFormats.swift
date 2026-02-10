import Foundation
import UniformTypeIdentifiers

struct SupportedFormats {
    private static let m4bTypes: [UTType] = {
        let typeByExtension = UTType(filenameExtension: "m4b") ?? .mpeg4Audio
        let typeByIdentifier = UTType("com.apple.m4b-audio") ?? typeByExtension
        return Array(Set([typeByExtension, typeByIdentifier]))
    }()

    static let voiceBoxAudioTypes: [UTType] = [
        .mp3,
        .mpeg4Audio,
        .wav,
        .aiff
    ] + m4bTypes

    static let displayNames: [UTType: String] = [
        .mp3: "MP3 Audio",
        .mpeg4Audio: "MPEG-4 Audio (M4A/M4B)",
        .wav: "WAV Audio",
        .aiff: "AIFF Audio"
    ]

    static func isSupported(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()

        // Direct extension check as fallback
        let supportedExtensions = ["mp3", "m4a", "m4b", "wav", "aiff", "aif"]
        if supportedExtensions.contains(fileExtension) {
            return true
        }

        // UTType-based check
        guard let type = UTType(filenameExtension: fileExtension) else {
            return false
        }

        return voiceBoxAudioTypes.contains(type)
    }

    static func getDisplayName(for url: URL) -> String {
        let fileExtension = url.pathExtension.lowercased()

        switch fileExtension {
        case "mp3":
            return displayNames[.mp3] ?? "Audio File"
        case "m4a", "m4b":
            return displayNames[.mpeg4Audio] ?? "Audio File"
        case "wav":
            return displayNames[.wav] ?? "Audio File"
        case "aiff", "aif":
            return displayNames[.aiff] ?? "Audio File"
        default:
            break
        }

        guard let type = UTType(filenameExtension: fileExtension) else {
            return "Audio File"
        }

        if let displayName = displayNames[type] {
            return displayName
        }

        if type.conforms(to: .mpeg4Audio) {
            return displayNames[.mpeg4Audio] ?? "Audio File"
        }

        if type.conforms(to: .aiff) {
            return displayNames[.aiff] ?? "Audio File"
        }

        if type.conforms(to: .wav) {
            return displayNames[.wav] ?? "Audio File"
        }

        return "Audio File"
    }

    static func isM4B(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return fileExtension == "m4b"
    }
}
