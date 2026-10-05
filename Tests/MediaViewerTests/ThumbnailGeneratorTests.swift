import XCTest
import AppKit
import AVFoundation
@testable import MediaViewer

final class ThumbnailGeneratorTests: XCTestCase {
    func testCancellingOneSharedImageWaiterDoesNotCancelProducer() async {
        let broker = SharedImageLoadBroker()
        let probe = SharedImageLoadProbe()
        let key = "shared-thumbnail"

        let first = Task {
            await broker.value(for: key) { await probe.produce() }
        }
        let firstStarted = await probe.waitForStarts(1)
        XCTAssertTrue(firstStarted)

        let second = Task {
            await broker.value(for: key) { await probe.produce() }
        }
        let bothRegistered = await waitForWaiterCount(2, key: key, broker: broker)
        XCTAssertTrue(bothRegistered)

        first.cancel()
        let cancelledWaiterReleased = await waitForWaiterCount(1, key: key, broker: broker)
        XCTAssertTrue(cancelledWaiterReleased)
        await probe.finish()

        let firstResult = await first.value
        let secondResult = await second.value
        let snapshot = await probe.snapshot()
        XCTAssertNil(firstResult)
        XCTAssertNotNil(secondResult)
        XCTAssertEqual(snapshot.starts, 1)
        XCTAssertEqual(snapshot.cancellations, 0)
    }

    func testCancellingLastSharedImageWaiterCancelsProducer() async {
        let broker = SharedImageLoadBroker()
        let probe = SharedImageLoadProbe()
        let key = "abandoned-thumbnail"

        let waiter = Task {
            await broker.value(for: key) { await probe.produce() }
        }
        let producerStarted = await probe.waitForStarts(1)
        XCTAssertTrue(producerStarted)

        waiter.cancel()
        let result = await waiter.value
        let producerCancelled = await probe.waitForCancellations(1)
        let waiterCount = await broker.waiterCount(for: key)
        XCTAssertNil(result)
        XCTAssertTrue(producerCancelled)
        XCTAssertEqual(waiterCount, 0)
    }

    func testThumbnailFailureSuppressionIsSourceKeyedAndResettable() {
        var suppression = ImageLoadFailureSuppression()
        let itemID = UUID()
        let firstSource = "\(itemID.uuidString)|sm|/archive/first.png"
        let secondSource = "\(itemID.uuidString)|sm|/archive/second.png"

        XCTAssertTrue(suppression.shouldAttempt(firstSource))
        XCTAssertTrue(suppression.recordFailure(firstSource))
        XCTAssertFalse(suppression.recordFailure(firstSource))
        XCTAssertFalse(suppression.shouldAttempt(firstSource))
        XCTAssertTrue(suppression.shouldAttempt(secondSource))

        suppression.invalidate(itemID: itemID)
        XCTAssertTrue(suppression.shouldAttempt(firstSource))

        _ = suppression.recordFailure(secondSource)
        suppression.invalidate(sourceURL: URL(fileURLWithPath: "/archive/second.png"))
        XCTAssertTrue(suppression.shouldAttempt(secondSource))
    }

    func testThumbnailFailureSuppressionExpiresAtTTLBoundary() {
        var suppression = ImageLoadFailureSuppression(
            maximumEntryCount: 8,
            timeToLive: 5
        )
        let key = "missing|sm|/archive/gone.png"

        XCTAssertTrue(suppression.recordFailure(key, now: 100))
        XCTAssertFalse(suppression.shouldAttempt(key, now: 104.999))
        XCTAssertTrue(suppression.shouldAttempt(key, now: 105))
        XCTAssertEqual(suppression.entryCount, 0)

        XCTAssertTrue(suppression.recordFailure(key, now: 105))
        XCTAssertFalse(suppression.recordFailure(key, now: 105))
        XCTAssertFalse(suppression.shouldAttempt(key, now: 105))
    }

