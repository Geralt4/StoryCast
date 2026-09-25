import Foundation
import SwiftData
import os

@MainActor
final class ProgressBackupStore {
    static let shared = ProgressBackupStore()
    
    private var apiOverride: AudiobookshelfAPI?
    private var api: AudiobookshelfAPI { apiOverride ?? .shared }

    private init() {}
    
    /// `changedAt` is when the position last really changed; it defaults to now.
    /// Recording the change time (not the time of the backup) keeps a paused,
    /// stale position from looking newer than progress made elsewhere.
    func backup(serverURL: String, itemId: String, currentTime: Double, timeListened: Double, duration: Double, changedAt: Date? = nil) {
        let key = pendingProgressKey(serverURL: serverURL, itemId: itemId)
        let backup: [String: Any] = [
            "currentTime": currentTime,
            "timeListened": timeListened,
            "duration": duration,
            "timestamp": (changedAt ?? Date()).timeIntervalSince1970
        ]
        UserDefaults.standard.set(backup, forKey: key)
        AppLogger.sync.warning("Progress backed up locally due to sync failure: \(currentTime)s")
    }
    
    func hasPending(serverURL: String, itemId: String) -> Bool {
        let key = pendingProgressKey(serverURL: serverURL, itemId: itemId)
        return UserDefaults.standard.dictionary(forKey: key) != nil
    }
    
    func clear(serverURL: String, itemId: String) {
        let key = pendingProgressKey(serverURL: serverURL, itemId: itemId)
        UserDefaults.standard.removeObject(forKey: key)
    }
    
    /// Position and change time of the progress backed up for an item.
    func pendingProgress(serverURL: String, itemId: String) -> (position: Double, changedAt: Date)? {
        let key = pendingProgressKey(serverURL: serverURL, itemId: itemId)
        guard let backup = UserDefaults.standard.dictionary(forKey: key),
              let currentTime = backup["currentTime"] as? Double,
              let timestamp = backup["timestamp"] as? Double else { return nil }
        return (currentTime, Date(timeIntervalSince1970: timestamp))
    }

    /// Sends backed-up progress to the server, unless the server has newer
    /// progress (from another device), in which case the backup is dropped.
    /// Pass `serverProgress` when it was already fetched; otherwise it is
    /// fetched here, and nothing is sent if that fails.
    func attemptRecovery(server: ABSServer, itemId: String, serverProgress: ServerProgressSnapshot?? = nil) async {
        let key = pendingProgressKey(serverURL: server.normalizedURL, itemId: itemId)
        guard let backup = UserDefaults.standard.dictionary(forKey: key),
              let currentTime = backup["currentTime"] as? Double,
              let duration = backup["duration"] as? Double else {
            return
        }
        
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            return
        }

        let snapshot: ServerProgressSnapshot?
        if let serverProgress {
            snapshot = serverProgress
        } else {
            do {
                snapshot = try await api.fetchProgressSnapshot(baseURL: server.normalizedURL, token: token, itemId: itemId)
            } catch {
                AppLogger.sync.debug("Couldn't check server progress before recovery: \(error.localizedDescription, privacy: .private)")
                return
            }
        }
        let changedAt = (backup["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let decision = ResumePositionResolver.resolve(
            local: .init(position: currentTime, changedAt: changedAt, isDirty: true),
            server: snapshot,
            timelineDuration: duration
        )
        guard decision.source == .local else {
            clear(serverURL: server.normalizedURL, itemId: itemId)
            AppLogger.sync.info("Dropped backed-up progress; the server has newer progress")
            return
        }
        
        do {
            let isFinished = duration > 0 && currentTime >= duration - 10
            try await api.updateProgress(
                baseURL: server.normalizedURL,
                token: token,
                itemId: itemId,
                currentTime: currentTime,
                duration: duration,
                isFinished: isFinished ? true : nil
            )
            clear(serverURL: server.normalizedURL, itemId: itemId)
            AppLogger.sync.info("Recovered pending progress: \(currentTime)s")
        } catch {
            AppLogger.sync.error("Failed to recover pending progress: \(error.localizedDescription, privacy: .private)")
        }
    }
    
    func recoverPendingForAllBooks(container: ModelContainer) async {
        let context = ModelContext(container)
        
        do {
            let books = try context.fetch(FetchDescriptor<Book>())
            let servers = try context.fetch(FetchDescriptor<ABSServer>())
            let serversByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
            
            for book in books where book.isRemote {
                guard let itemId = book.remoteItemId,
                      let serverID = book.serverId,
                      let server = serversByID[serverID],
                      hasPending(serverURL: server.normalizedURL, itemId: itemId) else {
                    continue
                }
                
                await attemptRecovery(server: server, itemId: itemId)
            }
        } catch {
            AppLogger.sync.error("Failed to recover pending progress at startup: \(error.localizedDescription, privacy: .private)")
        }
    }
    
    private func pendingProgressKey(serverURL: String, itemId: String) -> String {
        let normalizedServer: String
        do {
            normalizedServer = try AudiobookshelfURLValidator.normalizedBaseURLString(from: serverURL)
        } catch {
            AppLogger.network.debug("Could not normalize server URL for progress key: \(error.localizedDescription, privacy: .private)")
            normalizedServer = serverURL
        }
        let digest = Data(normalizedServer.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "pendingProgress_\(digest)_\(itemId)"
    }
}

#if DEBUG
extension ProgressBackupStore {
    func debugPendingProgressKey(serverURL: String, itemId: String) -> String {
        pendingProgressKey(serverURL: serverURL, itemId: itemId)
    }
    
    func debugHasPending(serverURL: String, itemId: String) -> Bool {
        hasPending(serverURL: serverURL, itemId: itemId)
    }
    
    func debugBackup(serverURL: String, itemId: String, currentTime: Double, timeListened: Double, duration: Double) {
        backup(serverURL: serverURL, itemId: itemId, currentTime: currentTime, timeListened: timeListened, duration: duration)
    }
    
    func debugClear(serverURL: String, itemId: String) {
        clear(serverURL: serverURL, itemId: itemId)
    }

    func debugOverrideAPI(_ api: AudiobookshelfAPI?) { apiOverride = api }

    func debugBackupTimestamp(serverURL: String, itemId: String) -> Double? {
        UserDefaults.standard.dictionary(forKey: pendingProgressKey(serverURL: serverURL, itemId: itemId))?["timestamp"] as? Double
    }
}
#endif