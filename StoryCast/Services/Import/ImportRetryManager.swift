import Foundation
import SwiftData
import os

@MainActor
final class ImportRetryManager {
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var performImport: @Sendable (URL, UUID?, ModelContainer, Int) async throws -> Bool
    private var getFailedImports: () -> [FailedImport]
    private var updateFailedImports: ([FailedImport]) -> Void

    init(
        performImport: @escaping @Sendable @MainActor (URL, UUID?, ModelContainer, Int) async throws -> Bool,
        getFailedImports: @escaping () -> [FailedImport],
        updateFailedImports: @escaping ([FailedImport]) -> Void
    ) {
        self.performImport = performImport
        self.getFailedImports = getFailedImports
        self.updateFailedImports = updateFailedImports
    }

    func recordFailure(
        for url: URL,
        errorType: ImportErrorType,
        retryCount: Int,
        container: ModelContainer,
        shouldScheduleAutoRetry: Bool
    ) {
        let failedImport = FailedImport(
            url: url,
            fileName: url.lastPathComponent,
            errorType: errorType,
            errorMessage: errorType.userMessage,
            retryCount: retryCount
        )

        upsertFailedImport(failedImport)

        if shouldScheduleAutoRetry && failedImport.canAutoRetry {
            scheduleAutoRetry(for: failedImport, container: container)
        } else {
            retryTasks.removeValue(forKey: failedImport.sourceKey)?.cancel()
        }
    }

    func retryImport(_ failedImport: FailedImport, container: ModelContainer) async {
        retryTasks.removeValue(forKey: failedImport.sourceKey)?.cancel()
        let previousRetryCount = failedImport.retryCount
        updateFailedImports(getFailedImports().filter { $0.sourceKey != failedImport.sourceKey })
        await performRetryImport(url: failedImport.url, folderId: nil, container: container, previousRetryCount: previousRetryCount)
    }

    func retryAllFailed(container: ModelContainer) async {
        let failedImports = getFailedImports()
        let retryableImports = failedImports.filter { $0.errorType.isTransient }
        let retryCounts = Dictionary(uniqueKeysWithValues: retryableImports.map { ($0.sourceKey, $0.retryCount) })

        for failedImport in retryableImports {
            retryTasks.removeValue(forKey: failedImport.sourceKey)?.cancel()
        }

        updateFailedImports(failedImports.filter { !$0.errorType.isTransient })

        for failedImport in retryableImports {
            let previousRetryCount = retryCounts[failedImport.sourceKey] ?? 0
            await performRetryImport(url: failedImport.url, folderId: nil, container: container, previousRetryCount: previousRetryCount)
        }
    }

    func dismissFailedImport(_ failedImport: FailedImport) {
        retryTasks.removeValue(forKey: failedImport.sourceKey)?.cancel()
        updateFailedImports(getFailedImports().filter { $0.sourceKey != failedImport.sourceKey })
    }

    func cancelAllRetryTasks() {
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
    }

    var retryTaskCount: Int { retryTasks.count }

    #if DEBUG
    func debugRegisterRetryTask(_ task: Task<Void, Never>, for sourceKey: String) {
        retryTasks[sourceKey]?.cancel()
        retryTasks[sourceKey] = task
    }

    func debugResetState() {
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
    }
    #endif

    private func upsertFailedImport(_ failedImport: FailedImport) {
        var imports = getFailedImports()
        if let index = imports.firstIndex(where: { $0.sourceKey == failedImport.sourceKey }) {
            imports[index] = failedImport
        } else {
            imports.append(failedImport)
        }
        updateFailedImports(imports)
    }

    private func performRetryImport(url: URL, folderId: UUID?, container: ModelContainer, previousRetryCount: Int) async {
        do {
            _ = try await performImport(url, folderId, container, previousRetryCount + 1)
        } catch is CancellationError {
            return
        } catch {
            AppLogger.importService.error("Retry import failed for \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
        }
    }

    private func scheduleAutoRetry(for failedImport: FailedImport, container: ModelContainer) {
        let sourceKey = failedImport.sourceKey
        retryTasks.removeValue(forKey: sourceKey)?.cancel()

        guard failedImport.canAutoRetry else { return }

        let attemptNumber = failedImport.retryCount + 1
        let delay = pow(2.0, Double(failedImport.retryCount))

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch is CancellationError {
                retryTasks.removeValue(forKey: sourceKey)
                return
            } catch {
                AppLogger.importService.warning("Unexpected error during auto-retry delay: \(error.localizedDescription, privacy: .private)")
                retryTasks.removeValue(forKey: sourceKey)
                return
            }

            let currentImports = getFailedImports()
            guard !Task.isCancelled,
                  let currentFailure = currentImports.first(where: { $0.sourceKey == sourceKey }),
                  currentFailure.retryCount + 1 == attemptNumber else {
                retryTasks.removeValue(forKey: sourceKey)
                return
            }

            retryTasks.removeValue(forKey: sourceKey)
            await retryImport(currentFailure, container: container)
        }

        retryTasks[sourceKey] = task
    }
}