import Foundation

#if os(iOS)
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Recreate the background download session right away: when iOS
        // relaunches the app for download events, the library UI (and its
        // startup work) may never run.
        DownloadManager.shared.activate()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DownloadManager.shared.storeBackgroundCompletionHandler(identifier: identifier, completionHandler: completionHandler)
        DownloadManager.shared.activate()
    }
}
#endif
