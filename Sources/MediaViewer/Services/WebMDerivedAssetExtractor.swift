import Darwin
import Foundation

enum WebMDerivedAssetExtractionError: LocalizedError, Sendable {
    case sourceMissing(URL)
    case unsupportedSource(URL)
    case ffmpegUnavailable
    case launchFailed(operation: String, message: String)
    case timedOut(operation: String, seconds: TimeInterval)
    case processFailed(operation: String, exitCode: Int32, diagnostic: String)
    case invalidDuration(URL)
    case missingStream(kind: String, source: URL)
    case outputMissing(operation: String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let url):
            return "WebM source file not found: \(url.lastPathComponent)"
        case .unsupportedSource(let url):
            return "WebM extraction requires a .webm source: \(url.lastPathComponent)"
        case .ffmpegUnavailable:
            return "ffmpeg is required to analyze WebM media"
        case .launchFailed(let operation, let message):
            return "WebM \(operation) could not start its media tool: \(message)"
        case .timedOut(let operation, let seconds):
            return "WebM \(operation) timed out after \(Int(seconds.rounded())) seconds"
        case .processFailed(let operation, let exitCode, let diagnostic):
            return "WebM \(operation) failed (tool exit \(exitCode)): \(diagnostic)"
        case .invalidDuration(let url):
            return "Could not determine WebM duration: \(url.lastPathComponent)"
        case .missingStream(let kind, let source):
            return "WebM source has no \(kind) stream: \(source.lastPathComponent)"
        case .outputMissing(let operation):
            return "WebM \(operation) did not produce a usable temporary asset"
        }
    }
}

/// Source-timeline metadata shared by transcription and video-understanding.
/// ffmpeg normalizes derived WAV/MOV timestamps to zero, so callers use these
/// offsets to put analysis results back on the original WebM timeline.
struct WebMStreamInfo: Sendable, Equatable {
    let hasAudio: Bool
    let hasVideo: Bool
    let audioStartTime: Double?
    let videoStartTime: Double?
    let formatStartTime: Double?
    let formatDuration: Double?
    let usedFFprobe: Bool

    var audioTimelineOffset: Double {
        Self.normalizedOffset(audioStartTime ?? formatStartTime)
    }

    var videoTimelineOffset: Double {
        Self.normalizedOffset(videoStartTime ?? formatStartTime)
    }

    private static func normalizedOffset(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return max(0, value)
    }
}

struct WebMTimelineMapping: Sendable, Equatable {
    let sourceStartTime: Double
    let sourceDuration: Double

    func sourceTime(forDerivedTime time: Double) -> Double {
        guard time.isFinite else { return sourceStartTime }
        return max(0, sourceStartTime + time)
    }
}

/// A short-lived, AVFoundation-readable asset derived from WebM media.
///
/// Callers should invoke `cleanup()` as soon as the consumer finishes. The
/// deinitializer is a fallback so failures cannot strand large PCM/video files.
final class WebMTemporaryDerivedAsset: @unchecked Sendable {
    let url: URL
    let workingDirectory: URL
    let sourceTimelineOffset: Double

    private let lock = NSLock()
    private var cleanedUp = false

    init(url: URL, workingDirectory: URL, sourceTimelineOffset: Double = 0) {
        self.url = url
        self.workingDirectory = workingDirectory
        self.sourceTimelineOffset = sourceTimelineOffset
    }

    func cleanup() {
        lock.lock()
        guard !cleanedUp else {
            lock.unlock()
            return
        }
        cleanedUp = true
        lock.unlock()

        try? FileManager.default.removeItem(at: workingDirectory)
    }

    deinit {
        cleanup()
    }
}

struct WebMSampledVideoAsset: Sendable {
    let temporaryAsset: WebMTemporaryDerivedAsset
    let timelineMapping: WebMTimelineMapping
    let framesPerSecond: Double
    let frameLimit: Int

    var url: URL { temporaryAsset.url }
    var workingDirectory: URL { temporaryAsset.workingDirectory }
    var sourceDuration: Double { timelineMapping.sourceDuration }
    var sourceTimelineOffset: Double { timelineMapping.sourceStartTime }

