import Foundation

enum RealtimeDebug {
    private static let defaultsKey = "hv_realtime_debug"

    static var enabled: Bool {
        // Priority 1: Scheme environment variable (when set).
        if ProcessInfo.processInfo.environment["HV_REALTIME_DEBUG"] == "1" {
            return true
        }

        // Priority 2: persisted flag (so you don't need Scheme edits).
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }

        // Default: on in Debug builds, off in Release.
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: defaultsKey)
    }
}

