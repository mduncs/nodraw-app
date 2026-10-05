import XCTest
@testable import MediaViewer

private final class LockedInvocationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private func waitIgnoringCancellation(for seconds: TimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            continuation.resume()
        }
    }
}

final class VisionOperationTimeoutTests: XCTestCase {
    private enum TestError: Error, Equatable {
        case expected
    }

    func testSuccessfulOperationReturnsItsValue() async throws {
        let result = try await VisionProcessor.withTimeout(seconds: 1) {
            42
        }

        XCTAssertEqual(result, 42)
    }

    func testOperationErrorPassesThrough() async {
        do {
            let _: Int = try await VisionProcessor.withTimeout(seconds: 1) {
                throw TestError.expected
            }
            XCTFail("Expected operation error")
        } catch let error as TestError {
            XCTAssertEqual(error, .expected)
        } catch {
            XCTFail("Expected TestError.expected, got \(error)")
        }
    }

    func testTimeoutFiresRegisteredCancellationHookExactlyOnceAndIgnoresLateResult() async {
        let cancellationHookFired = expectation(description: "Cancellation hook fired")
        cancellationHookFired.assertForOverFulfill = true
        let operationFinished = expectation(description: "Cancellation-ignoring operation finished")
        let cancellationHookCalls = LockedInvocationCount()
        let start = ContinuousClock.now

        do {
            let _: Int = try await VisionProcessor.withTimeout(seconds: 0.03) { cancellation in
                cancellation.register {
                    cancellationHookCalls.increment()
                    cancellationHookFired.fulfill()
                }
                await waitIgnoringCancellation(for: 0.5)
                operationFinished.fulfill()
                return 99
            }
            XCTFail("Expected timeout")
        } catch VisionError.timeout {
            // Expected.
        } catch {
            XCTFail("Expected VisionError.timeout, got \(error)")
        }

        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(
            elapsed,
            .milliseconds(300),
            "Timeout waited for the cancellation-ignoring operation: \(elapsed)"
        )

        // Let the losing operation complete to exercise both exactly-once guards.
        await fulfillment(of: [cancellationHookFired, operationFinished], timeout: 1)
        XCTAssertEqual(cancellationHookCalls.value, 1)

        do {
            let subsequent = try await VisionProcessor.withTimeout(seconds: 1) { 7 }
            XCTAssertEqual(subsequent, 7)
        } catch {
            XCTFail("Late completion corrupted a subsequent timeout race: \(error)")
        }
    }

    func testCancellationBeforeHookRegistrationRunsHookExactlyOnceWhenRegistered() async {
        let cancellationHookFired = expectation(description: "Late-registered cancellation hook fired")
        cancellationHookFired.assertForOverFulfill = true
        let operationFinished = expectation(description: "Late-registering operation finished")
        let cancellationHookCalls = LockedInvocationCount()

        do {
            let _: Int = try await VisionProcessor.withTimeout(seconds: 0.03) { cancellation in
                await waitIgnoringCancellation(for: 0.1)
                cancellation.register {
                    cancellationHookCalls.increment()
                    cancellationHookFired.fulfill()
                }
                await waitIgnoringCancellation(for: 0.1)
                operationFinished.fulfill()
                return 99
            }
            XCTFail("Expected timeout")
        } catch VisionError.timeout {
            // Expected.
        } catch {
            XCTFail("Expected VisionError.timeout, got \(error)")
        }

        await fulfillment(of: [cancellationHookFired, operationFinished], timeout: 1)
        XCTAssertEqual(cancellationHookCalls.value, 1)
    }

    func testParentCancellationFiresRegisteredHookWithoutAwaitingOperation() async {
        let operationStarted = expectation(description: "Operation registered cancellation hook")
        let cancellationHookFired = expectation(description: "Parent cancellation hook fired")
        cancellationHookFired.assertForOverFulfill = true
        let operationFinished = expectation(description: "Parent-cancelled operation finished late")
        let cancellationHookCalls = LockedInvocationCount()

        let task = Task {
            try await VisionProcessor.withTimeout(seconds: 5) { cancellation in
                cancellation.register {
                    cancellationHookCalls.increment()
                    cancellationHookFired.fulfill()
                }
                operationStarted.fulfill()
                await waitIgnoringCancellation(for: 0.5)
                operationFinished.fulfill()
                return 99
            }
        }

        await fulfillment(of: [operationStarted], timeout: 1)
        let start = ContinuousClock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(
            elapsed,
            .milliseconds(300),
            "Parent cancellation waited for the cancellation-ignoring operation: \(elapsed)"
        )

        await fulfillment(of: [cancellationHookFired, operationFinished], timeout: 1)
        XCTAssertEqual(cancellationHookCalls.value, 1)
    }
}
