import Foundation
import Darwin

// MARK: - Crash Telemetry

/// Captures crash context for silent/undiagnosed crashes.
/// - Installs POSIX signal handlers (SIGSEGV, SIGABRT, SIGBUS, SIGTRAP, SIGFPE, SIGILL)
/// - Maintains a rolling breadcrumb trail written to disk
/// - On crash: writes last-known state + breadcrumbs to a crash file
/// - On next launch: detects previous crash and logs it
/// - Redirects stderr to a log file so Swift runtime fatal errors are captured
///
/// Signal handler uses ONLY async-signal-safe functions: write(), open(), close(), _exit().
/// No Swift String ops, no malloc, no locks inside the handler.
enum CrashTelemetry {

    // MARK: - File paths

    private static let logsDir: String = {
        if let isolated = BackgroundQAConfiguration.logsDirectory { return isolated.path }
        let home = NSHomeDirectory()
        return "\(home)/Library/Logs/NoDraw"
    }()

    /// Rolling breadcrumbs file — overwritten atomically on each breadcrumb
    static let breadcrumbPath: String = {
        "\(logsDir)/crash-breadcrumbs.txt"
    }()

    /// Written by signal handler on crash — presence on next launch = previous crash
    static let crashFilePath: String = {
        "\(logsDir)/crash-report.txt"
    }()

    /// Sentinel: written on clean launch, removed on clean shutdown.
    /// If present on next launch, previous session didn't exit cleanly.
    static let sessionSentinelPath: String = {
        "\(logsDir)/session-active.sentinel"
    }()

    /// Runtime heartbeat, updated periodically while app is alive.
    static let heartbeatPath: String = {
        "\(logsDir)/runtime-heartbeat.txt"
    }()

    /// Append-only resource snapshots for memory/FD/CPU trend analysis.
    static let resourceLogPath: String = {
        "\(logsDir)/runtime-resources.log"
    }()

    /// Stderr capture file — Swift runtime fatalError/precondition messages end up here
    static let stderrLogPath: String = {
        "\(logsDir)/stderr.log"
    }()

    // MARK: - Thread-safe breadcrumb ring buffer

    /// Fixed-size ring buffer of recent actions, protected by unfair lock
    private static let maxBreadcrumbs = 30
    private static var breadcrumbs: [String] = []
    private static var breadcrumbIndex: Int = 0
    private static var breadcrumbLock = os_unfair_lock()

    // MARK: - Pre-allocated signal-safe C strings for crash file header

    /// Pre-allocated C-string paths for use inside signal handler (no Swift String allocation)
    private static var crashFilePathCStr: UnsafeMutablePointer<CChar>!
    private static var breadcrumbPathCStr: UnsafeMutablePointer<CChar>!
    private static var heartbeatPathCStr: UnsafeMutablePointer<CChar>!
    private static var resourceLogPathCStr: UnsafeMutablePointer<CChar>!
    private static var stderrLogPathCStr: UnsafeMutablePointer<CChar>!

    // MARK: - Lightweight runtime monitors

    private static let monitorQueue = DispatchQueue(label: "com.nodraw.crashtelemetry.monitor")
    private static let maxResourceLogBytes: UInt64 = 2 * 1024 * 1024
    private static let heartbeatInterval: TimeInterval = 20
    private static let mainThreadProbeInterval: TimeInterval = 15
    private static let mainThreadStallThreshold: TimeInterval = 8

    private static var heartbeatTimer: DispatchSourceTimer?
    private static var mainThreadProbeTimer: DispatchSourceTimer?
    private static var memoryPressureSource: DispatchSourceMemoryPressure?
    private static var nextProbeID: UInt64 = 0
    private static var lastCompletedProbeID: UInt64 = 0
    private static var lastReportedStalledProbeID: UInt64 = 0
    private static var mainThreadStallCount: Int = 0
    private static var memoryPressureWarningCount: Int = 0
    private static var memoryPressureCriticalCount: Int = 0
    private static var memoryPressureNormalCount: Int = 0
    private static var lastMemoryPressureLevel: String = "normal"
    private static var lastMemoryPressureISO: String = "never"
    private static var highWaterResidentBytes: UInt64 = 0
    private static var highWaterFootprintBytes: UInt64 = 0
    private static var highWaterFDCount: Int = 0
    private static var sessionID: String = ""

    private struct ProcessResourceSnapshot {
        let timestampISO: String
        let reason: String
        let pid: Int32
        let sessionID: String
        let uptimeSeconds: Int
        let residentBytes: UInt64?
        let virtualBytes: UInt64?
        let footprintBytes: UInt64?
        let compressedBytes: UInt64?
        let openFDs: Int?
        let fdLimit: Int?
        let userCPUSeconds: Double?
        let systemCPUSeconds: Double?
        let pageFaults: Int64?
        let pageIns: Int64?
        let memPressureLevel: String
        let memPressureLastISO: String
        let memPressureWarningCount: Int
        let memPressureCriticalCount: Int
        let memPressureNormalCount: Int
        let mainThreadStallCount: Int
        let mainProbeBacklog: UInt64
        let highWaterResidentBytes: UInt64
        let highWaterFootprintBytes: UInt64
        let highWaterFDCount: Int
    }

