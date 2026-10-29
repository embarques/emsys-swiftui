import Foundation
import Observation

@MainActor
@Observable
final class SynchronizationState {
    private(set) var isRunning = false
    private(set) var failed = false
    private(set) var lastSucceededAt: Date?
    private(set) var lastFinishedAt: Date?
    private(set) var lastDownloadedAt: Date?
    private(set) var requestedUploadVersion = 0
    private(set) var completedUploadVersion = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    func requestUpload() {
        requestedUploadVersion += 1
    }

    func waitForCurrentRun() async {
        guard isRunning else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func useSession(_ sessionID: UUID) {
        guard self.sessionID != sessionID else { return }
        self.sessionID = sessionID
        reset()
    }

    @discardableResult
    func synchronize(includesDownloads: Bool = true, using operation: () async throws -> Void) async -> Bool {
        guard !isRunning else { return false }
        let currentGeneration = generation
        let uploadVersion = requestedUploadVersion
        isRunning = true
        failed = false
        do {
            try await operation()
            try Task.checkCancellation()
            guard generation == currentGeneration else { return true }
            lastSucceededAt = .now
            if includesDownloads { lastDownloadedAt = .now }
            completedUploadVersion = uploadVersion
        } catch is CancellationError {
            // A canceled window/session must not be reported as synchronized.
        } catch {
            guard generation == currentGeneration else { return true }
            failed = true
        }
        if generation == currentGeneration {
            lastFinishedAt = .now
            isRunning = false
            resumeWaiters()
        }
        return true
    }

    func reset() {
        generation = UUID()
        isRunning = false
        failed = false
        lastSucceededAt = nil
        lastFinishedAt = nil
        lastDownloadedAt = nil
        requestedUploadVersion = 0
        completedUploadVersion = 0
        resumeWaiters()
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}
