import Foundation
import os.signpost

/// Opt-in monotonic startup records; no file writes, scheduling or work changes.
/// `first_viewport_cell` is layout availability, while `first_thumbnail_ready`
/// separately records rendered-image availability (neither claims window focus).
enum StartupMetrics {
    private static let enabled = ProcessInfo.processInfo.environment["NODRAW_STARTUP_METRICS"] == "1"
    private static let origin = DispatchTime.now().uptimeNanoseconds
    private static let lock = NSLock()
    private static var emitted = Set<String>()

    static func begin() -> UInt64 {
        guard enabled else { return 0 }
        _ = origin
        return DispatchTime.now().uptimeNanoseconds
    }

    static func end(_ stage: String, since start: UInt64, once: Bool = false, count: Int? = nil) {
        guard enabled, start != 0 else { return }
        emit(stage, duration: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, once: once, count: count)
    }

    static func mark(_ stage: String, count: Int? = nil) {
        guard enabled else { return }
        emit(stage, duration: nil, once: true, count: count)
    }

    private static func emit(_ stage: String, duration: Double?, once: Bool, count: Int?) {
        lock.lock()
        defer { lock.unlock() }
        if once, !emitted.insert(stage).inserted { return }
        let reference = origin
        var record: [String: Any] = ["stage": stage,
            "elapsed_ms": Double(DispatchTime.now().uptimeNanoseconds - reference) / 1_000_000,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "maintenance_suppressed": BackgroundQAConfiguration.isEnabled]
        if let duration { record["duration_ms"] = duration }
        if let count { record["count"] = count }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(Data("[STARTUP] ".utf8) + data + Data("\n".utf8))
    }
}

// MARK: - Performance Profiling

/// Performance profiling using os_signpost for Instruments tracing.
/// Use these to measure critical code paths and identify bottlenecks.
///
/// To view in Instruments:
/// 1. Run the app with Instruments (Product > Profile)
/// 2. Choose "os_signpost" or "Time Profiler" template
/// 3. Look for the "Performance" category under subsystem "com.nodraw.app"
enum PerformanceLog {
    /// Main performance log for signpost events
    static let log = OSLog(subsystem: "com.nodraw.app", category: "Performance")

    /// Log for image loading/caching operations
    static let imageLog = OSLog(subsystem: "com.nodraw.app", category: "ImageLoading")

    /// Log for database/fetch operations
    static let dataLog = OSLog(subsystem: "com.nodraw.app", category: "DataFetch")

    /// Log for UI interactions (clicks, context menus)
    static let interactionLog = OSLog(subsystem: "com.nodraw.app", category: "Interaction")

    // MARK: - Interval Measurement (begin/end pairs)

    /// Begin a named interval. Must be paired with end().
    /// - Parameters:
    ///   - name: Static string name for the interval (shows in Instruments)
    ///   - log: Which log category to use (default: Performance)
    ///   - id: Signpost ID for correlating begin/end (default: exclusive)
    static func begin(_ name: StaticString, log: OSLog = log, id: OSSignpostID = .exclusive) {
        os_signpost(.begin, log: log, name: name, signpostID: id)
    }