    // MARK: - Public API

    /// Call once at app launch, before any UI.
    /// Checks for previous crash, installs handlers, writes sentinel.
    static func install() {
        // Ensure logs dir exists
        mkdir(logsDir, 0o755)

        // Pre-allocate C strings for signal handler (must happen before any crash)
        crashFilePathCStr = strdup(crashFilePath)
        breadcrumbPathCStr = strdup(breadcrumbPath)
        heartbeatPathCStr = strdup(heartbeatPath)
        resourceLogPathCStr = strdup(resourceLogPath)
        stderrLogPathCStr = strdup(stderrLogPath)

        // Redirect stderr to a file so Swift runtime messages are captured
        redirectStderr()

        // Check for previous crash before anything else
        checkPreviousCrash()

        // Install signal handlers
        installSignalHandlers()

        // Install NSException handler (for ObjC exceptions that bypass signals)
        NSSetUncaughtExceptionHandler { exception in
            let reason = exception.reason ?? "unknown"
            let name = exception.name.rawValue
            let symbols = exception.callStackSymbols.prefix(15).joined(separator: "\n")
            let msg = "NSException: \(name) — \(reason)\n\(symbols)"
            CrashTelemetry.leave("EXCEPTION: \(msg)")
            // NSException handler is NOT in signal context — safe to use Swift
            CrashTelemetry.writeCrashFileSwift(signalName: "NSException(\(name))")
        }

        // Write session sentinel
        let pid = ProcessInfo.processInfo.processIdentifier
        let now = ISO8601DateFormatter().string(from: Date())
        sessionID = "\(pid)-\(Int(Date().timeIntervalSince1970))"
        monitorQueue.sync {
            nextProbeID = 0
            lastCompletedProbeID = 0
            lastReportedStalledProbeID = 0
            mainThreadStallCount = 0
            memoryPressureWarningCount = 0
            memoryPressureCriticalCount = 0
            memoryPressureNormalCount = 0
            lastMemoryPressureLevel = "normal"
            lastMemoryPressureISO = now
            highWaterResidentBytes = 0
            highWaterFootprintBytes = 0
            highWaterFDCount = 0
        }
        let sentinel = "pid=\(pid)\nsession=\(sessionID)\nstarted=\(now)\n"
        try? sentinel.write(toFile: sessionSentinelPath, atomically: true, encoding: .utf8)

        leave("app-launch")
        appendResourceMarker("session-start pid=\(pid) session=\(sessionID)")
        startRuntimeMonitors()
        logInfo("CrashTelemetry installed — signal handlers active, stderr redirected, breadcrumb trail started")
    }

    /// Call on clean shutdown to remove sentinel
    static func shutdown() {
        leave("app-shutdown-clean")
        monitorQueue.sync {
            writeHeartbeatSnapshot(reason: "shutdown")
            appendResourceMarker("session-end pid=\(ProcessInfo.processInfo.processIdentifier) session=\(sessionID)")
        }
        stopRuntimeMonitors()
        flushBreadcrumbs()
        // Remove sentinel — clean exit
        unlink(sessionSentinelPath)
    }

    /// Thread-safe breadcrumb. Flushed to disk every 5 entries.
    static func leave(_ crumb: String) {
        let ts = timestampString()
        let entry = "[\(ts)] \(crumb)"

        os_unfair_lock_lock(&breadcrumbLock)
        if breadcrumbs.count < maxBreadcrumbs {
            breadcrumbs.append(entry)
        } else {
            breadcrumbs[breadcrumbIndex % maxBreadcrumbs] = entry
        }
        breadcrumbIndex += 1
        let shouldFlush = breadcrumbIndex % 5 == 0
        os_unfair_lock_unlock(&breadcrumbLock)

        if shouldFlush {
            flushBreadcrumbs()
        }
    }

