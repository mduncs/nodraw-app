import AVFoundation
import PhotoPipeline
import XCTest
@testable import MediaViewer

final class WebMDerivedAssetExtractorTests: XCTestCase {
    func testParsesFFmpegDurationAndRejectsUnknownDuration() throws {
        let output = """
          Duration: 01:02:03.45, start: -0.007000, bitrate: 924 kb/s
        """

        let duration = try XCTUnwrap(
            WebMDerivedAssetExtractor.parseDuration(fromFFmpegOutput: output)
        )
        XCTAssertEqual(duration, 3_723.45, accuracy: 0.0001)
        XCTAssertNil(
            WebMDerivedAssetExtractor.parseDuration(
                fromFFmpegOutput: "Duration: N/A, start: 0.000000"
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(WebMDerivedAssetExtractor.parseStartTime(fromFFmpegOutput: output)),
            -0.007,
            accuracy: 0.000_001
        )
        let streamOutput = """
          Stream #0:0: Video: vp8, yuv420p, start 0.000000
          Stream #0:1: Audio: opus, 48000 Hz, mono, fltp, start 1.001000
        """
        XCTAssertEqual(
            try XCTUnwrap(
                WebMDerivedAssetExtractor.parseStreamStartTime(
                    kind: "Audio",
                    fromFFmpegOutput: streamOutput
                )
            ),
            1.001,
            accuracy: 0.000_001
        )
    }

    func testDelayedAudioRetainsSourceTimelineOffsetWithoutPaddingDerivedWAV() async throws {
        guard let ffmpegURL = DependencyManager.executableURL(named: "ffmpeg"),
              let ffprobeURL = DependencyManager.executableURL(named: "ffprobe") else {
            throw XCTSkip("ffmpeg and ffprobe are required")
        }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("delayed-audio.webm")
        try makeDelayedAudioWebMFixture(at: sourceURL, ffmpegURL: ffmpegURL)
        let derivedRoot = root.appendingPathComponent("derived", isDirectory: true)
        try FileManager.default.createDirectory(at: derivedRoot, withIntermediateDirectories: true)
        let extractor = WebMDerivedAssetExtractor(
            ffmpegURL: ffmpegURL,
            ffprobeURL: ffprobeURL,
            temporaryRoot: derivedRoot
        )

        let streams = try await extractor.probeStreams(in: sourceURL)
        XCTAssertTrue(streams.hasAudio)
        XCTAssertTrue(streams.hasVideo)
        XCTAssertTrue(streams.usedFFprobe)
        XCTAssertEqual(try XCTUnwrap(streams.audioStartTime), 1.001, accuracy: 0.03)
        XCTAssertEqual(streams.audioTimelineOffset, 1.001, accuracy: 0.03)

        let audioAsset = try await extractor.extractTranscriptionAudio(
            from: sourceURL,
            streamInfo: streams
        )
        defer { audioAsset.cleanup() }
        XCTAssertEqual(audioAsset.sourceTimelineOffset, 1.001, accuracy: 0.03)

        let audioFile = try AVAudioFile(forReading: audioAsset.url)
        let derivedDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        XCTAssertLessThan(derivedDuration, 4.2, "Derived audio should not be padded with a leading second of silence")

        let segment = TranscriptSegment(
            id: UUID(),
            itemId: UUID(),
            mediaFileIndex: 0,
            sourcePath: sourceURL.path,
            startTime: 0.25,
            endTime: 0.75,
            text: "delayed speech",
            confidence: 0.9,
            language: "en",
            model: "fixture",
            version: 1
        )
        let adjusted = try XCTUnwrap(
            TranscriptionQueue.applyingTimelineOffset(
                audioAsset.sourceTimelineOffset,
                to: [segment]
            ).first
        )
        XCTAssertEqual(adjusted.startTime, 1.251, accuracy: 0.03)
        XCTAssertEqual(adjusted.endTime, 1.751, accuracy: 0.03)
    }

    func testOffsetVideoMapsProxyAnalysisBackToSourceTimeline() async throws {
        guard let ffmpegURL = DependencyManager.executableURL(named: "ffmpeg"),
              let ffprobeURL = DependencyManager.executableURL(named: "ffprobe") else {
            throw XCTSkip("ffmpeg and ffprobe are required")
        }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("offset-video.webm")
        try makeOffsetVideoWebMFixture(at: sourceURL, ffmpegURL: ffmpegURL)
        let derivedRoot = root.appendingPathComponent("derived", isDirectory: true)
        try FileManager.default.createDirectory(at: derivedRoot, withIntermediateDirectories: true)
        let extractor = WebMDerivedAssetExtractor(
            ffmpegURL: ffmpegURL,
            ffprobeURL: ffprobeURL,
            temporaryRoot: derivedRoot,
            configuration: .init(frameLimit: 10, maximumVideoDimension: 96)
        )

        let streams = try await extractor.probeStreams(in: sourceURL)
        XCTAssertTrue(streams.hasVideo)
        XCTAssertFalse(streams.hasAudio)
        XCTAssertEqual(streams.videoTimelineOffset, 2, accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(streams.formatDuration), 7, accuracy: 0.08)

        let videoAsset = try await extractor.extractSampledVideo(
            from: sourceURL,
            streamInfo: streams
        ) { _ in 1 }
        defer { videoAsset.cleanup() }
        XCTAssertEqual(videoAsset.sourceTimelineOffset, 2, accuracy: 0.03)
        XCTAssertEqual(videoAsset.sourceDuration, 7, accuracy: 0.08)

        let proxyAsset = AVURLAsset(url: videoAsset.url)
        let proxyTime = try await proxyAsset.load(.duration)
        let proxyDuration = proxyTime.seconds
        XCTAssertLessThan(proxyDuration, 5.5)

        let labels = [SceneLabel(label: "fixture", confidence: 0.8)]
        let proxyAnalysis = VideoAnalysis(
            duration: proxyDuration,
            frameCount: 1,
            labels: labels,
            highlights: [VideoHighlight(time: 0.5, score: 0.9, labels: labels)],
            suggestedThumbnailTime: 1,
            frameAnalyses: [FrameAnalysis(time: 0.25, labels: labels, qualityScore: 0.7)]
        )
        let mapped = VideoUnderstandingQueue.analysis(
            proxyAnalysis,
            mappedTo: videoAsset.timelineMapping
        )
        XCTAssertEqual(mapped.duration, 7, accuracy: 0.08)
        XCTAssertEqual(mapped.highlights.first?.time ?? -1, 2.5, accuracy: 0.03)
        XCTAssertEqual(mapped.suggestedThumbnailTime, 3, accuracy: 0.03)
        XCTAssertEqual(mapped.frameAnalyses.first?.time ?? -1, 2.25, accuracy: 0.03)

        let segments = VideoTimelineBuilder.buildSegments(
            itemId: UUID(),
            mediaFileIndex: 0,
            sourcePath: sourceURL.path,
            analysis: mapped
        )
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(segments.first).startTime, 2)
    }