    /// End a named interval. Must match a previous begin().
    static func end(_ name: StaticString, log: OSLog = log, id: OSSignpostID = .exclusive) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }

    /// Begin with metadata string (shows in Instruments hover)
    static func begin(_ name: StaticString, log: OSLog = log, id: OSSignpostID = .exclusive, _ format: StaticString, _ arg: String) {
        os_signpost(.begin, log: log, name: name, signpostID: id, format, arg)
    }

    /// End with metadata string
    static func end(_ name: StaticString, log: OSLog = log, id: OSSignpostID = .exclusive, _ format: StaticString, _ arg: String) {
        os_signpost(.end, log: log, name: name, signpostID: id, format, arg)
    }

    // MARK: - Point Events

    /// Log a single point event (no duration)
    static func event(_ name: StaticString, log: OSLog = log, _ message: String = "") {
        if message.isEmpty {
            os_signpost(.event, log: log, name: name)
        } else {
            os_signpost(.event, log: log, name: name, "%{public}s", message)
        }
    }

    // MARK: - Scoped Measurement

    /// Measure a synchronous block of code. Returns the block's result.
    /// Usage: `let result = PerformanceLog.measure("operation") { doWork() }`
    @discardableResult
    static func measure<T>(_ name: StaticString, log: OSLog = log, _ block: () throws -> T) rethrows -> T {
        begin(name, log: log)
        defer { end(name, log: log) }
        return try block()
    }

    /// Measure an async block of code. Returns the block's result.
    /// Usage: `let result = await PerformanceLog.measureAsync("operation") { await doWork() }`
    @discardableResult
    static func measureAsync<T>(_ name: StaticString, log: OSLog = log, _ block: () async throws -> T) async rethrows -> T {
        begin(name, log: log)
        defer { end(name, log: log) }
        return try await block()
    }
}

// MARK: - Signpost ID Generation

extension OSSignpostID {
    /// Create a signpost ID from an object for tracking concurrent operations
    static func from(_ object: AnyObject) -> OSSignpostID {
        OSSignpostID(log: PerformanceLog.log, object: object)
    }

}

// MARK: - PerfLog (Real-time Console Performance Logging)

/// Real-time performance logging with threshold-based warnings.
/// Outputs to console for live monitoring during development.
///
/// Output format:
/// ```
/// [14:32:15.123] [PERF/DATA] fetchItems: 45.2ms | search:art, starred
/// [14:32:16.500] [PERF/DATA] ⚠️ SLOW fetchItems: 234.5ms (threshold: 100ms) | heavy query
/// ```
enum PerfLog {
    // MARK: - Categories with Thresholds

    /// Performance category with associated threshold (ms)
    enum Category: String, CaseIterable {
        case layout = "LAYOUT"      // Grid column calculations, width changes
        case image = "IMAGE"        // Cache hits/misses, thumbnail generation
        case data = "DATA"          // Database queries, filters
        case view = "VIEW"          // Focus view transitions
        case interact = "INTERACT"  // Selection, navigation, clicks
        case scroll = "SCROLL"      // Scroll/resize events

        /// Threshold in milliseconds - operations exceeding this are flagged
        var threshold: Double {
            switch self {
            case .layout: return 16
            case .image: return 50
            case .data: return 100
            case .view: return 250
            case .interact: return 16
            case .scroll: return 8
            }
        }

        /// UserDefaults key for per-category enable/disable
        var enabledKey: String {
            "perfLog_\(rawValue.lowercased())_enabled"
        }

        /// Check if this category is enabled
        var isEnabled: Bool {
            get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
            nonmutating set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
        }

        var displayName: String {
            switch self {
            case .layout: return "Layout"
            case .image: return "Image"
            case .data: return "Data"
            case .view: return "View"
            case .interact: return "Interact"
            case .scroll: return "Scroll"
            }
        }
    }

    // MARK: - Verbosity Levels

    /// Logging verbosity level
    enum Level: Int, CaseIterable {
        case off = 0       // No output
        case slow = 1      // Only operations exceeding threshold
        case normal = 2    // All timed operations
        case verbose = 3   // Everything including point events

        var displayName: String {
            switch self {
            case .off: return "Off"
            case .slow: return "Slow Only"
            case .normal: return "Normal"
            case .verbose: return "Verbose"
            }
        }
    }

    // MARK: - Token for Begin/End Tracking

    /// Token returned by begin() to track operation timing
    struct PerfToken {
        let name: String
        let category: Category
        let context: String?
        let startTime: CFAbsoluteTime
        fileprivate init(name: String, category: Category, context: String?, startTime: CFAbsoluteTime) {
            self.name = name
            self.category = category
            self.context = context
            self.startTime = startTime
        }
    }