    /// Force flush breadcrumbs to disk right now (thread-safe)
    static func flushBreadcrumbs() {
        os_unfair_lock_lock(&breadcrumbLock)
        let ordered: [String]
        if breadcrumbs.count < maxBreadcrumbs {
            ordered = breadcrumbs
        } else {
            let start = breadcrumbIndex % maxBreadcrumbs
            ordered = Array(breadcrumbs[start...]) + Array(breadcrumbs[..<start])
        }
        os_unfair_lock_unlock(&breadcrumbLock)

        let content = ordered.joined(separator: "\n") + "\n"
        try? content.write(toFile: breadcrumbPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Stderr redirect

    /// Redirect stderr to a log file. Swift runtime's fatalError/preconditionFailure
    /// print to stderr before calling abort(). Even if our signal handler deadlocks,
    /// the Swift error message will be in this file.
    private static func redirectStderr() {
        // Rotate old stderr log
        let fm = FileManager.default
        let oldStderrPath = "\(logsDir)/stderr-prev.log"
        if fm.fileExists(atPath: stderrLogPath) {
            try? fm.removeItem(atPath: oldStderrPath)
            try? fm.moveItem(atPath: stderrLogPath, toPath: oldStderrPath)
        }

        let fd = Darwin.open(stderrLogPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }

        // Write header
        let header = "=== stderr log started at \(ISO8601DateFormatter().string(from: Date())) ===\n"
        header.utf8CString.withUnsafeBufferPointer { buf in
            if buf.count > 1 {
                _ = Darwin.write(fd, buf.baseAddress, buf.count - 1)
            }
        }

        // dup2 redirects stderr (fd 2) to our file
        // Keep a copy of the original stderr for Xcode console (if running under debugger)
        let origStderr = dup(STDERR_FILENO)
        dup2(fd, STDERR_FILENO)
        Darwin.close(fd)

        // Also tee to original stderr if running under a debugger/terminal
        // (using a pipe + reader would be complex, just accept we lose live stderr in release)
        _ = origStderr  // silence unused warning; could be used for tee in future
    }

    // MARK: - Signal handlers

    private static func installSignalHandlers() {
        let signals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGTRAP, SIGFPE, SIGILL]
        for sig in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = signalHandler
            action.sa_flags = 0
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
    }

    /// Async-signal-safe crash handler.
    /// ONLY uses write(), open(), close(), backtrace(), _exit() — NO malloc, NO Swift String ops.
    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        // Open crash file using pre-allocated C string path
        let fd = Darwin.open(crashFilePathCStr, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            // Can't write crash file — just re-raise
            Darwin.signal(sig, SIG_DFL)
            Darwin.raise(sig)
            return
        }

        // Write header using raw C strings only — zero allocation
        writeCStr(fd, "=== NoDraw Crash Report ===\n")
        writeCStr(fd, "signal: ")
        writeCStr(fd, signalNameCStr(sig))
        writeCStr(fd, "\n")

        // Avoid non-signal-safe thread APIs in signal context.
        writeCStr(fd, "thread: unknown\n")

        // Write backtrace (backtrace/backtrace_symbols are signal-safe on Darwin)
        writeCStr(fd, "\n--- backtrace ---\n")
        var callstack = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let frameCount = backtrace(&callstack, Int32(callstack.count))
        if frameCount > 0 {
            // backtrace_symbols_fd writes directly to fd — fully signal-safe
            backtrace_symbols_fd(&callstack, frameCount, fd)
        }

        // Point to breadcrumbs and stderr files
        writeCStr(fd, "\n--- breadcrumbs: ")
        writeCStr(fd, breadcrumbPathCStr)
        writeCStr(fd, " ---\n")

        writeCStr(fd, "--- heartbeat: ")
        writeCStr(fd, heartbeatPathCStr)
        writeCStr(fd, " ---\n")

        writeCStr(fd, "--- resources: ")
        writeCStr(fd, resourceLogPathCStr)
        writeCStr(fd, " ---\n")

        writeCStr(fd, "--- stderr: ")
        writeCStr(fd, stderrLogPathCStr)
        writeCStr(fd, " ---\n")

        Darwin.close(fd)

        // Re-raise to get default crash behavior
        Darwin.signal(sig, SIG_DFL)
        Darwin.raise(sig)
    }

    /// Write crash report from NSException context (NOT a signal handler, safe to use Swift)
    private static func writeCrashFileSwift(signalName: String) {
        flushBreadcrumbs()

        let fd = Darwin.open(crashFilePath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }

        writeSwiftStr(fd, "=== NoDraw Crash Report ===\n")
        writeSwiftStr(fd, "signal: \(signalName)\n")
        writeSwiftStr(fd, "time: \(timestampString())\n")
        writeSwiftStr(fd, "pid: \(ProcessInfo.processInfo.processIdentifier)\n")
        writeSwiftStr(fd, "thread: \(Thread.isMainThread ? "main" : "background")\n")

        writeSwiftStr(fd, "\n--- backtrace ---\n")
        var callstack = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let frameCount = backtrace(&callstack, Int32(callstack.count))
        if frameCount > 0 {
            if let symbols = backtrace_symbols(callstack, frameCount) {
                for i in 0..<Int(frameCount) {
                    if let sym = symbols[i] {
                        let str = String(cString: sym)
                        writeSwiftStr(fd, "\(str)\n")
                    }
                }
                free(symbols)
            }
        }

        writeSwiftStr(fd, "\n--- breadcrumbs: \(breadcrumbPath) ---\n")
        writeSwiftStr(fd, "--- heartbeat: \(heartbeatPath) ---\n")
        writeSwiftStr(fd, "--- resources: \(resourceLogPath) ---\n")
        writeSwiftStr(fd, "--- stderr: \(stderrLogPath) ---\n")
        Darwin.close(fd)
    }

    /// Write a C string literal to fd — async-signal-safe (no allocation)
    private static func writeCStr(_ fd: Int32, _ cStr: UnsafePointer<CChar>) {
        let len = strlen(cStr)
        if len > 0 {
            _ = Darwin.write(fd, cStr, len)
        }
    }

    /// Write a Swift String to fd — NOT signal-safe, only for NSException path
    private static func writeSwiftStr(_ fd: Int32, _ str: String) {
        str.utf8CString.withUnsafeBufferPointer { buf in
            if buf.count > 1 {
                _ = Darwin.write(fd, buf.baseAddress, buf.count - 1)
            }
        }
    }