    func testRejectsNonWebMBeforeCreatingTemporaryFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.mov")
        try Data([0]).write(to: sourceURL)
        let derivedRoot = root.appendingPathComponent("derived", isDirectory: true)
        try FileManager.default.createDirectory(at: derivedRoot, withIntermediateDirectories: true)
        let extractor = WebMDerivedAssetExtractor(
            ffmpegURL: URL(fileURLWithPath: "/usr/bin/false"),
            temporaryRoot: derivedRoot
        )

        do {
            _ = try await extractor.extractTranscriptionAudio(from: sourceURL)
            XCTFail("Expected a non-WebM source to be rejected")
        } catch let error as WebMDerivedAssetExtractionError {
            guard case .unsupportedSource(let rejectedURL) = error else {
                return XCTFail("Unexpected extraction error: \(error)")
            }
            XCTAssertEqual(rejectedURL, sourceURL)
        }

        XCTAssertTrue(try contents(of: derivedRoot).isEmpty)
    }

    func testAudioAndSampledVideoExtractionProduceBoundedCompatibleAssets() async throws {
        guard let ffmpegURL = DependencyManager.executableURL(named: "ffmpeg") else {
            throw XCTSkip("ffmpeg is not installed")
        }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.webm")
        try makeWebMFixture(at: sourceURL, ffmpegURL: ffmpegURL)

        let derivedRoot = root.appendingPathComponent("derived", isDirectory: true)
        try FileManager.default.createDirectory(at: derivedRoot, withIntermediateDirectories: true)
        let extractor = WebMDerivedAssetExtractor(
            ffmpegURL: ffmpegURL,
            temporaryRoot: derivedRoot,
            configuration: .init(frameLimit: 500, maximumVideoDimension: 96)
        )

        let audioAsset = try await extractor.extractTranscriptionAudio(from: sourceURL)
        let audioWorkingDirectory = audioAsset.workingDirectory
        XCTAssertEqual(audioAsset.url.pathExtension, "wav")
        let audioFile = try AVAudioFile(forReading: audioAsset.url)
        XCTAssertEqual(audioFile.fileFormat.sampleRate, 16_000, accuracy: 0.1)
        XCTAssertEqual(audioFile.fileFormat.channelCount, 1)
        XCTAssertEqual(audioFile.fileFormat.commonFormat, .pcmFormatInt16)
        audioAsset.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioWorkingDirectory.path))

        let videoAsset = try await extractor.extractSampledVideo(from: sourceURL) { _ in 100 }
        let videoWorkingDirectory = videoAsset.workingDirectory
        defer { videoAsset.cleanup() }
        XCTAssertEqual(videoAsset.url.pathExtension, "mov")
        XCTAssertEqual(videoAsset.frameLimit, 60)
        XCTAssertGreaterThan(videoAsset.sourceDuration, 1.5)
        XCTAssertLessThanOrEqual(
            videoAsset.framesPerSecond,
            (60 / videoAsset.sourceDuration) + 0.0001
        )

        let asset = AVURLAsset(url: videoAsset.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertTrue(audioTracks.isEmpty)
        let frameCount = try countSamples(in: asset, track: try XCTUnwrap(tracks.first))
        XCTAssertGreaterThan(frameCount, 0)
        XCTAssertLessThanOrEqual(frameCount, 60)

        videoAsset.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: videoWorkingDirectory.path))
        XCTAssertTrue(try contents(of: derivedRoot).isEmpty)
    }

    func testTimeoutAndCancellationStopFFmpegAndCleanWorkingDirectories() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeFFmpeg = root.appendingPathComponent("ffmpeg")
        let script = """
            #!/bin/sh
            while :
            do
                :
            done
            """
        try Data(script.utf8).write(to: fakeFFmpeg, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeFFmpeg.path
        )
        let fakeFFprobe = root.appendingPathComponent("ffprobe")
        let probeScript = """
            #!/bin/sh
            printf '%s\\n' '{"streams":[{"codec_type":"audio","start_time":"0.000000"}],"format":{"start_time":"0.000000","duration":"1.000000"}}'
            """
        try Data(probeScript.utf8).write(to: fakeFFprobe, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeFFprobe.path
        )
        let sourceURL = root.appendingPathComponent("source.webm")
        try Data([0]).write(to: sourceURL)

        let timeoutRoot = root.appendingPathComponent("timeout-derived", isDirectory: true)
        try FileManager.default.createDirectory(at: timeoutRoot, withIntermediateDirectories: true)
        let timeoutExtractor = WebMDerivedAssetExtractor(
            ffmpegURL: fakeFFmpeg,
            ffprobeURL: fakeFFprobe,
            temporaryRoot: timeoutRoot,
            configuration: .init(audioTimeout: 0.05, terminationGrace: 0.05)
        )

        do {
            _ = try await timeoutExtractor.extractTranscriptionAudio(from: sourceURL)
            XCTFail("Expected ffmpeg extraction to time out")
        } catch let error as WebMDerivedAssetExtractionError {
            guard case .timedOut(let operation, _) = error else {
                return XCTFail("Unexpected timeout error: \(error)")
            }
            XCTAssertEqual(operation, "audio extraction")
        }
        XCTAssertTrue(try contents(of: timeoutRoot).isEmpty)

        let cancellationRoot = root.appendingPathComponent("cancel-derived", isDirectory: true)
        try FileManager.default.createDirectory(at: cancellationRoot, withIntermediateDirectories: true)
        let cancellationExtractor = WebMDerivedAssetExtractor(
            ffmpegURL: fakeFFmpeg,
            ffprobeURL: fakeFFprobe,
            temporaryRoot: cancellationRoot,
            configuration: .init(audioTimeout: 30, terminationGrace: 0.05)
        )
        let extractionTask = Task {
            try await cancellationExtractor.extractTranscriptionAudio(from: sourceURL)
        }

        for _ in 0..<100 where try contents(of: cancellationRoot).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        extractionTask.cancel()

        do {
            _ = try await extractionTask.value
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(try contents(of: cancellationRoot).isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WebMDerivedAssetExtractorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func contents(of directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
    }

    private func makeWebMFixture(at outputURL: URL, ffmpegURL: URL) throws {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-y",
            "-f", "lavfi",
            "-i", "testsrc2=size=96x64:rate=30:duration=2",
            "-f", "lavfi",
            "-i", "sine=frequency=440:sample_rate=48000:duration=2",
            "-shortest",
            "-c:v", "libvpx",
            "-deadline", "realtime",
            "-cpu-used", "8",
            "-pix_fmt", "yuv420p",
            "-c:a", "libopus",
            outputURL.path
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw XCTSkip("ffmpeg cannot encode the synthetic WebM fixture")
        }
    }

    private func makeDelayedAudioWebMFixture(at outputURL: URL, ffmpegURL: URL) throws {
        try runFixtureCommand(
            ffmpegURL: ffmpegURL,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=96x64:rate=10:duration=5",
                "-itsoffset", "1",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=4",
                "-shortest",
                "-c:v", "libvpx", "-deadline", "realtime", "-cpu-used", "8",
                "-pix_fmt", "yuv420p", "-c:a", "libopus",
                outputURL.path
            ],
            failureMessage: "ffmpeg cannot encode delayed-audio WebM fixture"
        )
    }

    private func makeOffsetVideoWebMFixture(at outputURL: URL, ffmpegURL: URL) throws {
        try runFixtureCommand(
            ffmpegURL: ffmpegURL,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=96x64:rate=10:duration=5",
                "-c:v", "libvpx", "-deadline", "realtime", "-cpu-used", "8",
                "-pix_fmt", "yuv420p", "-an", "-output_ts_offset", "2",
                outputURL.path
            ],
            failureMessage: "ffmpeg cannot encode offset-timeline WebM fixture"
        )
    }

    private func runFixtureCommand(
        ffmpegURL: URL,
        arguments: [String],
        failureMessage: String
    ) throws {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip(failureMessage)
        }
    }

    private func countSamples(in asset: AVAsset, track: AVAssetTrack) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw XCTSkip("AVFoundation cannot inspect the derived MOV fixture")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw XCTSkip("AVFoundation cannot read the derived MOV fixture")
        }

        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 {
                count += 1
            }
        }
        return count
    }
}
