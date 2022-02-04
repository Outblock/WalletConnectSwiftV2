
import Foundation

protocol BackgroundTaskRegistering {
    func register(name: String, completion: @escaping ()->())
}

class BackgroundTaskRegistrar: BackgroundTaskRegistering {
#if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
#endif

    func register(name: String, completion: @escaping () -> ()) {
#if os(iOS)
        backgroundTaskID = UIApplication.shared.beginBackgroundTask (withName: name) { [weak self] in
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
            completion()
        }
#endif
    }
}
