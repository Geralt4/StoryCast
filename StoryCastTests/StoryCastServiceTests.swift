import XCTest
import AVFoundation
import Combine
import SwiftData

#if canImport(UIKit)
import UIKit
#endif
@testable import StoryCast

nonisolated final class StoryCastServiceTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        Task { @MainActor in
            SleepTimerService.shared.cancel()
            AudioPlayerService.shared.pause()
        }
    }

    @MainActor
    func testAudioPlayerServiceLoadsAudio() async throws {
        let fileURL = try makeTemporaryAudioFile()
        let expectation = XCTestExpectation(description: "Loads audio duration")
        let audioPlayer = AudioPlayerService.shared
        var cancellable: AnyCancellable?

        cancellable = audioPlayer.$duration.dropFirst().sink { duration in
            if duration > 0 {
                expectation.fulfill()
            }
        }

        audioPlayer.loadAudio(url: fileURL, title: "Test Audio", duration: 10.0, seekTo: 0)
        await fulfillment(of: [expectation], timeout: 3)
        cancellable?.cancel()
        XCTAssertEqual(audioPlayer.currentURL, fileURL)
        XCTAssertGreaterThan(audioPlayer.duration, 0)
    }

    func testSleepTimerServiceStartAndCancel() async {
        let service = await MainActor.run { SleepTimerService.shared }
        await MainActor.run {
            service.start(minutes: 1)
            XCTAssertTrue(service.isActive)
            XCTAssertEqual(service.totalTime, 60)
            XCTAssertEqual(service.remainingTime, 60)

            service.extendBy(minutes: 1)
            XCTAssertEqual(service.remainingTime, 120)
            XCTAssertEqual(service.totalTime, 120)

            service.cancel()
            XCTAssertFalse(service.isActive)
            XCTAssertEqual(service.remainingTime, 0)
            XCTAssertEqual(service.totalTime, 0)
        }
    }

    func testStorageManagerCopiesAndDeletesFiles() async throws {
        let storageManager = StorageManager.shared
        let sourceURL = try makeTemporaryAudioFile()
        let destinationURL = try await storageManager.copyFileToStoryCastLibraryDirectory(
            from: sourceURL,
            withName: sourceURL.lastPathComponent
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))

        let imageData = try makeTestImageData()
        let bookId = UUID()
        let coverFileName = try await storageManager.saveCoverArt(imageData, for: bookId)
        XCTAssertNotNil(coverFileName)
        if let coverFileName {
            let coverURL = storageManager.coverArtURL(for: coverFileName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: coverURL.path))
            await storageManager.deleteCoverArt(fileName: coverFileName)
            XCTAssertFalse(FileManager.default.fileExists(atPath: coverURL.path))
        }
    }

    func testURLValidatorNormalizesHTTPSBaseURL() throws {
        let normalized = try AudiobookshelfURLValidator.normalizedBaseURLString(from: "abs.example.com:13378/")
        XCTAssertEqual(normalized, "https://abs.example.com:13378")
    }

    func testURLValidatorRejectsHTTPBaseURL() {
        XCTAssertThrowsError(try AudiobookshelfURLValidator.normalizedBaseURLString(from: "http://abs.example.com")) { error in
            guard case APIError.insecureConnection = error else {
                return XCTFail("Expected insecure connection error")
            }
        }
    }

    func testURLValidatorRejectsBaseURLWithPath() {
        XCTAssertThrowsError(try AudiobookshelfURLValidator.normalizedBaseURLString(from: "https://abs.example.com/library")) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error")
            }
        }
    }

    func testStreamingURLAllowsOnlySameOriginHTTPS() throws {
        let url = try AudiobookshelfURLValidator.validatedStreamingURL(
            baseURL: "https://abs.example.com:13378",
            contentURL: "/api/items/123/file.mp3"
        )

        XCTAssertEqual(url.absoluteString, "https://abs.example.com:13378/api/items/123/file.mp3")
    }

    func testStreamingURLRejectsTokenQueryAndCrossOriginURLs() {
        XCTAssertThrowsError(
            try AudiobookshelfURLValidator.validatedStreamingURL(
                baseURL: "https://abs.example.com",
                contentURL: "https://evil.example.com/file.mp3"
            )
        ) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error for cross-origin stream")
            }
        }

        XCTAssertThrowsError(
            try AudiobookshelfURLValidator.validatedStreamingURL(
                baseURL: "https://abs.example.com",
                contentURL: "/api/items/file.mp3?token=secret"
            )
        ) { error in
            guard case APIError.invalidURL = error else {
                return XCTFail("Expected invalid URL error for token query")
            }
        }
    }

    @MainActor
    func testAuthenticatedStreamUsesAuthorizationHeaderOnly() throws {
        let stream = AuthenticatedStream(
            url: URL(string: "https://abs.example.com/file.mp3")!,
            headers: ["Authorization": "Bearer token123"]
        )

        let request = stream.makeRequest()
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token123")
        XCTAssertNil(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
    }

    @MainActor
    func testImportServiceImportsAudioFile() async throws {
        let fileURL = try makeTemporaryAudioFile()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Book.self, Chapter.self, Folder.self, configurations: config)
        let service = ImportService.shared

        try await service.importFile(url: fileURL, container: container)
        let context = container.mainContext
        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.isImported, true)
    }

    private func makeTemporaryAudioFile() throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let sampleRate = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        let frameCount = AVAudioFrameCount(sampleRate / 10)
        guard let format else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing audio format"])
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing audio buffer"])
        }
        buffer.frameLength = frameCount
        if let channelData = buffer.floatChannelData {
            channelData[0].initialize(repeating: 0, count: Int(frameCount))
        }

        let audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        try audioFile.write(from: buffer)
        tempURLs.append(fileURL)
        return fileURL
    }

    private func makeTestImageData() throws -> Data {
        #if os(iOS)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 10, height: 10)))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing image data"])
        }
        return data
        #else
        throw NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported platform"])
        #endif
    }
}