    // MARK: - Previous crash detection

    private static func checkPreviousCrash() {
        let fm = FileManager.default

        // Check stderr log from previous session for Swift runtime messages
        let prevStderrPath = "\(logsDir)/stderr-prev.log"
        if fm.fileExists(atPath: prevStderrPath),
           let stderr = try? String(contentsOfFile: prevStderrPath, encoding: .utf8),
           stderr.contains("Fatal error") || stderr.contains("Precondition failed") || stderr.contains("assertion failed") {
            logError("=== PREVIOUS SESSION STDERR (runtime crash detected) ===")
            // Show last 30 lines of stderr
            let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines.suffix(30) {
                logError("  \(line)")
            }
        }

        // Check for crash report from signal handler
        if fm.fileExists(atPath: crashFilePath) {
            if let report = try? String(contentsOfFile: crashFilePath, encoding: .utf8) {
                logError("=== PREVIOUS SESSION CRASHED ===")
                for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
                    logError("  \(line)")
                }
            }

            // Also log breadcrumbs
            if fm.fileExists(atPath: breadcrumbPath) {
                if let crumbs = try? String(contentsOfFile: breadcrumbPath, encoding: .utf8) {
                    logError("=== CRASH BREADCRUMBS ===")
                    for line in crumbs.split(separator: "\n", omittingEmptySubsequences: false) {
                        logError("  \(line)")
                    }
                }
            }
            logLastHeartbeat(prefix: "  ")
            logResourceTimelineTail(prefix: "  ")

            // Archive the crash report (keep last 5)
            archiveCrashReport()
            return
        }

        // Check for sentinel without crash report = unclean exit (force quit, power loss, killed)
        if fm.fileExists(atPath: sessionSentinelPath) {
            if let sentinel = try? String(contentsOfFile: sessionSentinelPath, encoding: .utf8) {
                logWarning("=== PREVIOUS SESSION DID NOT EXIT CLEANLY ===")
                logWarning("  sentinel: \(sentinel.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            if fm.fileExists(atPath: breadcrumbPath) {
                if let crumbs = try? String(contentsOfFile: breadcrumbPath, encoding: .utf8) {
                    logWarning("=== LAST BREADCRUMBS ===")
                    for line in crumbs.split(separator: "\n", omittingEmptySubsequences: false) {
                        logWarning("  \(line)")
                    }
                }
            }
            logLastHeartbeat(prefix: "  ")
            logResourceTimelineTail(prefix: "  ")
            // Clean up stale sentinel
            try? fm.removeItem(atPath: sessionSentinelPath)
        }
    }

    // MARK: - Runtime monitor setup

    private static func startRuntimeMonitors() {
        startHeartbeatMonitor()
        startMainThreadStallMonitor()
        startMemoryPressureMonitor()
    }

    private static func stopRuntimeMonitors() {
        monitorQueue.sync {
            heartbeatTimer?.setEventHandler {}
            heartbeatTimer?.cancel()
            heartbeatTimer = nil

            mainThreadProbeTimer?.setEventHandler {}
            mainThreadProbeTimer?.cancel()
            mainThreadProbeTimer = nil

            memoryPressureSource?.setEventHandler {}
            memoryPressureSource?.cancel()
            memoryPressureSource = nil
        }
    }

    private static func startHeartbeatMonitor() {
        monitorQueue.sync {
            heartbeatTimer?.cancel()

            let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
            timer.schedule(deadline: .now(), repeating: heartbeatInterval)
            timer.setEventHandler {
                writeHeartbeatSnapshot(reason: "heartbeat")
            }
            timer.resume()
            heartbeatTimer = timer
        }
    }

    private static func writeHeartbeatSnapshot(reason: String) {
        let snapshot = captureProcessResourceSnapshot(reason: reason)
        writeHeartbeatFile(snapshot)
        appendResourceSnapshot(snapshot)
    }

    private static func startMainThreadStallMonitor() {
        monitorQueue.sync {
            mainThreadProbeTimer?.cancel()
            nextProbeID = 0
            lastCompletedProbeID = 0
            lastReportedStalledProbeID = 0

            let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
            timer.schedule(deadline: .now(), repeating: mainThreadProbeInterval)
            timer.setEventHandler {
                runMainThreadProbe()
            }
            timer.resume()
            mainThreadProbeTimer = timer
        }
    }

    /// Probes main queue responsiveness. If probe isn't acknowledged within threshold,
    /// emit breadcrumb + warning to aid hang/crash triage.
    private static func runMainThreadProbe() {
        nextProbeID &+= 1
        let probeID = nextProbeID

        DispatchQueue.main.async {
            monitorQueue.async {
                if probeID > lastCompletedProbeID {
                    lastCompletedProbeID = probeID
                }
            }
        }

        monitorQueue.asyncAfter(deadline: .now() + mainThreadStallThreshold) {
            guard lastCompletedProbeID < probeID else { return }
            guard lastReportedStalledProbeID < probeID else { return }

            lastReportedStalledProbeID = probeID
            mainThreadStallCount += 1
            let stallSeconds = Int(mainThreadStallThreshold.rounded())
            leave("monitor-main-thread-stall >\(stallSeconds)s probe=\(probeID)")
            flushBreadcrumbs()
            writeHeartbeatSnapshot(reason: "main-thread-stall")
            logWarning("Crash monitor: main thread unresponsive for >\(stallSeconds)s (probe \(probeID))")
        }
    }

