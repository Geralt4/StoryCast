import Foundation
import SwiftData
import os

@MainActor
final class ProgressBackupStore {
    static let shared = ProgressBackupStore()
    
    private init() {}
    
    func backup(serverURL: String, itemId: String, currentTime: Double, timeListened: Double, duration: Double) {
        let key = pendingProgressKey(serverURL: serverURL, itemId: itemId)
        let backup: [String: Any] = [
            "currentTime": currentTime,
            "timeListened": timeListened,
            "duration": duration,
            "timestamp": Date().timeIntervalSince1970
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
    
    func attemptRecovery(server: ABSServer, itemId: String) async {
        let key = pendingProgressKey(serverURL: server.normalizedURL, itemId: itemId)
        guard let backup = UserDefaults.standard.dictionary(forKey: key),
              let currentTime = backup["currentTime"] as? Double,
              let _ = backup["timeListened"] as? Double,
              let duration = backup["duration"] as? Double else {
            return
        }
        
        guard let token = await AudiobookshelfAuth.shared.token(for: server.normalizedURL) else {
            return
        }
        
        do {
            try await AudiobookshelfAPI.shared.updateProgress(
                baseURL: server.normalizedURL,
                token: token,
                itemId: itemId,
                currentTime: currentTime,
                duration: duration,
                isFinished: duration > 0 && currentTime >= duration - 10
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
}
#endif