    // MARK: - Current Level

    private static let levelKey = "perfLogLevel"

    /// Current verbosity level (persisted to UserDefaults)
    static var level: Level {
        get {
            let rawValue = UserDefaults.standard.integer(forKey: levelKey)
            return Level(rawValue: rawValue) ?? .off
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: levelKey)
        }
    }

    // MARK: - Date Formatter

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func timestamp() -> String {
        timeFormatter.string(from: Date())
    }

    // MARK: - Begin/End API

    /// Begin a timed operation. Returns a token to pass to end().
    /// - Parameters:
    ///   - name: Operation name (e.g., "fetchItems")
    ///   - category: Performance category
    ///   - context: Optional context string (e.g., "search:art, starred")
    @inlinable
    static func begin(_ name: String, category: Category, context: String? = nil) -> PerfToken {
        PerfToken(name: name, category: category, context: context, startTime: CFAbsoluteTimeGetCurrent())
    }

    /// End a timed operation and log if appropriate.
    /// - Parameter token: Token from begin()
    @inlinable
    static func end(_ token: PerfToken) {
        let elapsed = (CFAbsoluteTimeGetCurrent() - token.startTime) * 1000
        logTimed(name: token.name, category: token.category, elapsed: elapsed, context: token.context)
    }

    // MARK: - Scoped Measurement

    /// Measure a synchronous block. Returns the block's result.
    @inlinable
    @discardableResult
    static func measure<T>(
        _ name: String,
        category: Category,
        context: String? = nil,
        _ block: () throws -> T
    ) rethrows -> T {
        let token = begin(name, category: category, context: context)
        defer { end(token) }
        return try block()
    }

    /// Measure an async block. Returns the block's result.
    @inlinable
    @discardableResult
    static func measureAsync<T>(
        _ name: String,
        category: Category,
        context: String? = nil,
        _ block: () async throws -> T
    ) async rethrows -> T {
        let token = begin(name, category: category, context: context)
        defer { end(token) }
        return try await block()
    }

    // MARK: - Point Events

    /// Log a point event (no duration).
    /// Only logged at verbose level.
    static func event(_ name: String, category: Category, context: String? = nil) {
        guard level == .verbose && category.isEnabled else { return }

        let contextStr = context.map { " | \($0)" } ?? ""
        logDebug("[\(timestamp())] [PERF/\(category.rawValue)] \(name)\(contextStr)")
    }

    // MARK: - Cache Result Logging

    /// Log a cache hit/miss event with timing.
    static func cacheResult(
        _ name: String,
        hit: Bool,
        source: String? = nil,
        elapsed: Double? = nil
    ) {
        guard level.rawValue >= Level.normal.rawValue && Category.image.isEnabled else { return }

        let status = hit ? "HIT" : "MISS"
        let sourceStr = source.map { " (\($0))" } ?? ""
        let timeStr = elapsed.map { String(format: " %.1fms", $0) } ?? ""
        logDebug("[\(timestamp())] [PERF/IMAGE] \(name): \(status)\(sourceStr)\(timeStr)")
    }

    // MARK: - Internal Logging

    private static func logTimed(name: String, category: Category, elapsed: Double, context: String?) {
        guard level != .off && category.isEnabled else { return }

        let isSlow = elapsed > category.threshold

        // At .slow level, only log if slow
        if level == .slow && !isSlow { return }

        let contextStr = context.map { " | \($0)" } ?? ""

        if isSlow {
            logWarning("[\(timestamp())] [PERF/\(category.rawValue)] SLOW \(name): \(String(format: "%.1f", elapsed))ms (threshold: \(Int(category.threshold))ms)\(contextStr)")
        } else {
            logDebug("[\(timestamp())] [PERF/\(category.rawValue)] \(name): \(String(format: "%.1f", elapsed))ms\(contextStr)")
        }
    }
}