    private static func startMemoryPressureMonitor() {
        monitorQueue.sync {
            memoryPressureSource?.cancel()

            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.normal, .warning, .critical],
                queue: monitorQueue
            )

            source.setEventHandler {
                let event = source.data
                if event.contains(.critical) {
                    memoryPressureCriticalCount += 1
                    lastMemoryPressureLevel = "critical"
                    lastMemoryPressureISO = ISO8601DateFormatter().string(from: Date())
                    leave("monitor-memory-pressure critical")
                    flushBreadcrumbs()
                    writeHeartbeatSnapshot(reason: "memory-pressure-critical")
                    logWarning("Crash monitor: system memory pressure CRITICAL")
                } else if event.contains(.warning) {
                    memoryPressureWarningCount += 1
                    lastMemoryPressureLevel = "warning"
                    lastMemoryPressureISO = ISO8601DateFormatter().string(from: Date())
                    leave("monitor-memory-pressure warning")
                    writeHeartbeatSnapshot(reason: "memory-pressure-warning")
                    logWarning("Crash monitor: system memory pressure warning")
                } else if event.contains(.normal) {
                    memoryPressureNormalCount += 1
                    lastMemoryPressureLevel = "normal"
                    lastMemoryPressureISO = ISO8601DateFormatter().string(from: Date())
                    leave("monitor-memory-pressure normal")
                    writeHeartbeatSnapshot(reason: "memory-pressure-normal")
                }
            }