    func testThumbnailFailureSuppressionStaysBoundedUnderUniqueFailureStress() {
        let limit = 64
        var suppression = ImageLoadFailureSuppression(
            maximumEntryCount: limit,
            timeToLive: 10_000
        )

        for index in 0..<10_000 {
            XCTAssertTrue(suppression.recordFailure("missing-\(index)", now: 100))
        }

        XCTAssertEqual(suppression.entryCount, limit)
        XCTAssertTrue(suppression.shouldAttempt("missing-0", now: 101))
        XCTAssertFalse(suppression.shouldAttempt("missing-9999", now: 101))
        XCTAssertEqual(suppression.entryCount, limit)
    }

    private func waitForWaiterCount(
        _ expectedCount: Int,
        key: String,
        broker: SharedImageLoadBroker
    ) async -> Bool {
        for _ in 0..<100 {
            if await broker.waiterCount(for: key) == expectedCount { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await broker.waiterCount(for: key) == expectedCount
    }

    func testContextThumbnailVariantHasDistinctPersistentPath() {
        let itemID = UUID()
        let legacy = ThumbnailGenerator.thumbnailPath(for: itemID, size: .small)
        let context = ThumbnailGenerator.thumbnailPath(
            for: itemID,
            size: .small,
            variant: "context-abc123"
        )

        XCTAssertNotEqual(legacy, context)
        XCTAssertEqual(legacy.lastPathComponent, "\(itemID.uuidString)-sm.jpg")
        XCTAssertTrue(context.lastPathComponent.contains("-context-abc123-sm.jpg"))
    }

    func testVideoPreviewPreloadPolicyDeduplicatesAndBoundsSources() {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let sources = [
            VideoPreviewSource(itemId: firstID, url: URL(fileURLWithPath: "/one.mp4")),
            VideoPreviewSource(itemId: firstID, url: URL(fileURLWithPath: "/duplicate.mp4")),
            VideoPreviewSource(itemId: secondID, url: URL(fileURLWithPath: "/two.mp4")),
            VideoPreviewSource(itemId: thirdID, url: URL(fileURLWithPath: "/three.mp4"))
        ]

        let result = VideoPreviewPreloadPolicy.boundedUniqueSources(sources, limit: 2)

        XCTAssertEqual(result.map(\.itemId), [firstID, secondID])
        XCTAssertEqual(result.map(\.url.lastPathComponent), ["one.mp4", "two.mp4"])
    }

    func testEquivalentVideoPreviewPreloadRequestsRunOnce() async {
        let recorder = VideoPreviewPreloadRecorder()
        let first = VideoPreviewSource(itemId: UUID(), url: URL(fileURLWithPath: "/one.mp4"))
        let second = VideoPreviewSource(itemId: UUID(), url: URL(fileURLWithPath: "/two.mp4"))
        let overflow = VideoPreviewSource(itemId: UUID(), url: URL(fileURLWithPath: "/three.mp4"))
        let preloader = VideoPreviewPreloader(
            maxItemsPerPass: 2,
            debounce: .milliseconds(5),
            throttle: .zero,
            hasCachedFrames: { _ in false },
            generateFrames: { source in
                await recorder.record(source)
            }
        )

        await preloader.schedule(sources: [first, second, overflow])
        await preloader.schedule(sources: [first, second, overflow])
        try? await Task.sleep(for: .milliseconds(80))

        let metrics = await preloader.metricsSnapshot()
        let generatedIDs = await recorder.generatedIDs
        XCTAssertEqual(generatedIDs, [first.itemId, second.itemId])
        XCTAssertEqual(metrics.scheduledRequests, 2)
        XCTAssertEqual(metrics.deduplicatedRequests, 1)
        XCTAssertEqual(metrics.startedBatches, 1)
        XCTAssertEqual(metrics.completedBatches, 1)
        XCTAssertEqual(metrics.generatedItems, 2)
    }

    func testChangedVideoPreviewPreloadRequestCancelsSupersededBatch() async {
        let recorder = VideoPreviewPreloadRecorder(generationDelay: .milliseconds(100))
        let first = VideoPreviewSource(itemId: UUID(), url: URL(fileURLWithPath: "/one.mp4"))
        let second = VideoPreviewSource(itemId: UUID(), url: URL(fileURLWithPath: "/two.mp4"))
        let preloader = VideoPreviewPreloader(
            maxItemsPerPass: 1,
            debounce: .milliseconds(5),
            throttle: .zero,
            hasCachedFrames: { _ in false },
            generateFrames: { source in
                await recorder.record(source)
            }
        )

        await preloader.schedule(sources: [first])
        let firstDidStart = await recorder.waitForGeneratedCount(1)
        XCTAssertTrue(firstDidStart)
        await preloader.schedule(sources: [second])
        try? await Task.sleep(for: .milliseconds(180))

        let metrics = await preloader.metricsSnapshot()
        let attemptedIDs = await recorder.generatedIDs
        XCTAssertEqual(attemptedIDs, [first.itemId, second.itemId])
        XCTAssertEqual(metrics.cancelledRequests, 1)
        XCTAssertEqual(metrics.startedBatches, 2)
        XCTAssertEqual(metrics.completedBatches, 1)
        XCTAssertEqual(metrics.generatedItems, 1)
    }

    func testWebMIsSupportedVideoForThumbnailGeneration() {
        let url = URL(fileURLWithPath: "/archive/clip.webm")

        XCTAssertTrue(ThumbnailGenerator.isSupported(url))
        XCTAssertTrue(ThumbnailGenerator.isVideo(url))
    }

    func testGenerateWebMThumbnailWhenFFmpegIsAvailable() throws {
        guard let ffmpegURL = DependencyManager.executableURL(named: "ffmpeg") else {
            throw XCTSkip("ffmpeg is not installed")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailGeneratorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let webmURL = tempDir.appendingPathComponent("sample.webm")
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-f", "lavfi",
            "-i", "testsrc=size=64x64:duration=1:rate=1",
            "-c:v", "libvpx",
            "-pix_fmt", "yuv420p",
            webmURL.path
        ]
        process.standardError = Pipe()
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw XCTSkip("ffmpeg cannot encode the WebM smoke fixture")
        }

        let thumbnail = ThumbnailGenerator.generateVideoThumbnail(from: webmURL, size: .small)
        XCTAssertNotNil(thumbnail)
        XCTAssertGreaterThan(thumbnail?.size.width ?? 0, 0)
        XCTAssertGreaterThan(thumbnail?.size.height ?? 0, 0)
    }

    func testShortSingleKeyframeVideoUsesInteriorThumbnailAndPreviewFrames() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoURL = tempDir.appendingPathComponent("short-single-keyframe.mp4")
        try makeH264Fixture(at: videoURL, includesInteriorContent: true)

        let syncSampleTimes = try syncSampleTimes(in: videoURL)
        XCTAssertEqual(syncSampleTimes.count, 1, "The regression fixture must have one H.264 keyframe")
        XCTAssertEqual(syncSampleTimes.first ?? -1, 0, accuracy: 0.001)

        let openingFrame = try exactFrame(from: videoURL, seconds: 0)
        let interiorFrame = try exactFrame(from: videoURL, seconds: 0.5)
        XCTAssertTrue(ThumbnailGenerator.isLikelyDarkFrame(openingFrame))
        XCTAssertFalse(ThumbnailGenerator.isLikelyDarkFrame(interiorFrame))

        let thumbnail = try XCTUnwrap(
            ThumbnailGenerator.generateVideoThumbnail(from: videoURL, size: .small)
        )
        XCTAssertFalse(
            ThumbnailGenerator.isLikelyDarkFrame(thumbnail),
            "Interior thumbnail probes must not collapse to the dark opening keyframe"
        )

        let itemId = UUID()
        let frameCount = ThumbnailGenerator.dynamicFrameCount(forDuration: 1)
        defer {
            for index in 0..<frameCount {
                try? FileManager.default.removeItem(
                    at: ThumbnailGenerator.previewFramePath(for: itemId, frameIndex: index)
                )
            }
        }

        var previewFrames: [NSImage] = []
        ThumbnailGenerator.generateProgressivePreviewFrames(from: videoURL, itemId: itemId) { frames, isComplete in
            if isComplete {
                previewFrames = frames
            }
        }

        XCTAssertEqual(previewFrames.count, frameCount)
        XCTAssertTrue(
            previewFrames.contains { !ThumbnailGenerator.isLikelyDarkFrame($0) },
            "Progressive preview requests must not collapse to frame zero"
        )
    }

