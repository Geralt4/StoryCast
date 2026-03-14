import XCTest
import AVFoundation
import SwiftData
@testable import StoryCast

nonisolated final class ImportServiceStabilityTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()

        Task { @MainActor in
            ImportService.shared.debugResetState()
        }
    }

    @MainActor
    func testFailedImportIdentityUsesStableSourceKey() {
        let url = URL(fileURLWithPath: "/tmp/StoryCast/Book.wav")
        let failedImport = FailedImport(
            url: url,
            fileName: url.lastPathComponent,
            errorType: .networkTimeout,
            errorMessage: ImportErrorType.networkTimeout.userMessage,
            retryCount: 1
        )

        XCTAssertEqual(failedImport.id, url.standardizedFileURL.path)
        XCTAssertEqual(failedImport.sourceKey, url.standardizedFileURL.path)
    }

    @MainActor
    func testCancelImportCleansStagedArtifactsAndLeavesNoBooks() async throws {
        let container = try makeInMemoryContainer()
        let service = ImportService.shared
        service.debugResetState()
        service.debugStageDelayNanoseconds = 800_000_000

        let sourceURL = try makeTemporaryAudioFile(named: "CancelMe.wav")
        let importTask = Task {
            await service.importFiles(urls: [sourceURL], container: container)
        }

        while !service.debugDidStageFile {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        service.cancelImport()
        await importTask.value

        let context = ModelContext(container)
        let books = try context.fetch(FetchDescriptor<Book>())
        XCTAssertTrue(books.isEmpty)

        let libraryEntries = try FileManager.default.contentsOfDirectory(
            at: StorageManager.shared.storyCastLibraryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertFalse(libraryEntries.contains { $0.lastPathComponent.contains("CancelMe") })
        XCTAssertFalse(service.isImporting)
        XCTAssertEqual(service.currentPhase, .idle)
    }

    @MainActor
    func testDismissFailedImportCancelsRetryTaskAndRemovesSingleEntry() async throws {
        let service = ImportService.shared
        service.debugResetState()

        let sourceURL = URL(fileURLWithPath: "/tmp/StoryCast/RetryMe.wav")
        let failure = FailedImport(
            url: sourceURL,
            fileName: sourceURL.lastPathComponent,
            errorType: .connectionLost,
            errorMessage: ImportErrorType.connectionLost.userMessage,
            retryCount: 0
        )

        service.failedImports = [failure]

        let retryTask = Task<Void, Never> {}
        service.debugRegisterRetryTask(retryTask, for: failure.sourceKey)

        XCTAssertEqual(service.debugRetryTaskCount, 1)

        service.dismissFailedImport(failure)

        XCTAssertTrue(service.failedImports.isEmpty)
        XCTAssertEqual(service.debugRetryTaskCount, 0)
        XCTAssertTrue(retryTask.isCancelled)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Book.self, Chapter.self, Folder.self, ABSServer.self, configurations: config)
    }

    private func makeTemporaryAudioFile(named fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempURLs.append(directory)

        let fileURL = directory.appendingPathComponent(fileName)
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        let frameCount = AVAudioFrameCount(sampleRate / 10)

        guard let format else {
            throw NSError(domain: "ImportServiceStabilityTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing audio format"])
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "ImportServiceStabilityTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing audio buffer"])
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
}
