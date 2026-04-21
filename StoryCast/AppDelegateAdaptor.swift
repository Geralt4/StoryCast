import Foundation

#if os(iOS)
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DownloadManager.shared.storeBackgroundCompletionHandler(identifier: identifier, completionHandler: completionHandler)
    }
}
#endif
