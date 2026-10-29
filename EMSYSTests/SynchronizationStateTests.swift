import XCTest
@testable import EMSYS

@MainActor
final class SynchronizationStateTests: XCTestCase {
    func testSuccessFailureAndRetryPreserveLastSuccessfulTime() async {
        let state = SynchronizationState()
        await state.synchronize {}
        let succeededAt = state.lastSucceededAt
        XCTAssertNotNil(succeededAt)
        await state.synchronize { throw URLError(.notConnectedToInternet) }
        XCTAssertTrue(state.failed)
        XCTAssertEqual(state.lastSucceededAt, succeededAt)
        XCTAssertFalse(state.isRunning)
        await state.synchronize {}
        XCTAssertFalse(state.failed)
        XCTAssertNotNil(state.lastSucceededAt)
    }

    func testConcurrentRequestsAreCoalescedAndOldSessionCannotReportSuccess() async {
        let state = SynchronizationState()
        let sessionID = UUID()
        state.useSession(sessionID)
        let started = expectation(description: "Synchronization started")
        var finish: CheckedContinuation<Void, Never>?
        let running = Task { @MainActor in
            await state.synchronize {
                await withCheckedContinuation { continuation in
                    finish = continuation
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(state.isRunning)
        state.useSession(sessionID) // A second window must not reset this run.
        await state.synchronize { XCTFail("A second run must not start") }
        let waiting = expectation(description: "Reconnect is waiting for the current attempt")
        let reconnect = Task { @MainActor in
            waiting.fulfill()
            await state.waitForCurrentRun()
        }
        await fulfillment(of: [waiting], timeout: 2)
        state.useSession(UUID())
        await reconnect.value
        finish?.resume()
        let didStart = await running.value
        XCTAssertTrue(didStart)
        XCTAssertNil(state.lastSucceededAt)
        XCTAssertFalse(state.failed)
        XCTAssertFalse(state.isRunning)
    }

    func testCancellationIsNotReportedAsSuccessfulSynchronization() async {
        let state = SynchronizationState()
        await state.synchronize { throw CancellationError() }
        XCTAssertNil(state.lastSucceededAt)
        XCTAssertFalse(state.failed)
        XCTAssertFalse(state.isRunning)
    }

    func testAnUploadDoesNotFulfillADownloadOrWorkQueuedDuringItsRun() async {
        let state = SynchronizationState()
        state.requestUpload()
        let started = expectation(description: "Upload started")
        var finish: CheckedContinuation<Void, Never>?
        let running = Task {
            await state.synchronize(includesDownloads: false) {
                await withCheckedContinuation { finish = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        state.requestUpload()
        finish?.resume()
        _ = await running.value
        XCTAssertEqual(state.completedUploadVersion, 1)
        XCTAssertEqual(state.requestedUploadVersion, 2)
        XCTAssertNil(state.lastDownloadedAt)
        XCTAssertNotNil(state.lastFinishedAt)
        await state.synchronize {}
        XCTAssertEqual(state.completedUploadVersion, 2)
        XCTAssertNotNil(state.lastDownloadedAt)
    }
}
