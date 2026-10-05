import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreImage
import Darwin

// MARK: - ThumbnailGenerator

/// Generates thumbnails from images using CGImageSource for memory-efficient loading.
/// Never loads full resolution into memory - uses downsampling at decode time.
struct ThumbnailGenerator {

    /// Thumbnail size tiers matching ADR-003
    enum Size: String, Sendable {
        case small = "sm"   // 400px - masonry grid (2x for retina)
        case medium = "md"  // 800px - hover preview / larger tiles

        var maxPixelDimension: Int {
            switch self {
            case .small: return 400
            case .medium: return 800
            }
        }
    }

    /// Supported image formats
    private static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp"
    ]

    /// Supported video formats
    private static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "avi", "mkv"
    ]

    /// Coalesces background video preview preloading into a single cancellable task.
    private static let videoPreviewPreloader = VideoPreviewPreloader()

    /// Check if a file is a supported media format (image or video)
    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedImageExtensions.contains(ext) || supportedVideoExtensions.contains(ext)
    }

    /// Check if a file is a video
    static func isVideo(_ url: URL) -> Bool {
        supportedVideoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Shared context for fast average-luminance checks.
    private static let luminanceContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull()
    ])

    /// Returns true if a frame is likely just a black/near-black slate.
    private static func isLikelyDarkFrame(_ cgImage: CGImage, threshold: CGFloat = 0.06) -> Bool {
        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        guard !extent.isEmpty,
              let filter = CIFilter(name: "CIAreaAverage") else {
            return false
        }

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)

        guard let output = filter.outputImage else {
            return false
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        luminanceContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        let red = CGFloat(pixel[0]) / 255.0
        let green = CGFloat(pixel[1]) / 255.0
        let blue = CGFloat(pixel[2]) / 255.0
        let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        return luminance < threshold
    }

    /// Public helper so cache layers can decide whether to regenerate stale black thumbnails.
    static func isLikelyDarkFrame(_ image: NSImage, threshold: CGFloat = 0.06) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        return isLikelyDarkFrame(cgImage, threshold: threshold)
    }

    /// Generate a thumbnail from a video file using AVAssetImageGenerator.
    /// Probes multiple timestamps and prefers the first non-dark frame to avoid black slates.
    ///
    /// - Parameters:
    ///   - source: URL to the video file
    ///   - size: Target thumbnail size tier
    /// - Returns: Generated thumbnail or nil on failure
    static func generateVideoThumbnail(from source: URL, size: Size) -> NSImage? {
        let asset = AVURLAsset(url: source, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        let candidateSeconds = videoThumbnailProbeSeconds(for: asset)

        if let image = generateAVVideoThumbnail(from: asset, size: size, candidateSeconds: candidateSeconds) {
            return image
        }

        return generateFFmpegVideoThumbnail(from: source, size: size, candidateSeconds: candidateSeconds)
    }

    private static func videoThumbnailProbeSeconds(for asset: AVURLAsset) -> [Double] {
        var duration = asset.duration.seconds
        if duration <= 0 || duration.isNaN {
            duration = asset.tracks(withMediaType: .video).first?.timeRange.duration.seconds ?? 0
        }

        var candidateSeconds: [Double] = []
        if duration > 0, !duration.isNaN {
            let maxProbe = max(0.0, duration * 0.95)
            candidateSeconds = [1.0, duration * 0.10, duration * 0.25, duration * 0.40, duration * 0.60]
                .map { min(maxProbe, max(0.0, $0)) }
        } else {
            candidateSeconds = [1.0, 0.5, 0.0]
        }
        candidateSeconds.append(0.0)

        var seenSeconds = Set<Int64>()
        return candidateSeconds.filter { seconds in
            let quantized = Int64(seconds * 1000)
            return seenSeconds.insert(quantized).inserted
        }
    }

    private static func generateAVVideoThumbnail(
        from asset: AVURLAsset,
        size: Size,
        candidateSeconds: [Double]
    ) -> NSImage? {
        let generator = AVAssetImageGenerator(asset: asset)

        // Apply video transform (rotation) and constrain to max size
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: size.maxPixelDimension,
            height: size.maxPixelDimension
        )
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var frameZeroFallback: NSImage?

        for seconds in candidateSeconds {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            var actualTime = CMTime.invalid
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: &actualTime) else {
                continue
            }

            // Approximate seeking can collapse every request in a short GOP to its
            // opening keyframe. Interior probes must resolve past frame zero; the
            // explicit zero-second candidate remains the terminal fallback.
            let isFrameZeroRequest = CMTimeCompare(time, .zero) == 0
            if !isFrameZeroRequest,
               (!actualTime.isValid
                || !actualTime.isNumeric
                || CMTimeCompare(actualTime, .zero) <= 0) {
                continue
            }

            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )

            if isFrameZeroRequest {
                frameZeroFallback = image
            }

            if !isLikelyDarkFrame(cgImage) {
                return image
            }
        }

        return frameZeroFallback
    }

    private static func generateFFmpegVideoThumbnail(
        from source: URL,
        size: Size,
        candidateSeconds: [Double]
    ) -> NSImage? {
        guard let ffmpegURL = DependencyManager.executableURL(named: "ffmpeg") else {
            return nil
        }

        var fallbackImage: NSImage?

        for seconds in candidateSeconds {
            guard let image = runFFmpegThumbnail(
                ffmpegURL: ffmpegURL,
                source: source,
                seconds: seconds,
                maxPixelDimension: size.maxPixelDimension
            ) else {
                continue
            }

            if fallbackImage == nil {
                fallbackImage = image
            }

            if !isLikelyDarkFrame(image) {
                return image
            }
        }

        return fallbackImage
    }

    private static func runFFmpegThumbnail(
        ffmpegURL: URL,
        source: URL,
        seconds: Double,
        maxPixelDimension: Int
    ) -> NSImage? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodraw-webm-thumb-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-ss", String(format: "%.3f", seconds),
            "-i", source.path,
            "-frames:v", "1",
            "-vf", "scale=\(maxPixelDimension):\(maxPixelDimension):force_original_aspect_ratio=decrease",
            outputURL.path
        ]

        // ffmpeg can emit enough diagnostic output to fill a Pipe and deadlock a
        // caller that only waits for termination. We do not consume diagnostics
        // here, so route both streams to /dev/null instead.
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logWarning("ThumbnailGenerator: ffmpeg thumbnail fallback failed to launch: \(error.localizedDescription)")
            return nil
        }

        let deadline = Date().addingTimeInterval(12)
        while process.isRunning {
            if Task.isCancelled || Date() >= deadline {
                process.terminate()
                let graceDeadline = Date().addingTimeInterval(0.25)
                while process.isRunning, Date() < graceDeadline {
                    usleep(10_000)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                return nil
            }
            usleep(20_000)
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: outputURL.path),
              let data = try? Data(contentsOf: outputURL),
              let image = NSImage(data: data) else {
            return nil
        }

        return image
    }

    // MARK: - Video Preview Frames

    /// Generate multiple preview frames from a video for hover scrubbing
    /// Frame count scaled to video duration — short clips get fewer, long ones get more
    /// Frame count tuned to stay under ~500ms first-gen budget (~9ms/frame at 100px)
    static func dynamicFrameCount(forDuration seconds: Double) -> Int {
        switch seconds {
        case ..<3:   return 10
        case ..<15:  return 24
        case ..<60:  return 40
        case ..<300: return 50  // ~450ms
        default:     return 55  // ~495ms
        }
    }

    /// Cache path for a video preview frame
    static func previewFramePath(for itemId: UUID, frameIndex: Int) -> URL {
        thumbnailCacheDirectory
            .appendingPathComponent("\(itemId.uuidString)-preview-\(frameIndex).jpg")
    }

    /// Compute progressive generation order — first batch evenly covers the full
    /// timeline for immediate coarse scrubbing, subsequent batches fill gaps.
    private static func progressiveOrder(totalCount: Int, batchSize: Int = 11) -> [[Int]] {
        guard totalCount > 0 else { return [] }
        if totalCount <= batchSize { return [Array(0..<totalCount)] }

        var passes: [[Int]] = []
        var generated = Set<Int>()

        // Pass 1: evenly spread across the full timeline
        var pass1: [Int] = []
        let stride1 = Double(totalCount) / Double(batchSize)
        for i in 0..<batchSize {
            let idx = min(totalCount - 1, Int(Double(i) * stride1))
            if generated.insert(idx).inserted {
                pass1.append(idx)
            }
        }
        passes.append(pass1)

        // Subsequent passes: pick evenly from remaining ungenerated indices
        while generated.count < totalCount {
            let remaining = (0..<totalCount).filter { !generated.contains($0) }
            if remaining.isEmpty { break }

            let thisBatch = min(batchSize, remaining.count)
            var pass: [Int] = []
            if thisBatch >= remaining.count {
                pass = remaining
            } else {
                let strideR = Double(remaining.count) / Double(thisBatch)
                for i in 0..<thisBatch {
                    let ri = min(remaining.count - 1, Int(Double(i) * strideR))
                    pass.append(remaining[ri])
                }
            }
            for idx in pass { generated.insert(idx) }
            passes.append(pass)
        }

        return passes
    }

    /// Generate preview frames progressively — first ~11 frames (~100ms) delivered
    /// immediately for coarse scrubbing, then resolution doubles with each batch
    /// while hovering. All frames cached to disk for instant subsequent hovers.
    ///
    /// - Parameters:
    ///   - source: Video file URL
    ///   - itemId: UUID for disk cache keying
    ///   - onBatch: Called after each batch with (allFramesSoFar sorted by time, isComplete)
    static func generateProgressivePreviewFrames(
        from source: URL,
        itemId: UUID,
        onBatch: @escaping (_ frames: [NSImage], _ isComplete: Bool) -> Void
    ) {
        guard !Task.isCancelled else { return }
        // Use AVURLAsset with precise duration to force synchronous property loading
        let asset = AVURLAsset(url: source, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        var duration = asset.duration.seconds
        // Fallback: get duration from video track if asset-level duration fails
        if duration <= 0 || duration.isNaN {
            if let track = asset.tracks(withMediaType: .video).first {
                duration = track.timeRange.duration.seconds
            }
        }
        guard duration > 0, !duration.isNaN else { onBatch([], true); return }

        let totalCount = dynamicFrameCount(forDuration: duration)

        // Check full cache first — if all frames exist, return instantly
        var cached: [NSImage] = []
        for i in 0..<totalCount {
            guard !Task.isCancelled else { return }
            if let image = NSImage(contentsOf: previewFramePath(for: itemId, frameIndex: i)) {
                cached.append(image)
            } else {
                break
            }
        }
        if cached.count == totalCount {
            onBatch(cached, true)
            return
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Match grid cell width (~150-250px) for crisp scrub frames
        generator.maximumSize = CGSize(width: 200, height: 200)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let passes = progressiveOrder(totalCount: totalCount)
        // Sparse array: index → image, filled progressively
        var allFrames: [NSImage?] = Array(repeating: nil, count: totalCount)

        let cacheDir = thumbnailCacheDirectory
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        for (passIdx, pass) in passes.enumerated() {
            guard !Task.isCancelled else { return }
            for idx in pass {
                guard !Task.isCancelled else { return }
                let time = CMTime(
                    seconds: duration * Double(idx + 1) / Double(totalCount + 1),
                    preferredTimescale: 600
                )
                var actualTime = CMTime.invalid
                guard let cgImage = try? generator.copyCGImage(at: time, actualTime: &actualTime),
                      actualTime.isValid,
                      actualTime.isNumeric,
                      CMTimeCompare(actualTime, .zero) > 0 else {
                    continue
                }
                guard !Task.isCancelled else { return }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                allFrames[idx] = image

                // Cache to disk
                if let data = jpegData(from: image, quality: 0.7) {
                    guard !Task.isCancelled else { return }
                    try? data.write(to: previewFramePath(for: itemId, frameIndex: idx), options: .atomic)
                }
            }

            // Deliver all frames generated so far, sorted by timeline position
            guard !Task.isCancelled else { return }
            let sortedFrames = allFrames.compactMap { $0 }
            let isComplete = passIdx == passes.count - 1
            onBatch(sortedFrames, isComplete)
        }
    }

    /// Non-progressive fallback: generate and cache all frames at once.
    /// Used when progressive loading isn't needed (e.g., pre-warming cache).
    static func generateAndCachePreviewFrames(from source: URL, itemId: UUID, count: Int? = nil) -> [NSImage] {
        var result: [NSImage] = []
        generateProgressivePreviewFrames(from: source, itemId: itemId) { frames, isComplete in
            if isComplete { result = frames }
        }
        return result
    }

    /// Check if preview frames are already cached for a video item.
    static func hasPreviewFrameCache(for itemId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: previewFramePath(for: itemId, frameIndex: 0).path)
    }

    /// A cancelled progressive generation can leave a valid first frame behind. Treating that
    /// partial result as a cache hit permanently strands the rest of the scrub timeline, so the
    /// background preloader verifies the duration-derived frame set before skipping an item.
    static func hasCompletePreviewFrameCache(for itemId: UUID, source: URL) async -> Bool {
        let asset = AVURLAsset(url: source, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        var duration = (try? await asset.load(.duration).seconds) ?? 0
        if duration <= 0 || !duration.isFinite,
           let track = try? await asset.loadTracks(withMediaType: .video).first {
            duration = (try? await track.load(.timeRange).duration.seconds) ?? 0
        }
        guard duration > 0, duration.isFinite else { return false }

        let frameCount = dynamicFrameCount(forDuration: duration)
        return (0..<frameCount).allSatisfy { frameIndex in
            FileManager.default.fileExists(
                atPath: previewFramePath(for: itemId, frameIndex: frameIndex).path
            )
        }
    }

    /// Background preload: generate and cache preview frames for a batch of video items.
    /// Runs at low priority, one video at a time, with throttling.
    static func preloadVideoFrames(for items: [MediaItem]) {
        var seen = Set<UUID>()
        let sources: [VideoPreviewSource] = items.compactMap { item in
            guard item.hasVideo,
                  let source = item.primaryVideoMedia,
                  seen.insert(item.id).inserted else {
                return nil
            }
            return VideoPreviewSource(itemId: item.id, url: source)
        }

        Task {
            await videoPreviewPreloader.schedule(sources: sources)
        }
    }

    static func cancelVideoFramePreload() {
        Task {
            await videoPreviewPreloader.cancel()
        }
    }

    /// Generate a thumbnail from source media (image or video).
    /// Uses CGImageSourceCreateThumbnailAtIndex for images, AVAssetImageGenerator for videos.
    /// Returns nil for unsupported or corrupted files.
    ///
    /// - Parameters:
    ///   - source: URL to the source media file
    ///   - size: Target thumbnail size tier
    ///   - saliencyRect: Optional normalized rect (0-1) for saliency-based cropping (images only)
    /// - Returns: Generated thumbnail or nil on failure
    static func generate(
        from source: URL,
        size: Size,
        saliencyRect: CGRect? = nil
    ) -> NSImage? {
        guard isSupported(source) else {
            return nil
        }

        // Route videos to video thumbnail generator
        if isVideo(source) {
            return generateVideoThumbnail(from: source, size: size)
        }

        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            return nil
        }

        // Options for thumbnail generation
        // kCGImageSourceCreateThumbnailFromImageAlways: Create even if no embedded thumbnail
        // kCGImageSourceCreateThumbnailWithTransform: Apply EXIF orientation
        // kCGImageSourceThumbnailMaxPixelSize: Target size (preserves aspect ratio)
        // kCGImageSourceShouldCacheImmediately: Decode immediately, don't defer
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size.maxPixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        // If we have a saliency rect, apply cropping
        if let saliencyRect = saliencyRect {
            return applySaliencyCrop(to: cgImage, saliencyRect: saliencyRect, targetSize: size.maxPixelDimension)
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Apply saliency-based cropping to focus on interesting region.
    /// The saliencyRect is in normalized coordinates (0-1).
    private static func applySaliencyCrop(
        to cgImage: CGImage,
        saliencyRect: CGRect,
        targetSize: Int
    ) -> NSImage? {
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        // Convert normalized rect to pixel coordinates
        let cropRect = CGRect(
            x: saliencyRect.origin.x * imageWidth,
            y: saliencyRect.origin.y * imageHeight,
            width: saliencyRect.width * imageWidth,
            height: saliencyRect.height * imageHeight
        )

        // Expand crop rect to include some context while keeping saliency region centered
        // Aim for square-ish output for grid display
        let expandedRect = expandRectForThumbnail(
            saliencyRect: cropRect,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            targetSize: CGFloat(targetSize)
        )

        // Perform the crop
        guard let croppedImage = cgImage.cropping(to: expandedRect) else {
            // Fallback to uncropped image
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        return NSImage(cgImage: croppedImage, size: NSSize(width: croppedImage.width, height: croppedImage.height))
    }

    /// Expand saliency rect to create a better thumbnail crop
    private static func expandRectForThumbnail(
        saliencyRect: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        targetSize: CGFloat
    ) -> CGRect {
        // Center point of saliency region
        let centerX = saliencyRect.midX
        let centerY = saliencyRect.midY

        // Try to make a square crop that includes the saliency region
        // Use the larger dimension of saliency rect as minimum size
        let minSize = max(saliencyRect.width, saliencyRect.height) * 1.2 // 20% padding

        // Prefer square crop but don't exceed image bounds
        let cropSize = max(minSize, min(imageWidth, imageHeight) * 0.5)
        let halfSize = cropSize / 2

        // Calculate crop origin, clamping to image bounds
        var originX = centerX - halfSize
        var originY = centerY - halfSize

        // Clamp to image bounds
        originX = max(0, min(originX, imageWidth - cropSize))
        originY = max(0, min(originY, imageHeight - cropSize))

        // Adjust size if we hit bounds
        let finalWidth = min(cropSize, imageWidth - originX)
        let finalHeight = min(cropSize, imageHeight - originY)

        return CGRect(x: originX, y: originY, width: finalWidth, height: finalHeight)
    }

    // MARK: - Batch Generation

    /// Generate thumbnails for multiple source files concurrently
    static func generateBatch(
        sources: [(url: URL, size: Size, saliencyRect: CGRect?)],
        maxConcurrency: Int = 4
    ) async -> [URL: NSImage] {
        await withTaskGroup(of: (URL, NSImage?).self) { group in
            var results: [URL: NSImage] = [:]
            var inFlight = 0
            var iterator = sources.makeIterator()

            // Limit concurrency to avoid memory spikes
            func addNextTask() -> Bool {
                guard let source = iterator.next() else { return false }
                group.addTask {
                    let image = generate(from: source.url, size: source.size, saliencyRect: source.saliencyRect)
                    return (source.url, image)
                }
                inFlight += 1
                return true
            }

            // Start initial batch
            while inFlight < maxConcurrency {
                if !addNextTask() { break }
            }

            // Process results and add new tasks
            for await (url, image) in group {
                inFlight -= 1
                if let image = image {
                    results[url] = image
                }
                _ = addNextTask()
            }

            return results
        }
    }
}

struct VideoPreviewSource: Hashable, Sendable {
    let itemId: UUID
    let url: URL
}

enum VideoPreviewPreloadPolicy {
    static func boundedUniqueSources(
        _ sources: [VideoPreviewSource],
        limit: Int
    ) -> [VideoPreviewSource] {
        guard limit > 0 else { return [] }
        var seenItemIDs = Set<UUID>()
        var result: [VideoPreviewSource] = []
        result.reserveCapacity(min(limit, sources.count))

        for source in sources where seenItemIDs.insert(source.itemId).inserted {
            result.append(source)
            if result.count == limit { break }
        }
        return result
    }
}

struct VideoPreviewPreloadMetrics: Equatable, Sendable {
    var scheduledRequests = 0
    var deduplicatedRequests = 0
    var cancelledRequests = 0
    var startedBatches = 0
    var completedBatches = 0
    var generatedItems = 0
    var cacheHits = 0
}

actor VideoPreviewPreloader {
    typealias CacheLookup = @Sendable (VideoPreviewSource) async -> Bool
    typealias FrameGenerator = @Sendable (VideoPreviewSource) async -> Bool

    private let maxItemsPerPass: Int
    private let debounce: Duration
    private let throttle: Duration
    private let hasCachedFrames: CacheLookup
    private let generateFrames: FrameGenerator

    private var preloadTask: Task<Void, Never>?
    private var activeSources: [VideoPreviewSource]?
    private var requestID = 0
    private var metrics = VideoPreviewPreloadMetrics()

    init(
        maxItemsPerPass: Int = 24,
        debounce: Duration = .milliseconds(300),
        throttle: Duration = .milliseconds(200),
        hasCachedFrames: @escaping CacheLookup = { source in
            await ThumbnailGenerator.hasCompletePreviewFrameCache(
                for: source.itemId,
                source: source.url
            )
        },
        generateFrames: @escaping FrameGenerator = { source in
            !ThumbnailGenerator.generateAndCachePreviewFrames(
                from: source.url,
                itemId: source.itemId
            ).isEmpty
        }
    ) {
        self.maxItemsPerPass = max(0, maxItemsPerPass)
        self.debounce = debounce
        self.throttle = throttle
        self.hasCachedFrames = hasCachedFrames
        self.generateFrames = generateFrames
    }

    func schedule(sources: [VideoPreviewSource]) {
        metrics.scheduledRequests += 1
        let boundedSources = VideoPreviewPreloadPolicy.boundedUniqueSources(
            sources,
            limit: maxItemsPerPass
        )

        guard !boundedSources.isEmpty else {
            cancel(clearSignature: true)
            return
        }

        // A SwiftUI/database refresh commonly hands us the exact same working set. Keep the
        // running or completed request instead of restarting its first video from frame zero.
        guard boundedSources != activeSources else {
            metrics.deduplicatedRequests += 1
            return
        }

        if preloadTask != nil {
            metrics.cancelledRequests += 1
            preloadTask?.cancel()
        }

        requestID += 1
        let thisRequestID = requestID
        activeSources = boundedSources
        let debounce = self.debounce
        let throttle = self.throttle
        let hasCachedFrames = self.hasCachedFrames
        let generateFrames = self.generateFrames

        preloadTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.recordBatchStart(requestID: thisRequestID)
            logInfo("PRELOAD: starting for \(boundedSources.count) videos")

            var generated = 0
            var skipped = 0
            for source in boundedSources {
                guard !Task.isCancelled else { return }

                if await hasCachedFrames(source) {
                    skipped += 1
                } else {
                    let didGenerate = await generateFrames(source)
                    guard !Task.isCancelled else { return }
                    if didGenerate {
                        generated += 1
                    } else {
                        logWarning("PRELOAD: 0 frames for \(source.url.lastPathComponent)")
                    }
                }

                do {
                    try await Task.sleep(for: throttle)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }
            await self?.finishBatch(
                requestID: thisRequestID,
                generated: generated,
                cacheHits: skipped
            )
            logInfo("PRELOAD: done — \(generated) generated, \(skipped) cached")
        }
    }

    func cancel() {
        cancel(clearSignature: true)
    }

    func metricsSnapshot() -> VideoPreviewPreloadMetrics {
        metrics
    }

    private func cancel(clearSignature: Bool) {
        if preloadTask != nil {
            metrics.cancelledRequests += 1
            preloadTask?.cancel()
            preloadTask = nil
        }
        requestID += 1
        if clearSignature {
            activeSources = nil
        }
    }

    private func recordBatchStart(requestID: Int) {
        guard requestID == self.requestID else { return }
        metrics.startedBatches += 1
    }

    private func finishBatch(requestID: Int, generated: Int, cacheHits: Int) {
        guard requestID == self.requestID else { return }
        preloadTask = nil
        metrics.completedBatches += 1
        metrics.generatedItems += generated
        metrics.cacheHits += cacheHits
    }
}

// MARK: - Thumbnail Persistence

extension ThumbnailGenerator {

    /// Directory for cached thumbnails
    static var thumbnailCacheDirectory: URL {
        AppPaths.thumbnailsDirectory
    }

    /// Get the cached thumbnail path for an item
    static func thumbnailPath(for itemId: UUID, size: Size, variant: String? = nil) -> URL {
        let variantSuffix = variant.map { "-\(sanitizedCacheVariant($0))" } ?? ""
        return thumbnailCacheDirectory
            .appendingPathComponent("\(itemId.uuidString)\(variantSuffix)-\(size.rawValue).jpg")
    }

    /// Keep cache variants filename-safe and bounded. Callers use a stable path
    /// fingerprint, so this is primarily defensive against future variant names.
    private static func sanitizedCacheVariant(_ variant: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = variant.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        return String(sanitized.prefix(80))
    }

    /// Check if thumbnail exists on disk
    static func thumbnailExists(for itemId: UUID, size: Size, variant: String? = nil) -> Bool {
        FileManager.default.fileExists(atPath: thumbnailPath(for: itemId, size: size, variant: variant).path)
    }

    /// Load an eagerly decoded disk thumbnail. Call from the bounded image worker pool.
    static func loadThumbnail(
        for itemId: UUID,
        size: Size,
        variant: String? = nil,
        maxPixelSize: Int? = nil,
        displayScale: CGFloat = 1
    ) -> NSImage? {
        let path = thumbnailPath(for: itemId, size: size, variant: variant)
        guard let source = CGImageSourceCreateWithURL(path as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize ?? size.maxPixelDimension, size.maxPixelDimension),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: bitmap,
            size: NSSize(width: CGFloat(bitmap.width) / displayScale, height: CGFloat(bitmap.height) / displayScale))
    }

    /// Materialize generated thumbnails too, without relying on AppKit's lazy representations.
    static func preparedThumbnail(
        _ image: NSImage,
        maxPixelSize: Int? = nil,
        displayScale: CGFloat = 1
    ) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let factor = min(1, CGFloat(maxPixelSize ?? max(cg.width, cg.height)) / CGFloat(max(cg.width, cg.height)))
        let width = max(1, Int((CGFloat(cg.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(cg.height) * factor).rounded()))
        // Keep the thumbnail's own RGB space where an 8-bit context supports it; a
        // device-RGB redraw would shift wide-gamut colors.
        let spaces = [cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil },
                      CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        guard let context = spaces.lazy.compactMap({
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: $0, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }).first else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bitmap = context.makeImage() else { return nil }
        return NSImage(cgImage: bitmap,
            size: NSSize(width: CGFloat(width) / displayScale, height: CGFloat(height) / displayScale))
    }

    /// Generate and save thumbnail to disk
    /// Returns the generated image or nil on failure
    @discardableResult
    static func generateAndSave(
        from source: URL,
        itemId: UUID,
        size: Size,
        saliencyRect: CGRect? = nil,
        variant: String? = nil
    ) -> NSImage? {
        guard let image = generate(from: source, size: size, saliencyRect: saliencyRect) else {
            return nil
        }

        // Ensure directory exists
        let directory = thumbnailCacheDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Save as JPEG at 80% quality (per ADR-003)
        let path = thumbnailPath(for: itemId, size: size, variant: variant)
        if let jpegData = jpegData(from: image, quality: 0.8) {
            try? jpegData.write(to: path, options: .atomic)
        }

        return image
    }

    /// Save an already-generated thumbnail to disk.
    static func save(_ image: NSImage, itemId: UUID, size: Size, variant: String? = nil) {
        let directory = thumbnailCacheDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let path = thumbnailPath(for: itemId, size: size, variant: variant)
        if let jpegData = jpegData(from: image, quality: 0.8) {
            try? jpegData.write(to: path, options: .atomic)
        }
    }

    /// Convert NSImage to JPEG data
    static func jpegData(from image: NSImage, quality: CGFloat) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: quality]
        )
    }

    /// Delete all thumbnails for an item
    static func deleteThumbnails(for itemId: UUID) {
        let prefix = itemId.uuidString
        if let files = try? FileManager.default.contentsOfDirectory(
            at: thumbnailCacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for file in files where file.lastPathComponent.hasPrefix(prefix + "-") {
                let name = file.lastPathComponent
                guard name.hasSuffix("-sm.jpg") || name.hasSuffix("-md.jpg") else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Clear entire thumbnail cache
    static func clearCache() throws {
        try FileManager.default.removeItem(at: thumbnailCacheDirectory)
    }

    /// Delete all thumbnails (alias for clearCache)
    static func deleteAllThumbnails() {
        try? clearCache()
    }

    /// Get total size of thumbnail cache in bytes
    static func cacheSize() -> Int64 {
        let fm = FileManager.default
        let directory = thumbnailCacheDirectory

        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }

        return totalSize
    }
}
