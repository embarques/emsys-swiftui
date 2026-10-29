import XCTest
@testable import EMSYS

@MainActor
final class PickupCompletionTests: XCTestCase {
    func testOfflineIntentAndExactRequestSurviveTerminationAndDownloads() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let snapshot = try snapshot()
        try await store.save(snapshot)
        let first = try await store.queueCompletion(id: 42, revision: snapshot.revision)
        let repeated = try await store.queueCompletion(id: 42, revision: snapshot.revision)
        XCTAssertEqual(first.id, repeated.id)
        let reopened = try await open(directory)
        // A list refresh may replace the server copy, never the local intent.
        try await reopened.save([snapshot.pickup])
        let pending = try await reopened.completion(id: 42)
        XCTAssertEqual(pending?.id, first.id)
        XCTAssertEqual(pending?.request, first.request)
        let pickup = try await reopened.pickup(id: 42)
        XCTAssertEqual(pickup?.pendingCompletion, true)
        let completed = try await reopened.pickups(matching: .init(status: .completed))
        XCTAssertEqual(completed.map(\.id), [42])
        let other = try await PickupStore.open(directory: directory, userID: "other", companyID: "company")
        let foreign = try await other.pendingCompletions()
        XCTAssertTrue(foreign.isEmpty)
    }

    func testRejectedConflictRequiresExplicitServerReviewAndUnknownOutcomesCannotBeDiscarded() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let original = try snapshot()
        try await store.save(original)
        let operation = try await store.queueCompletion(id: 42, revision: original.revision)
        let changed = try snapshot(revision: "b")
        do {
            try await store.discardRejectedCompletion(id: 42, snapshot: changed)
            XCTFail("Pending unknown outcome must not be discarded")
        } catch PickupStore.StoreError.pendingOperation { }
        try await store.setCompletionState(id: operation.id, state: .needsReview)
        try await store.discardRejectedCompletion(id: 42, snapshot: changed)
        let pending = try await store.completion(id: 42)
        XCTAssertNil(pending)
        let revised = try await store.revision(id: 42)
        XCTAssertEqual(revised, changed.revision)
        let next = try await store.queueCompletion(id: 42, revision: changed.revision)
        XCTAssertNotEqual(next.id, operation.id)
    }

    func testAcknowledgementCannotClearAnotherOperationOrReapplyReopenedStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let original = try snapshot()
        try await store.save(original)
        let operation = try await store.queueCompletion(id: 42, revision: original.revision)
        var receipt = try snapshot(revision: "b")
        receipt.requestId = UUID().uuidString
        do {
            try await store.acknowledgeCompletion(operation, snapshot: receipt)
            XCTFail("Wrong receipt identity must not acknowledge an operation")
        } catch PickupStore.StoreError.invalidRecords { }
        receipt.requestId = operation.id.uuidString
        // The server accepted the old operation, then dispatch reopened it.
        try await store.acknowledgeCompletion(operation, snapshot: receipt)
        let reopened = try await store.pickup(id: 42)
        XCTAssertEqual(reopened?.completed, false)
        XCTAssertNil(reopened?.pendingCompletion)
        let count = try await store.activeCompletionCount()
        XCTAssertEqual(count, 0)
        let next = try await store.queueCompletion(id: 42, revision: receipt.revision)
        try await store.acknowledgeCompletion(operation, snapshot: receipt)
        let current = try await store.completion(id: 42)
        XCTAssertEqual(current?.id, next.id, "A late old acknowledgement cannot clear a new intent")
    }

    func testStaleOrUnpreparedRecordsCannotQueueCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await open(directory)
        let original = try snapshot()
        try await store.save([original.pickup])
        do { _ = try await store.queueCompletion(id: 42, revision: original.revision); XCTFail() }
        catch PickupStore.StoreError.needsDownload { }
        try await store.save(snapshot(revision: "b"))
        do { _ = try await store.queueCompletion(id: 42, revision: original.revision); XCTFail() }
        catch PickupStore.StoreError.changed { }
        let operations = try await store.pendingCompletions()
        XCTAssertTrue(operations.isEmpty)
    }

    private func open(_ directory: URL) async throws -> PickupStore {
        try await PickupStore.open(directory: directory, userID: "driver", companyID: "company")
    }

    private func snapshot(revision: Character = "a") throws -> PickupSyncSnapshot {
        let pickup = try JSONDecoder().decode(Pickup.self, from: Data(#"{"id":42,"completed":false,"sender":{"name":"Sender"}}"#.utf8))
        return PickupSyncSnapshot(pickup: pickup, revision: "v1:" + String(repeating: String(revision), count: 64))
    }
}
