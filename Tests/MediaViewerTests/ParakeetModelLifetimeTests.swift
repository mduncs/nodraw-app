import FluidAudio
import Foundation
import XCTest
@testable import MediaViewer

final class ParakeetModelLifetimeTests: XCTestCase {
    func testIdleUnloadReloadsOnDemandWithoutChangingResult() async throws {
        let service = makeService()
        let first = try await service.transcribe(sourceURL: audioURL())
        try await waitForUnload(service)
        let second = try await service.transcribe(sourceURL: audioURL())
        XCTAssertEqual(second.text, first.text)
        XCTAssertEqual(second.model, first.model)
        let diagnostics = await service.resourceDiagnostics()
        XCTAssertEqual(diagnostics.managerLoadCount, 2)
        try await waitForUnload(service, count: 2)
    }

    func testPressureDoesNotUnloadUntilEveryActiveCallFinishes() async throws {
        let gate = TranscriptionLifetimeGate()
        let service = makeService(idleUnloadDelay: .seconds(30)) { _, _ in
            await gate.enterAndWait()
            return Self.result()
        }
        let first = Task { try await service.transcribe(sourceURL: audioURL()) }
        let second = Task { try await service.transcribe(sourceURL: audioURL()) }
        await gate.waitForCalls(2)
        await service.releaseIdleResources()
        var diagnostics = await service.resourceDiagnostics()
        XCTAssertTrue(diagnostics.modelLoaded)
        XCTAssertEqual(diagnostics.activeTranscriptions, 2)
        XCTAssertEqual(diagnostics.unloadCount, 0)

        await gate.resumeOne()
        try await waitForActiveCalls(service, count: 1)
        diagnostics = await service.resourceDiagnostics()
        XCTAssertTrue(diagnostics.modelLoaded)
        XCTAssertEqual(diagnostics.unloadCount, 0)
        await gate.resumeAll()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult.text, secondResult.text)
        try await waitForUnload(service)
    }

    func testConcurrentFirstUseLoadsOneManagerAndDefersPressureRelease() async throws {
        let gate = TranscriptionLifetimeGate()
        let service = ParakeetTranscriptionService(
            managerLoader: {
                await gate.enterAndWait()
                return AsrManager()
            },
            transcriptionOperation: { _, _ in Self.result() }
        )
        let first = Task { try await service.transcribe(sourceURL: audioURL()) }
        let second = Task { try await service.transcribe(sourceURL: audioURL()) }
        await gate.waitForCalls(1)
        try await waitForActiveCalls(service, count: 2)
        let loadCalls = await gate.callCount
        XCTAssertEqual(loadCalls, 1)
        await service.releaseIdleResources()
        await gate.resumeAll()
        _ = try await first.value
        _ = try await second.value
        try await waitForUnload(service)
        let diagnostics = await service.resourceDiagnostics()
        XCTAssertEqual(diagnostics.managerLoadCount, 1)
    }

    func testFailedTranscriptionStillReleasesManager() async throws {
        let service = makeService { _, _ in throw LifetimeTestError.expected }
        do {
            _ = try await service.transcribe(sourceURL: audioURL())
            XCTFail("Expected the injected transcription error")
        } catch LifetimeTestError.expected {}
        try await waitForUnload(service)
        let diagnostics = await service.resourceDiagnostics()
        XCTAssertEqual(diagnostics.activeTranscriptions, 0)
    }

    func testNewWorkCancelsPreviousIdleTimer() async throws {
        let gate = TranscriptionLifetimeGate()
        let service = makeService { _, url in
            if url.lastPathComponent == "active.wav" {
                await gate.enterAndWait()
            }
            return Self.result()
        }
        _ = try await service.transcribe(sourceURL: audioURL())
        let active = Task { try await service.transcribe(sourceURL: audioURL(name: "active.wav")) }
        await gate.waitForCalls(1)
        try await Task.sleep(for: .milliseconds(80))
        let diagnostics = await service.resourceDiagnostics()
        XCTAssertTrue(diagnostics.modelLoaded)
        XCTAssertEqual(diagnostics.unloadCount, 0)
        await gate.resumeAll()
        _ = try await active.value
        try await waitForUnload(service)
    }

    func testFailedLoadCanRetry() async throws {
        let attempts = TranscriptionLifetimeAttempts()
        let service = ParakeetTranscriptionService(
            idleUnloadDelay: .milliseconds(30),
            managerLoader: {
                if await attempts.next() == 1 {
                    throw LifetimeTestError.expected
                }
                return AsrManager()
            },
            transcriptionOperation: { _, _ in Self.result() }
        )
        do {
            _ = try await service.transcribe(sourceURL: audioURL())
            XCTFail("Expected the injected load error")
        } catch LifetimeTestError.expected {}
        let recovered = try await service.transcribe(sourceURL: audioURL())
        XCTAssertEqual(recovered.text, Self.result().text)
        let count = await attempts.count
        XCTAssertEqual(count, 2)
        try await waitForUnload(service)
    }

    private func makeService(
        idleUnloadDelay: Duration = .milliseconds(30),
        operation: @escaping @Sendable (AsrManager, URL) async throws -> ParakeetTranscriptionResult = { _, _ in ParakeetModelLifetimeTests.result() }
    ) -> ParakeetTranscriptionService {
        ParakeetTranscriptionService(
            idleUnloadDelay: idleUnloadDelay,
            managerLoader: { AsrManager() },
            transcriptionOperation: operation
        )
    }

    private func audioURL(name: String = "fixture.wav") -> URL {
        URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent(name)
    }

    private static func result() -> ParakeetTranscriptionResult {
        ParakeetTranscriptionResult(
            text: "A synthetic transcript.", confidence: 0.9, duration: 1,
            tokens: [], language: nil, model: "synthetic-parakeet"
        )
    }

    private func waitForUnload(_ service: ParakeetTranscriptionService, count: Int = 1) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            let diagnostics = await service.resourceDiagnostics()
            if !diagnostics.modelLoaded, diagnostics.unloadCount >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Manager did not unload after its idle grace period")
    }

    private func waitForActiveCalls(_ service: ParakeetTranscriptionService, count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await service.resourceDiagnostics().activeTranscriptions == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Active calls did not reach \(count)")
    }
}

private enum LifetimeTestError: Error {
    case expected
}

private actor TranscriptionLifetimeAttempts {
    private(set) var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

private actor TranscriptionLifetimeGate {
    private(set) var callCount = 0
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var startedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func enterAndWait() async {
        callCount += 1
        let ready = startedWaiters.filter { $0.0 <= callCount }
        startedWaiters.removeAll { $0.0 <= callCount }
        for (_, waiter) in ready { waiter.resume() }
        await withCheckedContinuation { pending.append($0) }
    }

    func waitForCalls(_ count: Int) async {
        guard callCount < count else { return }
        await withCheckedContinuation { startedWaiters.append((count, $0)) }
    }

    func resumeOne() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume()
    }

    func resumeAll() {
        let continuations = pending
        pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
