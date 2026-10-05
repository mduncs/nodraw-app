import Foundation

/// Simple synchronous logger - writes to ~/Library/Logs/NoDraw/nodraw.log
/// Appends across launches. Rotates to .1 when file exceeds ~1MB.
enum Log {
    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    private static let maxLogSize: UInt64 = 1_000_000 // ~1MB

    private static let logFile: URL = {
        let logsDir = BackgroundQAConfiguration.logsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NoDraw")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let url = logsDir.appendingPathComponent("nodraw.log")

        // Rotate if over size limit
        rotateIfNeeded(url)

        // Append startup marker (not overwrite)
        let isoDate = ISO8601DateFormatter().string(from: Date())
        let marker = "\n=== NoDraw Log Started \(isoDate) ===\n"
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(marker.data(using: .utf8) ?? Data())
                try? handle.close()
            }
        } else {
            try? marker.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }()

    /// Rotate log file: current -> .1 (keep only one rotated copy)
    private static func rotateIfNeeded(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else { return }

        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent("nodraw.log.1")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: url, to: rotated)
    }

    /// Throttle rotation checks (not every single log line)
    private static var linesSinceRotationCheck: Int = 0

    private static func log(_ level: String, _ message: String, file: String, line: Int) {
        let timestamp = dateFormatter.string(from: Date())
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let logLine = "[\(timestamp)] [\(level)] \(fileName):\(line) - \(message)\n"

        // Check rotation every ~500 lines
        linesSinceRotationCheck += 1
        if linesSinceRotationCheck >= 500 {
            linesSinceRotationCheck = 0
            rotateIfNeeded(logFile)
        }

        // Write to file
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(logLine.data(using: .utf8) ?? Data())
            try? handle.close()
        }

        // Also print
        print(logLine, terminator: "")
    }

    static func info(_ message: String, file: String = #file, line: Int = #line) {
        log("INFO", message, file: file, line: line)
    }

    static func error(_ message: String, file: String = #file, line: Int = #line) {
        log("ERROR", message, file: file, line: line)
    }

    static func debug(_ message: String, file: String = #file, line: Int = #line) {
        log("DEBUG", message, file: file, line: line)
    }

    static func warning(_ message: String, file: String = #file, line: Int = #line) {
        log("WARN", message, file: file, line: line)
    }
}

// Convenience global functions
func logInfo(_ message: String, file: String = #file, line: Int = #line) {
    Log.info(message, file: file, line: line)
}

func logError(_ message: String, file: String = #file, line: Int = #line) {
    Log.error(message, file: file, line: line)
}

func logDebug(_ message: String, file: String = #file, line: Int = #line) {
    Log.debug(message, file: file, line: line)
}

func logWarning(_ message: String, file: String = #file, line: Int = #line) {
    Log.warning(message, file: file, line: line)
}
