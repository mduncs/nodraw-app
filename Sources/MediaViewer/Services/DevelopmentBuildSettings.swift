import Foundation

enum DevelopmentBuildSettings {
    static var skipsOnboarding: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["NODRAW_DEV_REQUIRE_ONBOARDING"] != "1"
        #else
        return false
        #endif
    }

    static var usesLiveDatabaseByDefault: Bool {
        #if DEBUG
        return !CommandLine.arguments.contains("--test-vault") &&
            ProcessInfo.processInfo.environment["NODRAW_APP_SUPPORT_DIR"] == nil &&
            ProcessInfo.processInfo.environment["MEDIAVIEWER_APP_SUPPORT_DIR"] == nil
        #else
        return false
        #endif
    }
}