    func testSingleFrameVideoFallsBackToFrameZero() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoURL = tempDir.appendingPathComponent("single-frame.mp4")
        try makeH264Fixture(at: videoURL, includesInteriorContent: false)

        let thumbnail = try XCTUnwrap(
            ThumbnailGenerator.generateVideoThumbnail(from: videoURL, size: .small)
        )
        XCTAssertTrue(
            ThumbnailGenerator.isLikelyDarkFrame(thumbnail),
            "A source without an interior sample should still return its frame-zero fallback"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailGeneratorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Builds an approximately one-second H.264 GOP with its only keyframe at t=0.
    /// The multi-frame variant starts black, then switches to white after one frame.
    private func makeH264Fixture(at outputURL: URL, includesInteriorContent: Bool) throws {
        guard let ffmpegURL = DependencyManager.executableURL(named: "ffmpeg") else {
            throw XCTSkip("ffmpeg is required to encode the synthetic H.264 regression fixture")
        }

        let sourceFilter: String
        if includesInteriorContent {
            sourceFilter = "color=c=black:s=64x64:r=30:d=1,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='gte(t,0.033)'"
        } else {
            sourceFilter = "color=c=black:s=64x64:r=1:d=1"
        }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-f", "lavfi",
            "-i", sourceFilter,
            "-an",
            "-c:v", "libx264",
            "-preset", "ultrafast",
            "-g", "300",
            "-keyint_min", "300",
            "-sc_threshold", "0",
            "-x264-params", "keyint=300:min-keyint=300:scenecut=0",
            "-bf", "0",
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            outputURL.path
        ]
        process.standardError = Pipe()
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw XCTSkip("ffmpeg cannot encode the synthetic H.264 regression fixture")
        }
    }

    private func syncSampleTimes(in source: URL) throws -> [Double] {
        let asset = AVURLAsset(url: source)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        try XCTSkipUnless(reader.canAdd(output), "AVAssetReader cannot inspect the H.264 fixture")
        reader.add(output)
        try XCTSkipUnless(reader.startReading(), "AVAssetReader cannot read the H.264 fixture")

        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }

            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample,
                createIfNecessary: false
            ) as? [NSDictionary]
            let isNotSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? NSNumber)?.boolValue ?? false
            if !isNotSync {
                times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
        }
        return times
    }

    private func exactFrame(from source: URL, seconds: Double) throws -> NSImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var actualTime = CMTime.invalid
        let image = try generator.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 600),
            actualTime: &actualTime
        )
        XCTAssertTrue(actualTime.isValid)
        XCTAssertTrue(actualTime.isNumeric)
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }
}

