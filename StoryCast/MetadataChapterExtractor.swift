import AVFoundation
import Foundation
import os

class MetadataChapterExtractor {
    nonisolated init() {}
    nonisolated func extractChapters(from url: URL) async throws -> [DetectedChapter] {
        let asset = AVURLAsset(url: url)
        
        // Try to extract from AVFoundation chapter metadata (M4B, M4A)
        let avChapters = try await extractAVChapters(from: asset)
        if !avChapters.isEmpty {
            return avChapters
        }
        
        // Try to extract from ID3 tags (MP3)
        let id3Chapters = try await extractID3Chapters(from: asset)
        if !id3Chapters.isEmpty {
            return id3Chapters
        }
        
        return []
    }
    
    private nonisolated func extractAVChapters(from asset: AVURLAsset) async throws -> [DetectedChapter] {
        // Load chapter metadata groups using modern async API
        // Try available locales first, fall back to current locale
        let availableLocales = try await asset.load(.availableChapterLocales)
        let preferredLocale = availableLocales.first ?? Locale.current
        let metadataGroups = try await asset.loadChapterMetadataGroups(
            withTitleLocale: preferredLocale,
            containingItemsWithCommonKeys: []
        )

        var chapters: [DetectedChapter] = []

        for group in metadataGroups {
            let items = group.items

            // Get chapter title using modern load API
            var title = "Chapter \(chapters.count + 1)"
            if let titleItem = items.first(where: { item in
                item.commonKey?.rawValue == "title" ||
                item.key as? String == "title" ||
                item.commonKey == .commonKeyTitle ||
                item.key as? String == AVMetadataKey.id3MetadataKeyTitleDescription.rawValue
            }) {
                // Use modern async load API instead of deprecated stringValue
                do {
                    if let loadedTitle = try await titleItem.load(.value) as? String {
                        title = loadedTitle
                    }
                } catch {
                    AppLogger.metadata.warning("Failed to load chapter title: \(error.localizedDescription, privacy: .private)")
                }
            }

            // Get chapter start time from the group's time range
            let startTime = group.timeRange.start.seconds
            let endTime = startTime + group.timeRange.duration.seconds

            let chapter = DetectedChapter(
                title: title,
                startTime: startTime,
                endTime: endTime,
                source: .embedded
            )

            chapters.append(chapter)
        }

        return chapters
    }
    
    private nonisolated func extractID3Chapters(from asset: AVURLAsset) async throws -> [DetectedChapter] {
        let metadata = try await asset.load(.metadata)
        let chapterKey = AVMetadataKey(rawValue: "CHAP")
        let chapterItems = AVMetadataItem.metadataItems(from: metadata, withKey: chapterKey, keySpace: .id3)

        guard !chapterItems.isEmpty else { return [] }

        let assetDuration = (try? await asset.load(.duration).seconds) ?? 0
        var parsedChapters: [ParsedID3Chapter] = []

        for item in chapterItems {
            guard let data = try? await item.load(.dataValue) else { continue }
            if let parsed = parseID3ChapterFrame(data) {
                parsedChapters.append(parsed)
            }
        }

        guard !parsedChapters.isEmpty else { return [] }

        parsedChapters.sort { $0.startTime < $1.startTime }
        let resolved = resolveChapterEndTimes(parsedChapters, assetDuration: assetDuration)

        return resolved.enumerated().map { index, chapter in
            DetectedChapter(
                title: chapter.title ?? "Chapter \(index + 1)",
                startTime: chapter.startTime,
                endTime: chapter.endTime,
                source: .embedded
            )
        }
    }

    private struct ParsedID3Chapter {
        let startTime: Double
        let endTime: Double
        let title: String?
    }

    private nonisolated func parseID3ChapterFrame(_ data: Data) -> ParsedID3Chapter? {
        var offset = 0
        guard let elementId = readNullTerminatedString(from: data, offset: &offset), !elementId.isEmpty else {
            return nil
        }

        guard let startTimeMs = readUInt32(from: data, offset: &offset),
              let endTimeMs = readUInt32(from: data, offset: &offset),
              readUInt32(from: data, offset: &offset) != nil,
              readUInt32(from: data, offset: &offset) != nil else {
            return nil
        }

        let title = parseID3ChapterTitle(from: data, offset: offset)
        let startTime = Double(startTimeMs) / 1000.0
        let endTime = Double(endTimeMs) / 1000.0
        return ParsedID3Chapter(startTime: startTime, endTime: endTime, title: title)
    }

