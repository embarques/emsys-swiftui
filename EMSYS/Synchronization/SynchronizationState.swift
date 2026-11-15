import Foundation
import Observation

@MainActor
@Observable
final class SynchronizationState {
    private(set) var isRunning = false
    private(set) var failed = false
    private(set) var requiresReview = false
    private(set) var lastSucceededAt: Date?
    private(set) var lastFinishedAt: Date?
    private(set) var lastDownloadedAt: Date?
    private(set) var localInvoiceDeletionVersion = 0
    private(set) var requestedUploadVersion = 0
    private(set) var completedUploadVersion = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Schedules an upload for the next available synchronization run.
    func requestUpload() {
        requestedUploadVersion += 1
    }

    /// Suspends until the current run finishes or its session is replaced.
    func waitForCurrentRun() async {
        guard isRunning else {
            return
        }
        // Keep the continuation until this operation publishes its final state.
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Runs a local deletion without overlapping the synchronization worker.
    func deleteLocalInvoice(using operation: () async throws -> Void) async throws {
        guard !isRunning else {
            throw InvoiceStore.StoreError.draftChanged
        }
        let currentGeneration = generation
        isRunning = true
        defer {
            if generation == currentGeneration {
                isRunning = false
                resumeWaiters()
            }
        }
        try await operation()
        // Only the owning session should request an invoice list refresh.
        if generation == currentGeneration {
            localInvoiceDeletionVersion += 1
        }
    }

    /// Clears the prior state when a new authenticated scope takes over.
    func useSession(_ sessionID: UUID) {
        guard self.sessionID != sessionID else {
            return
        }
        self.sessionID = sessionID
        reset()
    }

    /// Runs one operation and records its result only for the originating session.
    @discardableResult
    func synchronize(includesDownloads: Bool = true, using operation: () async throws -> Void) async -> Bool {
        guard !isRunning else {
            return false
        }
        let currentGeneration = generation
        let uploadVersion = requestedUploadVersion
        isRunning = true
        failed = false
        requiresReview = false
        do {
            try await operation()
            try Task.checkCancellation()
            guard generation == currentGeneration else {
                return true
            }
            lastSucceededAt = .now
            if includesDownloads {
                lastDownloadedAt = .now
            }
            completedUploadVersion = uploadVersion
        } catch is CancellationError {
            // A canceled window/session must not be reported as synchronized.
        } catch {
            guard generation == currentGeneration else {
                return true
            }
            failed = true
            switch error {
            case IncomeRepository.UploadError.attentionRequired,
                 InvoiceMutationUploader.UploadError.attentionRequired,
                 InvoiceCreationUploader.UploadError.attentionRequired,
                 InvoiceEditUploader.UploadError.attentionRequired,
                 InvoiceAttachmentUploader.UploadError.attentionRequired,
                 PickupCompletionUploader.UploadError.attentionRequired:
                requiresReview = true
            default:
                requiresReview = false
            }
        }
        if generation == currentGeneration {
            lastFinishedAt = .now
            isRunning = false
            resumeWaiters()
        }
        return true
    }

    /// Coalesces requests for the active session and runs any work still outstanding.
    func run(for session: AuthenticationSession, includesDownloads: Bool, canStart: () -> Bool) async {
        guard canStart() else {
            return
        }
        let sessionID = session.contextID
        useSession(sessionID)

        // An existing run can satisfy this request if it covered the same upload version.
        let uploadVersion = requestedUploadVersion
        let previousSuccess = lastSucceededAt
        let previousDownload = lastDownloadedAt
        while true {
            if isRunning {
                await waitForCurrentRun()
            }

            // The scene or session may have become inactive while this request was waiting.
            guard !Task.isCancelled, session.contextID == sessionID, canStart() else {
                return
            }
            let didSynchronize: Bool
            if includesDownloads {
                didSynchronize = lastDownloadedAt != previousDownload
            } else {
                didSynchronize = lastSucceededAt != previousSuccess
            }
            if didSynchronize, completedUploadVersion >= uploadVersion {
                return
            }

            // Only the caller that acquired the run can report its completion.
            let started = await synchronize(includesDownloads: includesDownloads) {
                try await synchronizeFeatures(session: session, sessionID: sessionID,
                    includesDownloads: includesDownloads)
            }
            if started {
                return
            }
        }
    }

    /// Synchronizes each feature authorized for this session.
    private func synchronizeFeatures(session: AuthenticationSession, sessionID: UUID,
                                     includesDownloads: Bool) async throws {
        // Invoices use either the full directory or the restricted pickup creation outbox.
        var failure: Error?
        do {
            if session.canViewInvoices {
                let access = try await session.invoiceAccess()
                if includesDownloads {
                    try await InvoiceSynchronizer(client: access.client, store: access.store).synchronize()
                } else {
                    try await InvoiceMutationUploader(client: access.client, store: access.store).synchronize()
                }
            } else if session.canCreateAssignedPickupInvoices {
                let access = try await session.invoiceAccess(allowAssignedCreation: true)
                try await InvoiceCreationUploader(client: access.client, store: access.store, assignedOnly: true).synchronize()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failure = error
        }
        // A session switch invalidates the rest of this run.
        guard session.contextID == sessionID else {
            throw APIClientError.sessionChanged
        }
        // Pickup completions retain their own authorization even when invoice upload fails.
        do {
            if session.canViewPickups && session.canUpdatePickups {
                let access = try await session.pickupAccess()
                try await PickupCompletionUploader(client: access.client, store: access.store,
                    isAuthorized: { session.contextID == sessionID && session.canUpdatePickups }).synchronize()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failure = failure ?? error
        }
        // Prepare assigned-pickup drafts only during runs that download reference data.
        do {
            if includesDownloads, session.canCreateAssignedPickupInvoices {
                let access = try await session.invoiceAccess(allowAssignedCreation: true)
                try await AssignedInvoicePreparation(client: access.client, store: access.store,
                    isAuthorized: { session.contextID == sessionID && session.canCreateAssignedPickupInvoices }).download()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failure = failure ?? error
        }
        // Submit journals only for the branch and session that started the run.
        do {
            if session.canPostIncomeJournal, let branchID = session.user?.branch?.id {
                let access = try await session.incomeAccess()
                try await IncomeRepository(client: access.client, store: access.store).upload(branchID: branchID,
                    isAuthorized: { session.contextID == sessionID && session.canPostIncomeJournal })
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failure = failure ?? error
        }
        // Allow independent workflows to run, then report the first failure.
        if let failure {
            throw failure
        }
    }

    /// Clears progress and wakes callers waiting on the previous session.
    func reset() {
        generation = UUID()
        isRunning = false
        failed = false
        requiresReview = false
        lastSucceededAt = nil
        lastFinishedAt = nil
        lastDownloadedAt = nil
        requestedUploadVersion = 0
        completedUploadVersion = 0
        resumeWaiters()
    }

    /// Wakes all callers waiting for the active operation to end.
    private func resumeWaiters() {
        let pending = waiters
        waiters = []
        // Drain the list first so resumed callers can safely wait on a later operation.
        for waiter in pending {
            waiter.resume()
        }
    }
}
