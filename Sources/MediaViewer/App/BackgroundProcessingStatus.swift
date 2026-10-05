import Combine
import Foundation

/// Display-only progress stays out of AppState's library-wide change publisher.
@MainActor
final class BackgroundProcessingStatus: ObservableObject {
    struct ThumbnailProgress: Equatable {
        let completed: Int
        let total: Int
    }

    struct Snapshot: Equatable {
        var processingCount = 0
        var queuedCount = 0
        var pipelineProcessingCount = 0
        var pipelineQueuedCount = 0
        var videoUnderstandingProcessingCount = 0
        var videoUnderstandingQueuedCount = 0
        var transcriptionProcessingCount = 0
        var transcriptionQueuedCount = 0
        var processingRate: Double = 0
        var thumbnailProgress: ThumbnailProgress?

        var overallProcessingCount: Int {
            processingCount + pipelineProcessingCount + videoUnderstandingProcessingCount + transcriptionProcessingCount
        }
        var overallQueuedCount: Int {
            queuedCount + pipelineQueuedCount + videoUnderstandingQueuedCount + transcriptionQueuedCount
        }
    }

    @Published private(set) var snapshot = Snapshot()
    private var pending = Snapshot()
    private var displayTask: Task<Void, Never>?
    private var processingStartTime: Date?
    private var initialQueueCount = 0

    var processingCount: Int { snapshot.processingCount }
    var queuedCount: Int { snapshot.queuedCount }
    var pipelineProcessingCount: Int { snapshot.pipelineProcessingCount }
    var pipelineQueuedCount: Int { snapshot.pipelineQueuedCount }
    var videoUnderstandingProcessingCount: Int { snapshot.videoUnderstandingProcessingCount }
    var videoUnderstandingQueuedCount: Int { snapshot.videoUnderstandingQueuedCount }
    var transcriptionProcessingCount: Int { snapshot.transcriptionProcessingCount }
    var transcriptionQueuedCount: Int { snapshot.transcriptionQueuedCount }
    var overallProcessingCount: Int { snapshot.overallProcessingCount }
    var overallQueuedCount: Int { snapshot.overallQueuedCount }
    var processingRate: Double { snapshot.processingRate }
    var thumbnailRegenerationProgress: (completed: Int, total: Int)? {
        snapshot.thumbnailProgress.map { ($0.completed, $0.total) }
    }

    func updateQueueStatus(_ queue: AppState.BackgroundQueue, processing: Int, queued: Int) {
        let previous = pending
        switch queue {
        case .vision:
            pending.processingCount = processing
            pending.queuedCount = queued
        case .pipeline:
            pending.pipelineProcessingCount = processing
            pending.pipelineQueuedCount = queued
        case .videoUnderstanding:
            pending.videoUnderstandingProcessingCount = processing
            pending.videoUnderstandingQueuedCount = queued
        case .transcription:
            pending.transcriptionProcessingCount = processing
            pending.transcriptionQueuedCount = queued
        }
        guard pending != previous else { return }
        updateCombinedQueueMetrics()
        scheduleDisplayUpdate()
    }

    func updateThumbnailRegenerationProgress(_ progress: (completed: Int, total: Int)?) {
        let value = progress.map { ThumbnailProgress(completed: $0.completed, total: $0.total) }
        guard pending.thumbnailProgress != value else { return }
        pending.thumbnailProgress = value
        scheduleDisplayUpdate()
    }

    private func updateCombinedQueueMetrics() {
        let totalRemaining = pending.overallProcessingCount + pending.overallQueuedCount
        if totalRemaining > 0 && processingStartTime == nil {
            processingStartTime = Date()
            initialQueueCount = totalRemaining
        } else if totalRemaining == 0 {
            processingStartTime = nil
            initialQueueCount = 0
            pending.processingRate = 0
        } else if let startTime = processingStartTime {
            initialQueueCount = max(initialQueueCount, totalRemaining)
            let elapsed = Date().timeIntervalSince(startTime)
            let processed = initialQueueCount - totalRemaining
            if elapsed > 0.5 && processed > 0 {
                pending.processingRate = Double(processed) / elapsed
            }
        }
    }

    private func scheduleDisplayUpdate() {
        guard displayTask == nil, pending != snapshot else { return }
        displayTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return }
            guard let self else { return }
            self.displayTask = nil
            guard self.snapshot != self.pending else { return }
            self.snapshot = self.pending
        }
    }
}