    func cleanup() {
        temporaryAsset.cleanup()
    }
}

/// Converts only the portions of WebM needed by AVFoundation-only analysis.
/// Audio becomes mono 16 kHz signed-16-bit PCM. Visual analysis gets a bounded
/// MJPEG/MOV proxy sampled at the requested cadence with at most 60 frames.
struct WebMDerivedAssetExtractor: Sendable {
    struct Configuration: Sendable {
        let audioTimeout: TimeInterval
        let streamProbeTimeout: TimeInterval
        let durationProbeTimeout: TimeInterval
        let videoTimeout: TimeInterval
        let terminationGrace: TimeInterval
        let frameLimit: Int
        let maximumVideoDimension: Int

        init(
            audioTimeout: TimeInterval = 300,
            streamProbeTimeout: TimeInterval = 15,
            durationProbeTimeout: TimeInterval = 15,
            videoTimeout: TimeInterval = 300,
            terminationGrace: TimeInterval = 0.5,
            frameLimit: Int = 60,
            maximumVideoDimension: Int = 1280
        ) {
            self.audioTimeout = max(0.01, audioTimeout)
            self.streamProbeTimeout = max(0.01, streamProbeTimeout)
            self.durationProbeTimeout = max(0.01, durationProbeTimeout)
            self.videoTimeout = max(0.01, videoTimeout)
            self.terminationGrace = max(0.01, terminationGrace)
            self.frameLimit = min(60, max(1, frameLimit))
            self.maximumVideoDimension = max(64, maximumVideoDimension)
        }
    }

    private let ffmpegURL: URL?
    private let ffprobeURL: URL?
    private let temporaryRoot: URL
    private let configuration: Configuration

    init(
        ffmpegURL: URL? = DependencyManager.executableURL(named: "ffmpeg"),
        ffprobeURL: URL? = DependencyManager.executableURL(named: "ffprobe"),
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        configuration: Configuration = Configuration()
    ) {
        self.ffmpegURL = ffmpegURL
        self.ffprobeURL = ffprobeURL
        self.temporaryRoot = temporaryRoot
        self.configuration = configuration
    }

    func probeStreams(in sourceURL: URL) async throws -> WebMStreamInfo {
        let context = try prepareExtraction(for: sourceURL, operation: "stream probe")
        defer { try? FileManager.default.removeItem(at: context.workingDirectory) }
        return try await probeStreams(
            in: sourceURL,
            ffmpegURL: context.ffmpegURL,
            logDirectory: context.workingDirectory
        )
    }

    func extractTranscriptionAudio(
        from sourceURL: URL,
        streamInfo suppliedStreamInfo: WebMStreamInfo? = nil
    ) async throws -> WebMTemporaryDerivedAsset {
        let context = try prepareExtraction(for: sourceURL, operation: "audio extraction")
        var keepWorkingDirectory = false
        defer {
            if !keepWorkingDirectory {
                try? FileManager.default.removeItem(at: context.workingDirectory)
            }
        }

        let streamInfo: WebMStreamInfo
        if let suppliedStreamInfo {
            streamInfo = suppliedStreamInfo
        } else {
            streamInfo = try await probeStreams(
                in: sourceURL,
                ffmpegURL: context.ffmpegURL,
                logDirectory: context.workingDirectory
            )
        }
        guard streamInfo.hasAudio else {
            throw WebMDerivedAssetExtractionError.missingStream(kind: "audio", source: sourceURL)
        }

        let outputURL = context.workingDirectory.appendingPathComponent("transcription.wav")
        _ = try await runFFmpeg(
            executableURL: context.ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-y",
                "-i", sourceURL.path,
                "-map", "0:a:0",
                "-vn",
                "-sn",
                "-dn",
                "-ac", "1",
                "-ar", "16000",
                "-c:a", "pcm_s16le",
                "-f", "wav",
                outputURL.path
            ],
            timeout: configuration.audioTimeout,
            operation: "audio extraction",
            logURL: context.workingDirectory.appendingPathComponent("audio-ffmpeg.log")
        )
        try validateOutput(at: outputURL, operation: "audio extraction")

