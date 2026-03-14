import Foundation
import UniformTypeIdentifiers

/// Handles iCloud file downloads and progress monitoring for imports.
///
/// `ImportCloudHandler` manages:
/// - Checking cloud file availability
/// - Triggering downloads for iCloud files
/// - Monitoring download progress with timeout support
/// - File coordination for safe access
///
/// ## Usage
///
/// ```swift
/// let cloudHandler = ImportCloudHandler.shared
/// try await cloudHandler.accessCloudFile(at: url)
/// ```
actor ImportCloudHandler {
    static let shared = ImportCloudHandler()
    
    private init() {}
    
    /// Downloads and monitors iCloud file progress.
    ///
    /// - Parameters:
    ///   - url: The iCloud file URL
    ///   - progressHandler: Optional closure to receive progress updates (0.0-1.0)
    /// - Returns: `true` when download completes
    /// - Throws: Error if download times out or fails
    func downloadCloudFile(
        at url: URL,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Bool {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        return try await monitorDownloadProgress(url: url, progressHandler: progressHandler)
    }
    
    /// Accesses a cloud file, downloading if necessary.
    ///
    /// - Parameter url: The cloud file URL
    /// - Returns: `true` when file is accessible
    /// - Throws: Error if access fails or times out
    func accessCloudFile(
        at url: URL,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Bool {
        let resourceValues = try await loadCloudResourceValues(for: url)
        
        if !resourceValues.isCurrent {
            return try await downloadCloudFile(at: url, progressHandler: progressHandler)
        }
        
        return try await coordinateFileAccess(at: url)
    }
    
    // MARK: - Private
    
    /// Monitors iCloud download progress with timeout.
    private func monitorDownloadProgress(
        url: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> Bool {
        let startTime = Date()
        let timeout: TimeInterval = 300
        
        while Date().timeIntervalSince(startTime) < timeout {
            try await Task.sleep(nanoseconds: 500_000_000)
            
            let resourceValues = try await loadCloudResourceValues(for: url)
            
            if resourceValues.isCurrent {
                return true
            }
            
            if let percentDownloaded = resourceValues.percentDownloaded {
                let progress = percentDownloaded / 100.0
                progressHandler?(progress)
            }
            
            try Task.checkCancellation()
        }
        
        throw ImportServiceError.downloadTimedOut
    }
    
    /// Coordinates safe file access using NSFileCoordinator.
    private func coordinateFileAccess(at url: URL) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let coordinator = NSFileCoordinator()
            let intent = NSFileAccessIntent.readingIntent(with: url, options: .withoutChanges)
            
            let backgroundQueue = OperationQueue()
            backgroundQueue.qualityOfService = .utility
            
            coordinator.coordinate(with: [intent], queue: backgroundQueue) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: true)
                }
            }
        }
    }
    
    /// Loads cloud-specific resource values for a file.
    private func loadCloudResourceValues(for url: URL) async throws -> (isCurrent: Bool, percentDownloaded: Double?) {
        try await Task.detached(priority: .utility) {
            let resourceValues = try url.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey, URLResourceKey("ubiquitousItemPercentDownloadedKey")]
            )
            let status = resourceValues.ubiquitousItemDownloadingStatus
            let isCurrent = status == nil || status == .current
            let percentDownloaded = (resourceValues.allValues[URLResourceKey("ubiquitousItemPercentDownloadedKey")] as? NSNumber)?.doubleValue
            return (isCurrent, percentDownloaded)
        }.value
    }
}