    private nonisolated func parseID3ChapterTitle(from data: Data, offset: Int) -> String? {
        var currentOffset = offset
        while currentOffset + 10 <= data.count {
            guard let frameId = readString(from: data, offset: &currentOffset, length: 4) else { break }
            guard let sizeValue = readUInt32(from: data, offset: &currentOffset) else { break }
            guard currentOffset + 2 <= data.count else { break }
            let remaining = data.count - (currentOffset + 2)
            let frameSize = resolveID3FrameSize(sizeValue, remaining: remaining)
            currentOffset += 2
            guard frameSize > 0, currentOffset + frameSize <= data.count else { break }

            let frameData = data[currentOffset..<(currentOffset + frameSize)]
            if frameId == "TIT2" || frameId == "TIT3" {
                return decodeTextFrame(Data(frameData))
            }
            currentOffset += frameSize
        }
        return nil
    }

    private nonisolated func decodeTextFrame(_ data: Data) -> String? {
        guard let encodingByte = data.first else { return nil }
        let textData = data.dropFirst()
        let trimChars = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))
        switch encodingByte {
        case 0x00:
            return String(data: textData, encoding: .isoLatin1)?.trimmingCharacters(in: trimChars)
        case 0x01:
            return String(data: textData, encoding: .utf16)?.trimmingCharacters(in: trimChars)
        case 0x02:
            return String(data: textData, encoding: .utf16BigEndian)?.trimmingCharacters(in: trimChars)
        case 0x03:
            return String(data: textData, encoding: .utf8)?.trimmingCharacters(in: trimChars)
        default:
            return nil
        }
    }

    private nonisolated func resolveChapterEndTimes(
        _ chapters: [ParsedID3Chapter],
        assetDuration: Double
    ) -> [ParsedID3Chapter] {
        guard !chapters.isEmpty else { return [] }
        var resolved: [ParsedID3Chapter] = []
        for (index, chapter) in chapters.enumerated() {
            let nextStart = index + 1 < chapters.count ? chapters[index + 1].startTime : assetDuration
            let endTime = chapter.endTime > chapter.startTime ? chapter.endTime : nextStart
            resolved.append(ParsedID3Chapter(startTime: chapter.startTime, endTime: max(endTime, chapter.startTime), title: chapter.title))
        }
        return resolved
    }

    private nonisolated func readNullTerminatedString(from data: Data, offset: inout Int) -> String? {
        guard offset < data.count else { return nil }
        guard let terminatorIndex = data[offset...].firstIndex(of: 0x00) else { return nil }
        let stringData = data[offset..<terminatorIndex]
        offset = terminatorIndex + 1
        return String(data: stringData, encoding: .isoLatin1)
    }

    private nonisolated func readString(from data: Data, offset: inout Int, length: Int) -> String? {
        guard offset + length <= data.count else { return nil }
        let stringData = data[offset..<(offset + length)]
        offset += length
        return String(data: stringData, encoding: .isoLatin1)
    }

    private nonisolated func readUInt32(from data: Data, offset: inout Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { (result, byte) in
            (result << 8) | UInt32(byte)
        }
        offset += 4
        return value
    }

    private nonisolated func resolveID3FrameSize(_ value: UInt32, remaining: Int) -> Int {
        let raw = Int(value)
        if raw > 0 && raw <= remaining {
            return raw
        }
        let syncsafe = Int(syncsafeToUInt32(value))
        return syncsafe > 0 && syncsafe <= remaining ? syncsafe : 0
    }

    private nonisolated func syncsafeToUInt32(_ value: UInt32) -> UInt32 {
        let bytes = (
            (value >> 24) & 0xFF,
            (value >> 16) & 0xFF,
            (value >> 8) & 0xFF,
            value & 0xFF
        )
        return (bytes.0 << 21) | (bytes.1 << 14) | (bytes.2 << 7) | bytes.3
    }
}