private actor SharedImageLoadProbe {
    private var starts = 0
    private var cancellations = 0
    private var isFinished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func produce() async -> NSImage? {
        starts += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isFinished {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelProducer() }
        }
        guard !Task.isCancelled else { return nil }
        return NSImage(size: NSSize(width: 1, height: 1))
    }

    func finish() {
        isFinished = true
        continuation?.resume()
        continuation = nil
    }

    func waitForStarts(_ expected: Int) async -> Bool {
        for _ in 0..<100 {
            if starts >= expected { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return starts >= expected
    }

    func waitForCancellations(_ expected: Int) async -> Bool {
        for _ in 0..<100 {
            if cancellations >= expected { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return cancellations >= expected
    }

    func snapshot() -> (starts: Int, cancellations: Int) {
        (starts, cancellations)
    }

    private func cancelProducer() {
        cancellations += 1
        finish()
    }
}

private actor VideoPreviewPreloadRecorder {
    private(set) var generatedIDs: [UUID] = []
    private let generationDelay: Duration

    init(generationDelay: Duration = .zero) {
        self.generationDelay = generationDelay
    }

    func record(_ source: VideoPreviewSource) async -> Bool {
        generatedIDs.append(source.itemId)
        do {
            try await Task.sleep(for: generationDelay)
        } catch {
            return false
        }
        return !Task.isCancelled
    }

    func waitForGeneratedCount(_ count: Int) async -> Bool {
        for _ in 0..<100 {
            if generatedIDs.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return generatedIDs.count >= count
    }
}
