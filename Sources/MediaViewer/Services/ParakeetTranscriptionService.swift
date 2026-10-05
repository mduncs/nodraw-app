import AVFoundation
import FluidAudio
import Foundation

struct ParakeetTranscriptionResult: Sendable {
    let text: String
    let confidence: Double
    let duration: Double
    let tokens: [TranscriptToken]
    let language: String?
    let model: String
}

struct ParakeetResourceDiagnostics: Sendable {
    let modelLoaded: Bool
    let activeTranscriptions: Int
    let managerLoadCount: Int
    let unloadCount: Int
}

private enum ParakeetTranscriptionError: LocalizedError {
    case unsupportedMedia(String)
    case exportSessionUnavailable(String)
    case audioExportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedMedia(let filename):
            return "Unsupported media for Parakeet transcription: \(filename)"
        case .exportSessionUnavailable(let filename):
            return "Could not prepare video audio for transcription: \(filename)"
        case .audioExportFailed(let message):
            return "Audio extraction failed: \(message)"
        }
    }
}

actor ParakeetTranscriptionService {
    private let modelVersion: AsrModelVersion
    private var manager: AsrManager?
    private var loadedModelName: String?
    private let idleUnloadDelay: Duration
    private let managerLoader: (@Sendable () async throws -> AsrManager)?
    private let transcriptionOperation: (@Sendable (AsrManager, URL) async throws -> ParakeetTranscriptionResult)?
    private var managerLoadingTask: Task<AsrManager, Error>?
    private var cleanupTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?
    private var idleUnloadGeneration = 0
    private var activeTranscriptions = 0
    private var releaseWhenIdle = false
    private var managerLoadCount = 0
    private var unloadCount = 0

    init(
        modelVersion: AsrModelVersion = .v3,
        idleUnloadDelay: Duration = .seconds(30),
        managerLoader: (@Sendable () async throws -> AsrManager)? = nil,
        transcriptionOperation: (@Sendable (AsrManager, URL) async throws -> ParakeetTranscriptionResult)? = nil
    ) {
        self.modelVersion = modelVersion
        self.idleUnloadDelay = idleUnloadDelay
        self.managerLoader = managerLoader ?? {
            let models: AsrModels
            if try await AsrModels.isModelValid(version: modelVersion) {
                models = try await AsrModels.loadFromCache(version: modelVersion)
            } else {
                models = try await AsrModels.downloadAndLoad(version: modelVersion)
            }
            return AsrManager(config: Self.managerConfiguration(), models: models)
        }
        self.transcriptionOperation = transcriptionOperation
    }

    /// Cache-only callers load models explicitly and cannot enter automatic
    /// download/recovery. Taking the models also prevents a version mismatch.
    /// Supply a reload factory to allow idle unloading of these isolated models.
    init(
        preloadedModels: AsrModels,
        idleUnloadDelay: Duration = .seconds(30),
        reloadManager: (@Sendable () async throws -> AsrManager)? = nil
    ) {
        modelVersion = preloadedModels.version
        self.idleUnloadDelay = idleUnloadDelay
        managerLoader = reloadManager
        transcriptionOperation = nil
        manager = AsrManager(config: Self.managerConfiguration(), models: preloadedModels)
        loadedModelName = Self.modelName(for: preloadedModels.version)
        managerLoadCount = 1
        Task { [weak self] in await self?.scheduleIdleUnload() }
    }

    deinit {
        idleUnloadTask?.cancel()
    }

    func resourceDiagnostics() -> ParakeetResourceDiagnostics {
        ParakeetResourceDiagnostics(
            modelLoaded: manager != nil,
            activeTranscriptions: activeTranscriptions,
            managerLoadCount: managerLoadCount,
            unloadCount: unloadCount
        )
    }

    /// A pressure request waits for every reentrant call to finish before touching the manager.
    func releaseIdleResources() async {
        cancelIdleUnload()
        guard managerLoader != nil else { return }
        guard activeTranscriptions == 0 else {
            releaseWhenIdle = true
            return
        }
        releaseWhenIdle = false
        if let cleanupTask {
            await cleanupTask.value
            return
        }
        guard let oldManager = manager else { return }
        manager = nil
        loadedModelName = nil
        unloadCount += 1
        let cleanup = Task { await oldManager.cleanup() }
        cleanupTask = cleanup
        await cleanup.value
        cleanupTask = nil
    }

    private func cancelIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        idleUnloadGeneration &+= 1
    }

    private func scheduleIdleUnload() {
        guard activeTranscriptions == 0, manager != nil, managerLoader != nil else { return }
        cancelIdleUnload()
        let generation = idleUnloadGeneration
        let delay = releaseWhenIdle ? Duration.zero : idleUnloadDelay
        idleUnloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.unloadIfStillIdle(generation: generation)
        }
    }

    private func unloadIfStillIdle(generation: Int) async {
        guard generation == idleUnloadGeneration, activeTranscriptions == 0 else { return }
        await releaseIdleResources()
    }

    func transcribe(sourceURL: URL) async throws -> ParakeetTranscriptionResult {
        guard !BackgroundQAConfiguration.isEnabled else { throw BackgroundQAConfiguration.ConfigurationError.maintenanceSuppressed }
        cancelIdleUnload()
        activeTranscriptions += 1
        defer {
            activeTranscriptions -= 1
            scheduleIdleUnload()
        }
        let ext = sourceURL.pathExtension.lowercased()
        if TranscriptionQueue.isAudioExtension(ext) {
            return try await transcribeAudioFile(sourceURL)
        }

        if TranscriptionQueue.isVideoExtension(ext) {
            let asset = AVURLAsset(url: sourceURL)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                return ParakeetTranscriptionResult(
                    text: "",
                    confidence: 0,
                    duration: Self.duration(for: asset),
                    tokens: [],
                    language: nil,
                    model: Self.modelName(for: modelVersion)
                )
            }

            let audioURL = try await exportAudioTrack(from: asset, sourceURL: sourceURL)
            defer { try? FileManager.default.removeItem(at: audioURL) }
            return try await transcribeAudioFile(audioURL)
        }

        throw ParakeetTranscriptionError.unsupportedMedia(sourceURL.lastPathComponent)
    }

    private func transcribeAudioFile(_ url: URL) async throws -> ParakeetTranscriptionResult {
        let asrManager = try await ensureManager()
        if let transcriptionOperation {
            return try await transcriptionOperation(asrManager, url)
        }
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(url, decoderState: &decoderState)
        let tokens = (result.tokenTimings ?? []).map {
            TranscriptToken(
                token: $0.token,
                startTime: $0.startTime,
                endTime: $0.endTime,
                confidence: Double($0.confidence)
            )
        }

        return ParakeetTranscriptionResult(
            text: result.text,
            confidence: Double(result.confidence),
            duration: result.duration,
            tokens: tokens,
            language: nil,
            model: Self.modelName(for: modelVersion)
        )
    }

    private func ensureManager() async throws -> AsrManager {
        if let cleanupTask {
            await cleanupTask.value
        }
        let modelName = Self.modelName(for: modelVersion)
        if let manager, loadedModelName == modelName {
            return manager
        }

        if let managerLoadingTask {
            return try await managerLoadingTask.value
        }
        guard let managerLoader else {
            preconditionFailure("A preloaded manager must be retained without a reload factory")
        }
        let loading = Task { try await managerLoader() }
        managerLoadingTask = loading
        do {
            let asrManager = try await loading.value
            manager = asrManager
            loadedModelName = modelName
            managerLoadCount += 1
            managerLoadingTask = nil
            return asrManager
        } catch {
            managerLoadingTask = nil
            throw error
        }
    }

    private static func managerConfiguration() -> ASRConfig {
        ASRConfig(
            parallelChunkConcurrency: 1,
            streamingEnabled: true,
            streamingThreshold: 480_000
        )
    }

    private func exportAudioTrack(from asset: AVURLAsset, sourceURL: URL) async throws -> URL {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ParakeetTranscriptionError.exportSessionUnavailable(sourceURL.lastPathComponent)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodraw-parakeet-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: outputURL)

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    let message = exportSession.error?.localizedDescription ?? exportSession.status.description
                    continuation.resume(throwing: ParakeetTranscriptionError.audioExportFailed(message))
                default:
                    continuation.resume(throwing: ParakeetTranscriptionError.audioExportFailed(exportSession.status.description))
                }
            }
        }

        return outputURL
    }

    private static func duration(for asset: AVAsset) -> Double {
        let duration = CMTimeGetSeconds(asset.duration)
        return duration.isFinite && duration > 0 ? duration : 0
    }

    private static func modelName(for version: AsrModelVersion) -> String {
        switch version {
        case .v2:
            return "parakeet-tdt-0.6b-v2"
        case .v3:
            return "parakeet-tdt-0.6b-v3"
        case .tdtCtc110m:
            return "parakeet-tdt-ctc-110m"
        case .ctcZhCn:
            return "parakeet-ctc-zh-cn"
        case .tdtJa:
            return "parakeet-tdt-ja"
        }
    }
}

private extension AVAssetExportSession.Status {
    var description: String {
        switch self {
        case .unknown:
            return "unknown"
        case .waiting:
            return "waiting"
        case .exporting:
            return "exporting"
        case .completed:
            return "completed"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        @unknown default:
            return "unknown"
        }
    }
}
