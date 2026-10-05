import Foundation

enum BuildInfo {
    static var version: String {
        #if BUILD_INFO_GENERATED
        BuildInfoGenerated.version
        #else
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1"
        #endif
    }

    static var gitHash: String {
        #if BUILD_INFO_GENERATED
        BuildInfoGenerated.gitHash
        #else
        #if DEBUG
        runtimeGitHash() ?? "dev"
        #else
        "release"
        #endif
        #endif
    }

    static var buildDate: String {
        #if BUILD_INFO_GENERATED
        BuildInfoGenerated.buildDate
        #else
        #if DEBUG
        ISO8601DateFormatter().string(from: Date())
        #else
        "release"
        #endif
        #endif
    }

    static var versionDisplay: String {
        "\(version) (\(gitHash))"
    }

    #if DEBUG
    private static func runtimeGitHash() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "--short", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
    #endif
}