            source.resume()
            memoryPressureSource = source
        }
    }

    private static func captureProcessResourceSnapshot(reason: String) -> ProcessResourceSnapshot {
        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now)
        let pid = ProcessInfo.processInfo.processIdentifier
        let uptimeSeconds = Int(ProcessInfo.processInfo.systemUptime)
        let memoryInfo = currentProcessMemoryInfo()
        let usageInfo = currentRUsageInfo()
        let openFDs = openFileDescriptorCount()
        let fdLimit = openFileDescriptorLimit()

        if let residentBytes = memoryInfo.residentBytes, residentBytes > highWaterResidentBytes {
            highWaterResidentBytes = residentBytes
        }
        if let footprintBytes = memoryInfo.footprintBytes, footprintBytes > highWaterFootprintBytes {
            highWaterFootprintBytes = footprintBytes
        }
        if let openFDs, openFDs > highWaterFDCount {
            highWaterFDCount = openFDs
        }

        let probeBacklog = nextProbeID > lastCompletedProbeID ? (nextProbeID - lastCompletedProbeID) : 0

        return ProcessResourceSnapshot(
            timestampISO: iso,
            reason: reason,
            pid: pid,
            sessionID: sessionID,
            uptimeSeconds: uptimeSeconds,
            residentBytes: memoryInfo.residentBytes,
            virtualBytes: memoryInfo.virtualBytes,
            footprintBytes: memoryInfo.footprintBytes,
            compressedBytes: memoryInfo.compressedBytes,
            openFDs: openFDs,
            fdLimit: fdLimit,
            userCPUSeconds: usageInfo.userCPUSeconds,
            systemCPUSeconds: usageInfo.systemCPUSeconds,
            pageFaults: usageInfo.pageFaults,
            pageIns: usageInfo.pageIns,
            memPressureLevel: lastMemoryPressureLevel,
            memPressureLastISO: lastMemoryPressureISO,
            memPressureWarningCount: memoryPressureWarningCount,
            memPressureCriticalCount: memoryPressureCriticalCount,
            memPressureNormalCount: memoryPressureNormalCount,
            mainThreadStallCount: mainThreadStallCount,
            mainProbeBacklog: probeBacklog,
            highWaterResidentBytes: highWaterResidentBytes,
            highWaterFootprintBytes: highWaterFootprintBytes,
            highWaterFDCount: highWaterFDCount
        )
    }

    private static func writeHeartbeatFile(_ snapshot: ProcessResourceSnapshot) {
        let alerts = resourceAlerts(for: snapshot)
        let content = [
            "pid=\(snapshot.pid)",
            "session=\(snapshot.sessionID)",
            "beat=\(snapshot.timestampISO)",
            "reason=\(snapshot.reason)",
            "uptime=\(snapshot.uptimeSeconds)",
            "mem_pressure_level=\(snapshot.memPressureLevel)",
            "mem_pressure_last=\(snapshot.memPressureLastISO)",
            "mem_pressure_warning_count=\(snapshot.memPressureWarningCount)",
            "mem_pressure_critical_count=\(snapshot.memPressureCriticalCount)",
            "mem_pressure_normal_count=\(snapshot.memPressureNormalCount)",
            "main_stall_count=\(snapshot.mainThreadStallCount)",
            "main_probe_backlog=\(snapshot.mainProbeBacklog)",
            "resident_mb=\(formatMB(snapshot.residentBytes))",
            "footprint_mb=\(formatMB(snapshot.footprintBytes))",
            "compressed_mb=\(formatMB(snapshot.compressedBytes))",
            "virtual_mb=\(formatMB(snapshot.virtualBytes))",
            "resident_hwm_mb=\(formatMB(snapshot.highWaterResidentBytes))",
            "footprint_hwm_mb=\(formatMB(snapshot.highWaterFootprintBytes))",
            "fd_open=\(formatInt(snapshot.openFDs))",
            "fd_limit=\(formatInt(snapshot.fdLimit))",
            "fd_hwm=\(snapshot.highWaterFDCount)",
            "fd_usage_pct=\(formatPercent(percent(snapshot.openFDs, of: snapshot.fdLimit)))",
            "footprint_of_system_mem_pct=\(formatPercent(percent(snapshot.footprintBytes, of: ProcessInfo.processInfo.physicalMemory)))",
            "cpu_user_s=\(formatSeconds(snapshot.userCPUSeconds))",
            "cpu_system_s=\(formatSeconds(snapshot.systemCPUSeconds))",
            "page_faults=\(formatInt64(snapshot.pageFaults))",
            "page_ins=\(formatInt64(snapshot.pageIns))",
            "alerts=\(alerts.isEmpty ? "none" : alerts.joined(separator: ","))",
        ].joined(separator: "\n") + "\n"
        try? content.write(toFile: heartbeatPath, atomically: true, encoding: .utf8)
    }

    private static func appendResourceSnapshot(_ snapshot: ProcessResourceSnapshot) {
        let line = resourceLogLine(from: snapshot)
        appendResourceLogLine(line)
    }

    private static func appendResourceMarker(_ marker: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        appendResourceLogLine("ts=\(ts) marker=\(sanitizeResourceValue(marker))")
    }

    private static func appendResourceLogLine(_ line: String) {
        rotateResourceLogIfNeeded()
        let fd = Darwin.open(resourceLogPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        writeSwiftStr(fd, "\(line)\n")
        Darwin.close(fd)
    }

    private static func rotateResourceLogIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: resourceLogPath),
              let sizeNumber = attrs[.size] as? NSNumber else {
            return
        }

        let size = sizeNumber.uint64Value
        guard size > maxResourceLogBytes else { return }

        guard let content = try? String(contentsOfFile: resourceLogPath, encoding: .utf8) else {
            try? fm.removeItem(atPath: resourceLogPath)
            return
        }

        let tail = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(600)
            .joined(separator: "\n")
        try? (tail + "\n").write(toFile: resourceLogPath, atomically: true, encoding: .utf8)
    }

    private static func resourceLogLine(from snapshot: ProcessResourceSnapshot) -> String {
        let alerts = resourceAlerts(for: snapshot)
        let fields: [String] = [
            "ts=\(snapshot.timestampISO)",
            "session=\(snapshot.sessionID)",
            "reason=\(sanitizeResourceValue(snapshot.reason))",
            "pid=\(snapshot.pid)",
            "uptime=\(snapshot.uptimeSeconds)",
            "mem_level=\(snapshot.memPressureLevel)",
            "mem_last=\(snapshot.memPressureLastISO)",
            "mem_warn=\(snapshot.memPressureWarningCount)",
            "mem_crit=\(snapshot.memPressureCriticalCount)",
            "mem_norm=\(snapshot.memPressureNormalCount)",
            "main_stalls=\(snapshot.mainThreadStallCount)",
            "main_backlog=\(snapshot.mainProbeBacklog)",
            "rss_mb=\(formatMB(snapshot.residentBytes))",
            "footprint_mb=\(formatMB(snapshot.footprintBytes))",
            "compressed_mb=\(formatMB(snapshot.compressedBytes))",
            "vsize_mb=\(formatMB(snapshot.virtualBytes))",
            "rss_hwm_mb=\(formatMB(snapshot.highWaterResidentBytes))",
            "footprint_hwm_mb=\(formatMB(snapshot.highWaterFootprintBytes))",
            "fd_open=\(formatInt(snapshot.openFDs))",
            "fd_limit=\(formatInt(snapshot.fdLimit))",
            "fd_hwm=\(snapshot.highWaterFDCount)",
            "fd_pct=\(formatPercent(percent(snapshot.openFDs, of: snapshot.fdLimit)))",
            "footprint_pct_system=\(formatPercent(percent(snapshot.footprintBytes, of: ProcessInfo.processInfo.physicalMemory)))",
            "cpu_user_s=\(formatSeconds(snapshot.userCPUSeconds))",
            "cpu_sys_s=\(formatSeconds(snapshot.systemCPUSeconds))",
            "faults=\(formatInt64(snapshot.pageFaults))",
            "pageins=\(formatInt64(snapshot.pageIns))",
            "alerts=\(alerts.isEmpty ? "none" : alerts.joined(separator: ","))",
        ]
        return fields.joined(separator: " ")
    }

    private static func resourceAlerts(for snapshot: ProcessResourceSnapshot) -> [String] {
        var alerts: [String] = []

        if snapshot.memPressureCriticalCount > 0 || snapshot.memPressureLevel == "critical" {
            alerts.append("mem-pressure-critical")
        } else if snapshot.memPressureWarningCount > 0 || snapshot.memPressureLevel == "warning" {
            alerts.append("mem-pressure-warning")
        }

        if let fdUsage = percent(snapshot.openFDs, of: snapshot.fdLimit), fdUsage >= 80 {
            alerts.append("fd>=80%")
        }

        if let footprintPct = percent(snapshot.footprintBytes, of: ProcessInfo.processInfo.physicalMemory), footprintPct >= 70 {
            alerts.append("footprint>=70%sysmem")
        }

        if snapshot.mainProbeBacklog > 0 {
            alerts.append("main-probe-backlog")
        }

        return alerts
    }

    private static func parseHeartbeatFields(_ heartbeat: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in heartbeat.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            fields[key] = value
        }
        return fields
    }

    private static func heartbeatResourceDiagnosis(fields: [String: String]) -> String {
        var causes: [String] = []
        if let memLevel = fields["mem_pressure_level"], memLevel == "critical" || memLevel == "warning" {
            causes.append("system-memory-pressure=\(memLevel)")
        }
        if let criticalCount = Int(fields["mem_pressure_critical_count"] ?? ""), criticalCount > 0 {
            causes.append("critical-memory-events=\(criticalCount)")
        }
        if let fdPct = Double(fields["fd_usage_pct"] ?? ""), fdPct >= 80 {
            causes.append("fd-usage=\(Int(fdPct.rounded()))%")
        }
        if let footprintPct = Double(fields["footprint_of_system_mem_pct"] ?? ""), footprintPct >= 70 {
            causes.append("process-footprint=\(Int(footprintPct.rounded()))% of RAM")
        }
        if let backlog = Int(fields["main_probe_backlog"] ?? ""), backlog > 0 {
            causes.append("main-thread-backlog=\(backlog)")
        }
        if causes.isEmpty {
            return "no obvious memory/FD pressure indicators in last heartbeat"
        }
        return causes.joined(separator: ", ")
    }

    private static func logResourceTimelineTail(prefix: String, lines: Int = 80) {
        guard let content = try? String(contentsOfFile: resourceLogPath, encoding: .utf8),
              !content.isEmpty else {
            return
        }

        let tail = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines)
        guard !tail.isEmpty else { return }

        logWarning("=== LAST RESOURCE SNAPSHOTS ===")
        for line in tail {
            logWarning("\(prefix)\(line)")
        }
    }

    private static func currentProcessMemoryInfo() -> (
        residentBytes: UInt64?,
        virtualBytes: UInt64?,
        footprintBytes: UInt64?,
        compressedBytes: UInt64?
    ) {
        var residentBytes: UInt64?
        var virtualBytes: UInt64?
        var footprintBytes: UInt64?
        var compressedBytes: UInt64?

        var basicInfo = mach_task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let basicResult: kern_return_t = withUnsafeMutablePointer(to: &basicInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { intPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPointer, &basicCount)
            }
        }
        if basicResult == KERN_SUCCESS {
            residentBytes = UInt64(basicInfo.resident_size)
            virtualBytes = UInt64(basicInfo.virtual_size)
        }

        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let vmResult: kern_return_t = withUnsafeMutablePointer(to: &vmInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { intPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPointer, &vmCount)
            }
        }
        if vmResult == KERN_SUCCESS {
            footprintBytes = vmInfo.phys_footprint
            compressedBytes = vmInfo.compressed
        }

        return (residentBytes, virtualBytes, footprintBytes, compressedBytes)
    }

    private static func currentRUsageInfo() -> (
        userCPUSeconds: Double?,
        systemCPUSeconds: Double?,
        pageFaults: Int64?,
        pageIns: Int64?
    ) {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return (nil, nil, nil, nil)
        }

        let userCPUSeconds = Double(usage.ru_utime.tv_sec) + (Double(usage.ru_utime.tv_usec) / 1_000_000.0)
        let systemCPUSeconds = Double(usage.ru_stime.tv_sec) + (Double(usage.ru_stime.tv_usec) / 1_000_000.0)
        let pageFaults = Int64(usage.ru_minflt) + Int64(usage.ru_majflt)
        let pageIns = Int64(usage.ru_majflt)

        return (userCPUSeconds, systemCPUSeconds, pageFaults, pageIns)
    }

    private static func openFileDescriptorCount() -> Int? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else {
            return nil
        }
        return entries.count
    }

    private static func openFileDescriptorLimit() -> Int? {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            return nil
        }
        if limit.rlim_cur > rlim_t(Int.max) {
            return nil
        }
        return Int(limit.rlim_cur)
    }

    private static func percent(_ numerator: Int?, of denominator: Int?) -> Double? {
        guard let numerator, let denominator, denominator > 0 else { return nil }
        return (Double(numerator) / Double(denominator)) * 100
    }

    private static func percent(_ numerator: UInt64?, of denominator: UInt64?) -> Double? {
        guard let numerator, let denominator, denominator > 0 else { return nil }
        return (Double(numerator) / Double(denominator)) * 100
    }

    private static func formatMB(_ bytes: UInt64?) -> String {
        guard let bytes else { return "na" }
        return String(format: "%.1f", Double(bytes) / 1_048_576.0)
    }

    private static func formatMB(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576.0)
    }

    private static func formatPercent(_ value: Double?) -> String {
        guard let value else { return "na" }
        return String(format: "%.1f", value)
    }

    private static func formatSeconds(_ value: Double?) -> String {
        guard let value else { return "na" }
        return String(format: "%.2f", value)
    }

    private static func formatInt(_ value: Int?) -> String {
        guard let value else { return "na" }
        return String(value)
    }

    private static func formatInt64(_ value: Int64?) -> String {
        guard let value else { return "na" }
        return String(value)
    }

    private static func sanitizeResourceValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\t", with: "_")
    }

    private static func logLastHeartbeat(prefix: String) {
        guard let heartbeat = try? String(contentsOfFile: heartbeatPath, encoding: .utf8),
              !heartbeat.isEmpty else {
            return
        }

        var beatTimestamp: Date?
        for line in heartbeat.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("beat=") {
                let ts = String(line.dropFirst(5))
                beatTimestamp = ISO8601DateFormatter().date(from: ts)
                break
            }
        }

        let freshness: String
        if let beatTimestamp {
            let ageSeconds = max(0, Int(Date().timeIntervalSince(beatTimestamp)))
            freshness = " (\(ageSeconds)s old)"
        } else {
            freshness = ""
        }

        let compact = heartbeat
            .split(separator: "\n", omittingEmptySubsequences: true)
            .joined(separator: ", ")
        logWarning("\(prefix)last heartbeat: \(compact)\(freshness)")

        let fields = parseHeartbeatFields(heartbeat)
        let diagnosis = heartbeatResourceDiagnosis(fields: fields)
        logWarning("\(prefix)resource diagnosis: \(diagnosis)")
    }

    /// Move crash report to timestamped archive, keep last 5
    private static func archiveCrashReport() {
        let fm = FileManager.default
        let archiveDir = "\(logsDir)/crashes"
        try? fm.createDirectory(atPath: archiveDir, withIntermediateDirectories: true)

        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = "\(archiveDir)/crash-\(ts).txt"

        // Combine report + breadcrumbs + stderr into one archive file
        var content = (try? String(contentsOfFile: crashFilePath, encoding: .utf8)) ?? ""
        if let crumbs = try? String(contentsOfFile: breadcrumbPath, encoding: .utf8) {
            content += "\n\n=== BREADCRUMBS ===\n\(crumbs)"
        }
        if let heartbeat = try? String(contentsOfFile: heartbeatPath, encoding: .utf8),
           !heartbeat.isEmpty {
            content += "\n\n=== LAST HEARTBEAT ===\n\(heartbeat)"
        }
        if let resourceLog = try? String(contentsOfFile: resourceLogPath, encoding: .utf8),
           !resourceLog.isEmpty {
            let resourceLines = resourceLog.split(separator: "\n", omittingEmptySubsequences: false)
            let tail = resourceLines.suffix(120).joined(separator: "\n")
            content += "\n\n=== RESOURCE SNAPSHOTS (tail) ===\n\(tail)"
        }
        let prevStderrPath = "\(logsDir)/stderr-prev.log"
        if let stderr = try? String(contentsOfFile: prevStderrPath, encoding: .utf8),
           !stderr.isEmpty {
            // Include last 50 lines of stderr
            let stderrLines = stderr.split(separator: "\n", omittingEmptySubsequences: false)
            let tail = stderrLines.suffix(50).joined(separator: "\n")
            content += "\n\n=== STDERR ===\n\(tail)"
        }
        try? content.write(toFile: dest, atomically: true, encoding: .utf8)

        // Remove current crash file
        try? fm.removeItem(atPath: crashFilePath)

        // Prune old archives (keep last 5)
        if let files = try? fm.contentsOfDirectory(atPath: archiveDir)
            .filter({ $0.hasPrefix("crash-") })
            .sorted() {
            if files.count > 5 {
                for old in files.prefix(files.count - 5) {
                    try? fm.removeItem(atPath: "\(archiveDir)/\(old)")
                }
            }
        }
    }

    // MARK: - Helpers

    private static func timestampString() -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: now)
    }
}

// MARK: - Signal-safe C string helpers

/// Returns a static C string for signal name — no allocation
private func signalNameCStr(_ sig: Int32) -> UnsafePointer<CChar> {
    switch sig {
    case SIGSEGV: return staticCStr("SIGSEGV")
    case SIGABRT: return staticCStr("SIGABRT")
    case SIGBUS:  return staticCStr("SIGBUS")
    case SIGTRAP: return staticCStr("SIGTRAP")
    case SIGFPE:  return staticCStr("SIGFPE")
    case SIGILL:  return staticCStr("SIGILL")
    default:      return staticCStr("SIG_UNKNOWN")
    }
}

/// Helper to get a pointer to a StaticString's UTF8 buffer
private func staticCStr(_ s: StaticString) -> UnsafePointer<CChar> {
    return UnsafeRawPointer(s.utf8Start).assumingMemoryBound(to: CChar.self)
}
