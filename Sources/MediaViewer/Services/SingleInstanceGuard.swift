import Foundation
import AppKit
import Darwin

// MARK: - SingleInstanceGuard

/// Ensures only one instance of the application runs at a time.
/// Uses both running application detection and a lockfile fallback.
final class SingleInstanceGuard {

    /// Shared instance
    static let shared = SingleInstanceGuard()

    /// Lock file path
    private let lockFileURL: URL

    /// File handle for the lock (kept open while app runs)
    private var lockFileHandle: FileHandle?

    /// True only for the process that successfully acquired the lock file.
    private var ownsLockFile = false

    /// Set when launch was rejected because another instance is already active.
    private(set) var duplicateLaunchDetected = false

    private init() {
        self.lockFileURL = AppPaths.appDataDirectory.appendingPathComponent(".lock")
    }

    private var isBypassedForTesting: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--disable-single-instance") ||
            processInfo.environment["MEDIAVIEWER_DISABLE_SINGLE_INSTANCE"] == "1"
    }

    // MARK: - Public API

    /// Check if another instance is already running.
    /// If found, activates the existing instance.
    /// - Returns: true if this is the only instance, false if another exists
    func acquireLock() -> Bool {
        if isBypassedForTesting {
            duplicateLaunchDetected = false
            return true
        }

        if lockFileHandle != nil {
            return true
        }

        duplicateLaunchDetected = false

        // First check: running app / process detection.
        if let existingPID = findExistingInstancePID() {
            logWarning("SingleInstanceGuard: existing pid=\(existingPID), current=\(ProcessInfo.processInfo.processIdentifier), bundle=\(Bundle.main.bundleIdentifier ?? "unbundled")")
            activateExistingProcess(pid: existingPID)
            duplicateLaunchDetected = true
            return false
        }

        // Fallback: lockfile approach (for edge cases or debugging)
        let acquired = acquireLockFile()
        duplicateLaunchDetected = !acquired

        if !acquired {
            activateInstanceFromLockFile()
        }

        return acquired
    }

    /// Release the lock when app terminates
    func releaseLock() {
        guard ownsLockFile else { return }
        ownsLockFile = false

        if let handle = lockFileHandle {
            // Release exclusive lock
            flock(handle.fileDescriptor, LOCK_UN)
            try? handle.close()
            lockFileHandle = nil
        }

        // Remove lockfile only if it still points at this process.
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if existingInstancePID() == currentPID {
            try? FileManager.default.removeItem(at: lockFileURL)
        }
    }

    // MARK: - Private

    private func acquireLockFile() -> Bool {
        // Create lockfile if it doesn't exist
        if !FileManager.default.fileExists(atPath: lockFileURL.path) {
            FileManager.default.createFile(atPath: lockFileURL.path, contents: nil)
        }

        // Open file for writing
        guard let handle = FileHandle(forWritingAtPath: lockFileURL.path) else {
            logWarning("SingleInstanceGuard: Failed to open lock file")
            return true // Allow launch on failure (fail-open)
        }

        // Try to acquire exclusive lock (non-blocking)
        let lockResult = flock(handle.fileDescriptor, LOCK_EX | LOCK_NB)

        if lockResult == 0 {
            // Got the lock
            lockFileHandle = handle
            ownsLockFile = true

            // Write our PID to the file
            let pid = ProcessInfo.processInfo.processIdentifier
            let pidData = "\(pid)\n".data(using: .utf8)!
            try? handle.truncate(atOffset: 0)
            try? handle.write(contentsOf: pidData)

            return true
        } else {
            // Lock is held by another process
            try? handle.close()
            return false
        }
    }

    private func findExistingInstancePID() -> pid_t? {
        let currentPID = ProcessInfo.processInfo.processIdentifier

        if let bundleId = Bundle.main.bundleIdentifier {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            if let existingApp = runningApps.first(where: {
                $0.processIdentifier > 0 && $0.processIdentifier != currentPID && !$0.isTerminated
            }) {
                return existingApp.processIdentifier
            }
        }

        guard let executableURL = Bundle.main.executableURL
            ?? CommandLine.arguments.first.map({ URL(fileURLWithPath: $0) }) else {
            return nil
        }

        let currentExecutablePath = executableURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        let pidBufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard pidBufferSize > 0 else { return nil }

        let pidCount = Int(pidBufferSize) / MemoryLayout<pid_t>.size
        var pids = Array(repeating: pid_t(0), count: pidCount)
        let bytesWritten = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &pids,
            Int32(MemoryLayout<pid_t>.size * pids.count)
        )

        guard bytesWritten > 0 else { return nil }

        let activePIDCount = Int(bytesWritten) / MemoryLayout<pid_t>.size
        for pid in pids.prefix(activePIDCount) where pid > 0 && pid != currentPID {
            var pathBuffer = Array(repeating: CChar(0), count: Int(MAXPATHLEN))
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard pathLength > 0 else { continue }

            let candidatePath = URL(fileURLWithPath: String(cString: pathBuffer))
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path

            if candidatePath == currentExecutablePath {
                return pid
            }
        }

        return nil
    }

    private func activateExistingProcess(pid: pid_t) {
        let runningApps = NSWorkspace.shared.runningApplications
        if let existingInstance = runningApps.first(where: { $0.processIdentifier == pid }) {
            existingInstance.activate(options: [.activateAllWindows])
        }
    }

    private func activateInstanceFromLockFile() {
        guard let pid = existingInstancePID() else { return }
        activateExistingProcess(pid: pid)
    }

    /// Read PID from lockfile (for debugging)
    func existingInstancePID() -> pid_t? {
        guard let data = try? Data(contentsOf: lockFileURL),
              let pidString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(pidString) else {
            return nil
        }
        return pid
    }
}

// MARK: - Alert Helper

extension SingleInstanceGuard {

    /// Show an alert that another instance is running
    /// Call this on the main thread before terminating
    @MainActor
    func showAlreadyRunningAlert() {
        let alert = NSAlert()
        alert.messageText = "NoDraw is already running"
        alert.informativeText = "Another instance of NoDraw is already open. The existing window has been activated."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
