import AppKit

@MainActor
enum AppLauncher {
    static func open(bundleIdentifier: String, fallbackPath: String,
                     completion: ((Error?) -> Void)? = nil) {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            ?? URL(fileURLWithPath: fallbackPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            completion?(NSError(domain: "AppLauncher", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "未找到对应的桌面应用"]))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.hides = false
        // Always deliver the standard reopen event. Activation alone cannot restore a
        // minimized Electron window, while reopen uses the app's own window handling.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { running, error in
            DispatchQueue.main.async {
                if let error {
                    NSLog("Could not open %@: %@", bundleIdentifier, error.localizedDescription)
                    completion?(error)
                    return
                }
                running?.unhide()
                running?.activate(options: [.activateAllWindows])
                completion?(nil)
            }
        }
    }
}
