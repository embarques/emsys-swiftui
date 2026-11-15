import Foundation
import Observation

@MainActor
@Observable
final class InvoiceDocumentViewModel: Identifiable {
    let id = UUID()
    let invoiceID: String
    private(set) var options: InvoiceSignatureOptions?
    private(set) var document: InvoiceDocument?
    private(set) var isLoading = false
    private(set) var failed = false
    private(set) var hasPendingChanges = false
    @ObservationIgnored private let repository: InvoiceDocumentRepository
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool

    /// Opens the document screen for one invoice under the active session.
    init(invoiceID: String, client: APIClient, store: InvoiceStore, isAuthorized: @escaping () -> Bool) {
        self.invoiceID = invoiceID
        self.repository = InvoiceDocumentRepository(client: client, store: store)
        self.store = store
        self.isAuthorized = isAuthorized
    }

    /// Checks whether the session can still access this invoice document.
    var isAvailable: Bool { isAuthorized() }

    /// Updates the warning for edits awaiting synchronization.
    func refreshPendingChanges() async {
        guard isAuthorized() else {
            return
        }
        do {
            // This status belongs to the current invoice and session.
            let pending = try await store.activeEdit(invoiceID: invoiceID) != nil
            if isAuthorized() {
                hasPendingChanges = pending
            }
        } catch {
            if isAuthorized() {
                failed = true
            }
        }
    }

    /// Restores the saved PDF and loads the available signature choices.
    func load() async {
        guard !isLoading, isAuthorized() else {
            return
        }
        isLoading = true
        failed = false
        defer {
            isLoading = false
        }
        do {
            // Keep the last PDF available while refreshing network-dependent options.
            let saved = try await store.latestDocument(invoiceID: invoiceID)
            try Task.checkCancellation()
            guard isAuthorized() else {
                return
            }
            document = saved
            hasPendingChanges = try await store.activeEdit(invoiceID: invoiceID) != nil
            try Task.checkCancellation()
            guard isAuthorized() else {
                return
            }
            let choice = try await repository.signatureOptions(invoiceID: invoiceID)
            try Task.checkCancellation()
            guard isAuthorized() else {
                return
            }
            options = choice
        } catch is CancellationError {
            return
        } catch {
            if isAuthorized() {
                failed = true
            }
        }
    }

    /// Generates and opens a saved document for the selected signatures.
    func generate(includeSender: Bool, receiverID: String, language: AppLanguage) async {
        guard !isLoading, isAuthorized(), let options,
              receiverID.isEmpty || options.receiverSignatures.contains(where: { $0.id == receiverID }) else {
            return
        }
        isLoading = true
        failed = false
        defer {
            isLoading = false
        }
        do {
            hasPendingChanges = try await store.activeEdit(invoiceID: invoiceID) != nil
            try Task.checkCancellation()
            guard isAuthorized() else {
                return
            }
            let selection = InvoiceSignatureSelection(invoiceID: invoiceID,
                includeSender: includeSender, receiverSignatureID: receiverID.isEmpty ? nil : receiverID)
            // Publish the document only after the repository has saved it for offline access.
            let saved = try await repository.generate(selection: selection, language: language,
                isAuthorized: isAuthorized)
            guard isAuthorized(), !Task.isCancelled else {
                return
            }
            document = saved
        } catch is CancellationError {
            return
        } catch {
            if isAuthorized() {
                failed = true
            }
        }
    }
}