        keepWorkingDirectory = true
        return WebMTemporaryDerivedAsset(
            url: outputURL,
            workingDirectory: context.workingDirectory,
            sourceTimelineOffset: streamInfo.audioTimelineOffset
        )
    }

    func extractSampledVideo(
        from sourceURL: URL,
        streamInfo suppliedStreamInfo: WebMStreamInfo? = nil,
        samplingFramesPerSecond: @Sendable (Double) -> Double
    ) async throws -> WebMSampledVideoAsset {
        let context = try prepareExtraction(for: sourceURL, operation: "video frame extraction")
        var keepWorkingDirectory = false
        defer {
            if !keepWorkingDirectory {
                try? FileManager.default.removeItem(at: context.workingDirectory)
            }
        }

        let streamInfo: WebMStreamInfo
        if let suppliedStreamInfo {
            streamInfo = suppliedStreamInfo
        } else {
            streamInfo = try await probeStreams(
                in: sourceURL,
                ffmpegURL: context.ffmpegURL,
                logDirectory: context.workingDirectory
            )
        }
        guard streamInfo.hasVideo else {
            throw WebMDerivedAssetExtractionError.missingStream(kind: "video", source: sourceURL)
        }
        guard let sourceDuration = streamInfo.formatDuration,
              sourceDuration.isFinite,
              sourceDuration > 0 else {
            throw WebMDerivedAssetExtractionError.invalidDuration(sourceURL)
        }

        let requestedFramesPerSecond = samplingFramesPerSecond(sourceDuration)
        let requestedFPS = requestedFramesPerSecond.isFinite && requestedFramesPerSecond > 0
            ? requestedFramesPerSecond
            : 0.2
        let maximumFPS = Double(configuration.frameLimit) / sourceDuration
        let effectiveFPS = max(0.001, min(requestedFPS, maximumFPS))
        let dimension = configuration.maximumVideoDimension
        let filter = "fps=\(effectiveFPS),scale='min(\(dimension),iw)':'min(\(dimension),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"
        let outputURL = context.workingDirectory.appendingPathComponent("sampled-frames.mov")

        _ = try await runFFmpeg(
            executableURL: context.ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-y",
                "-i", sourceURL.path,
                "-map", "0:v:0",
                "-vf", filter,
                "-frames:v", String(configuration.frameLimit),
                "-an",
                "-sn",
                "-dn",
                "-c:v", "mjpeg",
                "-q:v", "3",
                "-pix_fmt", "yuvj420p",
                "-f", "mov",
                outputURL.path
            ],
            timeout: configuration.videoTimeout,
            operation: "video frame extraction",
            logURL: context.workingDirectory.appendingPathComponent("video-ffmpeg.log")
        )
        try validateOutput(at: outputURL, operation: "video frame extraction")

        keepWorkingDirectory = true
        let temporaryAsset = WebMTemporaryDerivedAsset(
            url: outputURL,
            workingDirectory: context.workingDirectory,
            sourceTimelineOffset: streamInfo.videoTimelineOffset
        )
        return WebMSampledVideoAsset(
            temporaryAsset: temporaryAsset,
            timelineMapping: WebMTimelineMapping(
                sourceStartTime: streamInfo.videoTimelineOffset,
                sourceDuration: sourceDuration
            ),
            framesPerSecond: effectiveFPS,
            frameLimit: configuration.frameLimit
        )
    }

    static func parseDuration(fromFFmpegOutput output: String) -> Double? {
        let pattern = #"Duration:\s*([0-9]+):([0-9]{2}):([0-9]{2}(?:\.[0-9]+)?)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..., in: output)
              ),
              match.numberOfRanges == 4,
              let hoursRange = Range(match.range(at: 1), in: output),
              let minutesRange = Range(match.range(at: 2), in: output),
              let secondsRange = Range(match.range(at: 3), in: output),
              let hours = Double(output[hoursRange]),
              let minutes = Double(output[minutesRange]),
              let seconds = Double(output[secondsRange]) else {
            return nil
        }

        return (hours * 3600) + (minutes * 60) + seconds
    }

    static func parseStartTime(fromFFmpegOutput output: String) -> Double? {
        let pattern = #"start:\s*(-?[0-9]+(?:\.[0-9]+)?)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..., in: output)
              ),
              match.numberOfRanges == 2,
              let valueRange = Range(match.range(at: 1), in: output),
              let value = Double(output[valueRange]),
              value.isFinite else {
            return nil
        }
        return value
    }

    static func parseStreamStartTime(
        kind: String,
        fromFFmpegOutput output: String
    ) -> Double? {
        let escapedKind = NSRegularExpression.escapedPattern(for: kind)
        let pattern = #"(?mi)^\s*Stream\s+#[^\r\n]*\b"#
            + escapedKind
            + #":[^\r\n]*\bstart\s+(-?[0-9]+(?:\.[0-9]+)?)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..., in: output)
              ),
              match.numberOfRanges == 2,
              let valueRange = Range(match.range(at: 1), in: output),
              let value = Double(output[valueRange]),
              value.isFinite else {
            return nil
        }
        return value
    }

    private func probeStreams(
        in sourceURL: URL,
        ffmpegURL: URL,
        logDirectory: URL
    ) async throws -> WebMStreamInfo {
        if let resolvedFFprobeURL = resolvedFFprobeURL(beside: ffmpegURL) {
            do {
                let output = try await runFFmpeg(
                    executableURL: resolvedFFprobeURL,
                    arguments: [
                        "-v", "error",
                        "-show_entries", "stream=codec_type,start_time:format=start_time,duration",
                        "-of", "json",
                        sourceURL.path
                    ],
                    timeout: configuration.streamProbeTimeout,
                    operation: "stream probe",
                    logURL: logDirectory.appendingPathComponent("stream-ffprobe.log")
                )
                if let info = Self.parseFFprobeStreamInfo(output) {
                    return info
                }
                logWarning("WebM stream probe returned unreadable metadata for \(sourceURL.lastPathComponent); falling back to ffmpeg")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                logWarning("WebM ffprobe failed for \(sourceURL.lastPathComponent): \(error.localizedDescription); falling back to ffmpeg")
            }
        } else {
            logWarning("ffprobe is unavailable for \(sourceURL.lastPathComponent); using ffmpeg stream metadata fallback")
        }

        let output = try await runFFmpeg(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-nostdin",
                "-i", sourceURL.path,
                "-map", "0:v:0?",
                "-map", "0:a:0?",
                "-t", "0.001",
                "-f", "null",
                "-"
            ],
            timeout: configuration.durationProbeTimeout,
            operation: "stream probe fallback",
            logURL: logDirectory.appendingPathComponent("stream-ffmpeg.log")
        )
        let formatStart = Self.parseStartTime(fromFFmpegOutput: output)
        let hasAudio = output.range(of: "Audio:", options: .caseInsensitive) != nil
        let hasVideo = output.range(of: "Video:", options: .caseInsensitive) != nil
        return WebMStreamInfo(
            hasAudio: hasAudio,
            hasVideo: hasVideo,
            audioStartTime: hasAudio
                ? Self.parseStreamStartTime(kind: "Audio", fromFFmpegOutput: output) ?? formatStart
                : nil,
            videoStartTime: hasVideo
                ? Self.parseStreamStartTime(kind: "Video", fromFFmpegOutput: output) ?? formatStart
                : nil,
            formatStartTime: formatStart,
            formatDuration: Self.parseDuration(fromFFmpegOutput: output),
            usedFFprobe: false
        )
    }

    private func resolvedFFprobeURL(beside ffmpegURL: URL) -> URL? {
        let candidates = [
            ffprobeURL,
            ffmpegURL.deletingLastPathComponent().appendingPathComponent("ffprobe"),
            DependencyManager.executableURL(named: "ffprobe")
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static func parseFFprobeStreamInfo(_ output: String) -> WebMStreamInfo? {
        guard let data = output.data(using: .utf8),
              let document = try? JSONDecoder().decode(FFprobeDocument.self, from: data) else {
            return nil
        }

        let audio = document.streams.first { $0.codecType == "audio" }
        let video = document.streams.first { $0.codecType == "video" }
        return WebMStreamInfo(
            hasAudio: audio != nil,
            hasVideo: video != nil,
            audioStartTime: audio?.startTime.flatMap(parseFiniteDouble),
            videoStartTime: video?.startTime.flatMap(parseFiniteDouble),
            formatStartTime: document.format?.startTime.flatMap(parseFiniteDouble),
            formatDuration: document.format?.duration.flatMap(parseFiniteDouble),
            usedFFprobe: true
        )
    }

    private static func parseFiniteDouble(_ string: String) -> Double? {
        guard let value = Double(string), value.isFinite else { return nil }
        return value
    }

    private struct FFprobeDocument: Decodable {
        struct Stream: Decodable {
            let codecType: String
            let startTime: String?

            enum CodingKeys: String, CodingKey {
                case codecType = "codec_type"
                case startTime = "start_time"
            }
        }

        struct Format: Decodable {
            let startTime: String?
            let duration: String?

            enum CodingKeys: String, CodingKey {
                case startTime = "start_time"
                case duration
            }
        }

        let streams: [Stream]
        let format: Format?
    }

    private func prepareExtraction(
        for sourceURL: URL,
        operation: String
    ) throws -> (ffmpegURL: URL, workingDirectory: URL) {
        guard sourceURL.pathExtension.lowercased() == "webm" else {
            throw WebMDerivedAssetExtractionError.unsupportedSource(sourceURL)
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw WebMDerivedAssetExtractionError.sourceMissing(sourceURL)
        }
        let resolvedFFmpegURL: URL?
        if let ffmpegURL,
           FileManager.default.isExecutableFile(atPath: ffmpegURL.path) {
            resolvedFFmpegURL = ffmpegURL
        } else {
            // Queues live for the app session, so re-resolve here in case ffmpeg
            // was installed from Settings after a queue was initialized.
            resolvedFFmpegURL = DependencyManager.executableURL(named: "ffmpeg")
        }
        guard let resolvedFFmpegURL,
              FileManager.default.isExecutableFile(atPath: resolvedFFmpegURL.path) else {
            throw WebMDerivedAssetExtractionError.ffmpegUnavailable
        }

        let workingDirectory = temporaryRoot.appendingPathComponent(
            "nodraw-webm-\(operation.replacingOccurrences(of: " ", with: "-"))-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        return (resolvedFFmpegURL, workingDirectory)
    }

    private func validateOutput(at url: URL, operation: String) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw WebMDerivedAssetExtractionError.outputMissing(operation: operation)
        }
    }

    private func runFFmpeg(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        operation: String,
        logURL: URL
    ) async throws -> String {
        try Data().write(to: logURL, options: .atomic)
        let logHandle = try FileHandle(forWritingTo: logURL)
        var logHandleIsOpen = true
        defer {
            if logHandleIsOpen {
                try? logHandle.close()
            }
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = logHandle
        process.standardError = logHandle

        let termination = FFmpegTerminationSignal()
        let managedProcess = ManagedFFmpegProcess(
            process: process,
            terminationGrace: configuration.terminationGrace
        )
        process.terminationHandler = { finishedProcess in
            managedProcess.markExited()
            termination.finish(status: finishedProcess.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            managedProcess.markExited()
            throw WebMDerivedAssetExtractionError.launchFailed(
                operation: operation,
                message: error.localizedDescription
            )
        }

        let status: Int32
        do {
            status = try await Self.waitForTermination(
                signal: termination,
                process: managedProcess,
                timeout: timeout,
                operation: operation
            )
        } catch {
            managedProcess.requestStop()
            throw error
        }

        try? logHandle.synchronize()
        try? logHandle.close()
        logHandleIsOpen = false
        let outputData = (try? Data(contentsOf: logURL)) ?? Data()
        let output = String(decoding: outputData, as: UTF8.self)

        guard status == 0 else {
            let diagnostic = Self.conciseDiagnostic(from: output)
            throw WebMDerivedAssetExtractionError.processFailed(
                operation: operation,
                exitCode: status,
                diagnostic: diagnostic
            )
        }
        return output
    }

    private static func waitForTermination(
        signal: FFmpegTerminationSignal,
        process: ManagedFFmpegProcess,
        timeout: TimeInterval,
        operation: String
    ) async throws -> Int32 {
        try await withTaskCancellationHandler {
            return try await withThrowingTaskGroup(of: FFmpegProcessRaceResult.self) { group in
                group.addTask {
                    .exited(await signal.wait())
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return .deadlineReached
                }

                do {
                    guard let result = try await group.next() else {
                        throw CancellationError()
                    }
                    switch result {
                    case .exited(let status):
                        group.cancelAll()
                        try Task.checkCancellation()
                        return status
                    case .deadlineReached:
                        process.requestStop()
                        group.cancelAll()
                        throw WebMDerivedAssetExtractionError.timedOut(
                            operation: operation,
                            seconds: timeout
                        )
                    }
                } catch {
                    process.requestStop()
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            process.requestStop()
        }
    }

    private static func conciseDiagnostic(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No diagnostic output" }
        return String(trimmed.suffix(2_000))
    }
}

/// A single cooperative lane shared by transcription and video understanding.
/// Both queues can start together during archive scan; serializing the complete
/// WebM derive-and-analyze section avoids two ffmpeg decoders (and their
/// downstream analyzers) competing with interactive library work.
actor WebMBackgroundWorkCoordinator {
    static let shared = WebMBackgroundWorkCoordinator()

    private struct Lease: Sendable, Equatable {
        let id: UUID
        let sourcePath: String
    }

    private struct Waiter {
        let id: UUID
        let sourcePath: String
        let continuation: CheckedContinuation<Lease, Error>
    }

    private var activeLease: Lease?
    private var waiters: [Waiter] = []

    func withExclusiveAccess<T: Sendable>(
        to sourceURL: URL,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let lease = try await acquire(sourceURL: sourceURL)
        defer { release(lease) }
        try Task.checkCancellation()
        return try await operation()
    }

    func snapshot() -> (isActive: Bool, waiting: Int) {
        (activeLease != nil, waiters.count)
    }

    private func acquire(sourceURL: URL) async throws -> Lease {
        try Task.checkCancellation()
        let id = UUID()
        let sourcePath = sourceURL.standardizedFileURL.path

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let lease = Lease(id: id, sourcePath: sourcePath)
                if activeLease == nil {
                    activeLease = lease
                    continuation.resume(returning: lease)
                } else {
                    waiters.append(
                        Waiter(id: id, sourcePath: sourcePath, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ lease: Lease) {
        guard activeLease == lease else { return }
        activeLease = nil

        guard !waiters.isEmpty else { return }
        let waiter = waiters.removeFirst()
        let nextLease = Lease(id: waiter.id, sourcePath: waiter.sourcePath)
        activeLease = nextLease
        waiter.continuation.resume(returning: nextLease)
    }
}

private enum FFmpegProcessRaceResult: Sendable {
    case exited(Int32)
    case deadlineReached
}

private final class FFmpegTerminationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish(status: Int32) {
        lock.lock()
        guard self.status == nil else {
            lock.unlock()
            return
        }
        self.status = status
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()

        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }
}

private final class ManagedFFmpegProcess: @unchecked Sendable {
    // Retain the process until its termination callback fires. Queue task
    // cancellation can otherwise race local async suspension and lose the only
    // reliable handle for terminating a busy decoder.
    private var process: Process?
    private let terminationGrace: TimeInterval
    private let lock = NSLock()
    private var didExit = false
    private var stopRequested = false

    init(process: Process, terminationGrace: TimeInterval) {
        self.process = process
        self.terminationGrace = terminationGrace
    }

    func markExited() {
        lock.lock()
        didExit = true
        process = nil
        lock.unlock()
    }

    func requestStop() {
        lock.lock()
        guard !didExit, !stopRequested, let process else {
            lock.unlock()
            return
        }
        stopRequested = true
        lock.unlock()

        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminationGrace) { [self] in
            forceStopIfNeeded()
        }
    }

    private func forceStopIfNeeded() {
        lock.lock()
        guard !didExit, let process else {
            lock.unlock()
            return
        }
        let processIdentifier = process.processIdentifier
        lock.unlock()

        if processIdentifier > 0, process.isRunning {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }
}
