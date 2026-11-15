import Foundation
import Observation

@MainActor
@Observable
final class InvoiceDraftEditorViewModel: Identifiable {
    let id = UUID()
    var content: InvoiceDraft.Content
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isLoaded: Bool
    private(set) var didSave = false
    private(set) var hasConflict = false
    private(set) var issue: String?
    private(set) var isLoadingPolicies = false
    private(set) var isPreparingSignature = false
    private(set) var policyIssue: String?
    @ObservationIgnored private var draftID: UUID
    @ObservationIgnored private var expectedRevision: Int64?
    @ObservationIgnored private var original: InvoiceDraft.Content
    @ObservationIgnored private let store: InvoiceStore
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let client: APIClient?
    @ObservationIgnored private let draftRepository: InvoiceDraftRepository?
    @ObservationIgnored private let canViewItemCatalog: () -> Bool
    @ObservationIgnored private let canViewCustomers: () -> Bool
    @ObservationIgnored private let canReviewPolicies: () -> Bool
    @ObservationIgnored private let canViewContainers: () -> Bool
    @ObservationIgnored private let canViewAssignments: (InvoiceAssignmentPermission) -> Bool
    @ObservationIgnored private let canReviewPayments: () -> Bool
    @ObservationIgnored private let financialPermission: (InvoiceFinancialPermission) -> Bool
    @ObservationIgnored private let defaultPaymentRegion: String?
    @ObservationIgnored private let currentBranchID: () -> UInt16?
    @ObservationIgnored private let assignedOnlyAccess: Bool

    /// Opens a new or existing draft with its tenant-scoped data dependencies.
    init(assignedOnlyAccess: Bool = false, draftID: UUID? = nil, initialContent: InvoiceDraft.Content? = nil, store: InvoiceStore, client: APIClient? = nil,
         canViewItemCatalog: @escaping () -> Bool = { false },
         canViewCustomers: @escaping () -> Bool = { false }, canReviewPolicies: @escaping () -> Bool = { false },
         canViewContainers: @escaping () -> Bool = { false },
         canViewAssignments: @escaping (InvoiceAssignmentPermission) -> Bool = { _ in false },
         canReviewPayments: @escaping () -> Bool = { false }, currentBranchID: @escaping () -> UInt16? = { nil },
         defaultPaymentRegion: String? = nil,
         financialPermission: @escaping (InvoiceFinancialPermission) -> Bool = { _ in false },
         isAuthorized: @escaping () -> Bool) {
        // Initialize editable content and retain the baseline used to detect changes.
        let content = initialContent ?? InvoiceDraft.Content()
        self.content = content
        original = initialContent == nil ? content : InvoiceDraft.Content()
        self.draftID = draftID ?? UUID()
        isLoaded = draftID == nil
        self.store = store
        self.isAuthorized = isAuthorized
        self.client = client
        draftRepository = client.map { InvoiceDraftRepository(store: store, client: $0) }
        self.canViewItemCatalog = canViewItemCatalog
        self.canViewCustomers = canViewCustomers
        self.canReviewPolicies = canReviewPolicies
        self.canViewContainers = canViewContainers
        self.canViewAssignments = canViewAssignments
        self.canReviewPayments = canReviewPayments
        self.currentBranchID = currentBranchID
        self.defaultPaymentRegion = defaultPaymentRegion?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.assignedOnlyAccess = assignedOnlyAccess
        self.financialPermission = financialPermission
        // New drafts receive payment defaults before the first render.
        if isLoaded {
            applyPaymentDefaults()
        }
        if initialContent == nil {
            original = self.content
        }
    }

    // MARK: - Attachment import and upload status

    private(set) var attachmentIssue: String?
    private(set) var attachmentsSaved = false
    private(set) var attachmentStatuses: [PendingInvoiceAttachment] = []
    /// Checks whether the current draft and permissions allow file changes.
    var canAttachDocuments: Bool {
        !partiesAreLocked && isAvailable && financialPermission(.uploadDocument) && creation == nil && isLoaded && !isSaving && !hasConflict && !isLoadingCustomerDetails && !isLoadingPolicies && !isPreparingSignature
    }

    /// Imports a file into the current draft and reports preparation or save errors.
    func importAttachment(url: URL) async {
        // Lock the editor while the file is prepared and the draft revision is saved.
        guard canAttachDocuments else {
            return
        }
        isSaving = true
        attachmentIssue = nil
        defer {
            isSaving = false
        }
        let submitted = content
        do {
            // Prepare the selected file before passing it to the draft repository.
            let prepared = try await InvoiceAttachmentFile.prepare(url: url)
            guard isAvailable, !Task.isCancelled else {
                return
            }
            let saved = try await store.stageAttachment(prepared.attachment, bytes: prepared.bytes,
                draftID: draftID, content: submitted, expectedRevision: expectedRevision)
            // Apply the saved revision only if the editor still belongs to this session.
            guard isAvailable else {
                return
            }
            applyAttachmentSave(saved)
        } catch InvoiceStore.StoreError.draftChanged {
            // A stale draft needs the existing conflict recovery path.
            hasConflict = true
            attachmentIssue = "drafts.changed"
        } catch InvoiceAttachment.AttachmentError.tooLarge {
            // Tell the user to choose a smaller document.
            attachmentIssue = "invoiceAttachments.tooLarge"
        } catch InvoiceAttachment.AttachmentError.unsupportedType {
            // An unsupported file cannot be queued for upload.
            attachmentIssue = "invoiceAttachments.unsupported"
        } catch {
            // Other preparation and storage errors share the import failure message.
            attachmentIssue = "invoiceAttachments.importError"
        }
    }

    /// Deletes a staged attachment and applies the saved draft revision.
    func removeAttachment(id: UUID) async {
        guard canAttachDocuments, let expectedRevision else {
            return
        }
        isSaving = true
        attachmentIssue = nil
        defer {
            isSaving = false
        }
        do {
            let saved = try await store.removeAttachment(id: id, draftID: draftID, content: content, expectedRevision: expectedRevision)
            guard isAvailable else {
                return
            }
            applyAttachmentSave(saved)
        } catch InvoiceStore.StoreError.draftChanged {
            hasConflict = true
            attachmentIssue = "drafts.changed"
        } catch {
            attachmentIssue = "invoiceAttachments.importError"
        }
    }

    /// Updates the screen from the draft committed by the attachment transaction.
    private func applyAttachmentSave(_ saved: InvoiceDraft) {
        expectedRevision = saved.revision
        content = saved.content
        original = saved.content
        attachmentsSaved = true
    }

    /// Refreshes queued attachment states for the current draft.
    func refreshAttachmentStatuses() async {
        guard isAvailable else {
            return
        }
        do {
            let statuses = try await store.invoiceAttachments(draftID: draftID)
            guard isAvailable else {
                return
            }
            attachmentStatuses = statuses
        } catch { if isAvailable { attachmentIssue = "invoiceAttachments.loadError" } }
    }

    /// Checks whether this session can retry an unfinished attachment.
    var canRetryAttachments: Bool {
        isAvailable && financialPermission(.uploadDocument) && !isSaving
            && attachmentStatuses.contains { $0.invoiceID != nil && $0.state != .completed && $0.state != .awaitingContainer }
    }

    /// Returns eligible files to the sendable queue for another upload.
    func retryAttachments() async {
        guard isAvailable, financialPermission(.uploadDocument), !isSaving else {
            return
        }
        isSaving = true
        defer {
            isSaving = false
        }
        do {
            for attachment in attachmentStatuses where attachment.state != .completed && attachment.state != .awaitingContainer && attachment.invoiceID != nil {
                try await store.setAttachmentState(id: attachment.id, state: .pending)
            }
            guard isAvailable else {
                return
            }
            didQueueCreation = true
        } catch {
            attachmentIssue = "invoiceAttachments.loadError"
        }
    }

    private(set) var creation: PendingInvoiceCreation?
    private(set) var createdInvoiceNumber: String?
    // MARK: - Invoice submission and recovery

    private(set) var didQueueCreation = false
    private(set) var poolThreshold = 10
    private(set) var availableReservations = 0
    private(set) var nextInvoiceNumber: String?
    private(set) var createdInvoice: Invoice?

    /// Clears the screen's upload request after synchronization has accepted it.
    func acknowledgeUploadRequest() {
        didQueueCreation = false
    }

    /// Reloads the saved invoice and updates the number shown in confirmation.
    func refreshCreation() async {
        guard isAvailable, creation != nil else {
            return
        }
        do {
            guard let submission = try await store.invoiceCreation(draftID: draftID) else {
                return
            }
            // A queued operation can have a reserved number before the server assigns an ID.
            let invoice: Invoice?
            if let invoiceID = submission.invoiceID {
                invoice = try await store.invoice(id: invoiceID)
            } else {
                invoice = nil
            }
            guard isAvailable, !Task.isCancelled else {
                return
            }
            creation = submission
            createdInvoice = invoice
            createdInvoiceNumber = invoice?.number ?? submission.plan.reservation?.number
        } catch {
            if isAvailable, !Task.isCancelled {
                issue = "drafts.loadError"
            }
        }
    }

    /// Opens the confirmed invoice using the current session's dependencies.
    func makeCreatedInvoiceDetail() -> InvoiceDetailViewModel? {
        guard isAvailable, let createdInvoice, let client else {
            return nil
        }
        return InvoiceDetailViewModel(invoice: createdInvoice, client: client, store: store)
    }

    /// Checks that the form and reserved number are ready to submit.
    var canQueueCreation: Bool {
        isAvailable && nextInvoiceNumber != nil && financialPermission(.createInvoice) && creation == nil && isLoaded
            && !isSaving && !isLoading && !isPreparingSignature && !isLoadingCustomerDetails && !isLoadingPolicies
    }

    /// Validates the form and queues its draft, reservation, and first upload together.
    func queueCreation() async {
        // Keep the previewed number tied to this submission.
        guard canQueueCreation, let nextInvoiceNumber else {
            return
        }

        // Return to the first step that needs input before saving anything.
        for step in InvoiceCreationStep.allCases {
            if let issue = validationIssue(for: step) {
                content.wizardStep = step
                stepIssue = issue
                return
            }
        }
        // Verify attachment access, party details, and posting scope before creating a plan.
        guard (content.attachments ?? []).isEmpty || financialPermission(.uploadDocument) else {
            stepIssue = "invoiceAttachments.permissionRequired"
            return
        }
        guard content.senderWriteSnapshot != nil,
              content.receiverCustomer == nil || content.receiverWriteSnapshot != nil else {
            content.wizardStep = .customers
            stepIssue = "invoiceCreation.customerDetailsUnavailable"
            return
        }
        guard let branchID = currentBranchID(), branchID > 0 else {
            stepIssue = "invoiceCreation.branchRequired"
            return
        }
        let branch = AuthenticatedUser.Branch(id: branchID, name: nil, code: nil)
        isSaving = true
        issue = nil
        defer {
            isSaving = false
        }
        do {
            // The store owns the single transaction for the draft, reservation, and outbox.
            let plan = try InvoiceCreationPlan(content: content, branch: branch)
            let operation = try await store.queueInvoiceCreation(draftID: draftID, expectedRevision: expectedRevision, plan: plan,
                expectedNumber: nextInvoiceNumber)
            guard isAvailable else {
                return
            }

            // Publish the saved operation before requesting an upload.
            creation = operation
            createdInvoiceNumber = operation.plan.reservation?.number
            availableReservations = max(0, availableReservations - 1)
            self.nextInvoiceNumber = nil
            original = content
            didQueueCreation = true
        } catch InvoiceStore.StoreError.invoicePoolEmpty {
            // The pool can be exhausted by another operation after preview.
            if isAvailable {
                availableReservations = 0
                self.nextInvoiceNumber = nil
                issue = "invoicePool.empty"
            }
        } catch InvoiceStore.StoreError.invoiceNumberPreviewChanged {
            // Refresh the preview and ask the operator to confirm any replacement.
            if await refreshInvoiceNumberAvailability() {
                issue = self.nextInvoiceNumber == nil ? "invoicePool.empty" : "invoicePool.numberChanged"
            }
        } catch InvoiceStore.StoreError.draftChanged {
            // A newer saved revision must take the existing conflict path.
            if isAvailable {
                hasConflict = true
                issue = "drafts.changed"
            }
        } catch InvoiceCreationPlan.PlanError.changedReview {
            // A changed signature or policy acknowledgement requires another review.
            if isAvailable {
                stepIssue = "invoiceCreation.reviewRequired"
            }
        } catch {
            if isAvailable {
                issue = "invoiceCreation.queueError"
            }
        }
    }

    /// Opens the required closeout, then retries under the existing invoice identity.
    func openCloseout(branch: AuthenticatedUser.Branch, currency: String, rate: Double,
                      isAllowed: () -> Bool) async throws {
        // Only a blocked invoice for this branch may start closeout recovery.
        guard isAvailable, isAllowed(), !isSaving, let draftRepository, let creation,
              creation.failure?.requiresCloseout == true,
              creation.plan.branch.id == branch.id,
              creation.plan.content.pickupRoute == nil || creation.plan.content.pickupRoute?.branch?.id == branch.id,
              ["USD", "DOP"].contains(currency), rate.isFinite, rate > 0 else {
            throw APIClientError.invalidResponse
        }

        // Release the form lock before calling the normal retry action.
        let statement: InvoiceIncomeStatement
        do {
            isSaving = true
            defer {
                isSaving = false
            }
            statement = try await draftRepository.openCloseout(currency: currency, rate: rate)
        }

        // A session change or a closeout for another branch cannot authorize the retry.
        guard isAvailable, isAllowed(), !Task.isCancelled,
              statement.isOpen, statement.branch?.id == branch.id else {
            throw APIClientError.invalidResponse
        }
        await retryCreation()
    }

    /// Renders the persisted confirmed invoice or queued draft for printing.
    func printSavedCreation(language: String, printedBy: String) async throws -> InvoiceDocument {
        guard isAvailable, let operation = try await store.invoiceCreation(draftID: draftID) else {
            throw InvoicePDFRenderer.RenderError.missingInvoice
        }
        if let id = operation.invoiceID {
            return try await InvoiceLocalPrinting.generate(invoiceID: id, store: store, language: language, printedBy: printedBy)
        }
        return try await InvoiceLocalPrinting.generatePending(operation, store: store, language: language, printedBy: printedBy)
    }

    /// Checks whether the saved duplicate conflict can accept another number.
    var canReplaceInvoiceNumber: Bool {
        isAvailable && financialPermission(.createInvoice) && !isSaving && creation?.canReplaceInvoiceNumber == true
    }

    /// Reserves a new number after a duplicate rejection and awaits explicit retry.
    func replaceDuplicateInvoiceNumber() async {
        // Re-read the stored operation during replacement to enforce its latest state.
        guard canReplaceInvoiceNumber, let creation else {
            return
        }
        isSaving = true
        issue = nil
        defer {
            isSaving = false
        }

        do {
            let replacement = try await store.replaceDuplicateInvoiceNumber(creationID: creation.id)
            guard isAvailable else {
                return
            }
            self.creation = replacement
            createdInvoiceNumber = replacement.plan.reservation?.number
        } catch InvoiceStore.StoreError.invoicePoolEmpty {
            // Prompt the user to replenish the pool without changing the blocked draft.
            if isAvailable {
                issue = "invoiceCreation.replacementPoolEmpty"
            }
        } catch {
            if isAvailable {
                issue = "invoiceCreation.queueError"
            }
        }
    }

    /// Returns a saved, unconfirmed creation to the existing upload queue.
    func retryCreation() async {
        // Retain the request identity and bytes already saved with the operation.
        guard isAvailable, financialPermission(.createInvoice), let creation,
              creation.state != .completed, !isSaving else {
            return
        }
        isSaving = true
        issue = nil
        defer {
            isSaving = false
        }

        do {
            try await store.setInvoiceCreationState(id: creation.id, state: .pending)
            let updated = try await store.invoiceCreation(draftID: draftID)
            guard isAvailable else {
                return
            }
            self.creation = updated
            didQueueCreation = true
        } catch {
            if isAvailable {
                issue = "invoiceCreation.queueError"
            }
        }
    }

    // MARK: - Payment entry and funding

    /// Checks payment recording permission for this editor.
    var canRecordPayment: Bool { isAvailable && financialPermission(.recordPayment) }
    /// Checks discount permission independently of the payment grant.
    var canApplyDiscount: Bool { isAvailable && financialPermission(.applyDiscount) }
    /// Checks bank catalog access, including any explicit server denial.
    var canChooseBankAccount: Bool { isAvailable && !bankAccountAccessDenied && financialPermission(.viewBankAccounts) && client != nil }
    /// Calculates the visible payment totals from the draft subtotal.
    var paymentTotals: InvoiceDraftPayment.Totals? {
        guard let subtotal = amounts?.subtotal else {
            return nil
        }
        return content.payment?.totals(subtotal: subtotal)
    }
    private(set) var bankAccountAccessDenied = false
    private(set) var bankAccounts: [InvoiceBankAccount] = []
    private(set) var isLoadingBankAccounts = false
    private(set) var bankAccountIssue: String?

    /// Applies defaults for a draft that is still editable in this session.
    private func applyPaymentDefaults() {
        // Queued forms retain the payment details the operator already approved.
        guard isAvailable, creation == nil else {
            return
        }
        let permitsPayment = canRecordPayment
        content.applyPaymentDefaults(canRecordPayment: permitsPayment, defaultRegion: defaultPaymentRegion)
    }

    /// Updates payment mode once the user's permissions and editor state allow it.
    func setPaymentMode(_ mode: InvoiceDraftPayment.Mode) {
        // Skipping a payment remains available without permission to record one.
        guard isAvailable, !isSaving, mode != .record || canRecordPayment else {
            return
        }
        content.setPaymentMode(mode)
    }

    /// Sets the selected method and clears references tied to the previous method.
    func setPaymentMethod(_ method: InvoiceDraftPayment.Method?) {
        // Method changes are unavailable while an existing save is in progress.
        guard canRecordPayment, !isSaving else {
            return
        }
        content.setPaymentMethod(method)
    }

    /// Stores the selected available funding account in the draft.
    func selectBankAccount(id: UInt32?) {
        guard canChooseBankAccount, !isSaving else {
            return
        }
        content.payment?.bankAccount = bankAccounts.first { $0.id == id }
    }

    /// Displays saved bank accounts first and refreshes them when connected.
    func loadBankAccounts(online: Bool) async {
        // Ignore repeated loads and requests from a session without access.
        guard canChooseBankAccount, !isLoadingBankAccounts, let draftRepository else {
            return
        }
        isLoadingBankAccounts = true
        bankAccountIssue = nil
        defer {
            isLoadingBankAccounts = false
        }

        do {
            // Publish the local copy before waiting for network data.
            let cached = try await store.invoiceBankAccounts()
            guard canChooseBankAccount, !Task.isCancelled else {
                return
            }
            bankAccounts = cached
            guard online else {
                return
            }

            // The repository handles pagination, validation, and cache replacement.
            let downloaded = try await draftRepository.refreshBankAccounts {
                canChooseBankAccount
            }
            guard canChooseBankAccount, !Task.isCancelled else {
                return
            }
            bankAccounts = downloaded
        } catch is CancellationError {
            return
        } catch APIClientError.httpStatus(let status) where [401, 403].contains(status) {
            // Clear bank data after a server permission denial.
            bankAccountAccessDenied = true
            bankAccounts = []
            bankAccountIssue = "invoicePayment.permissionRequired"
        } catch {
            // Keep the cached list usable when refresh fails for another reason.
            if canChooseBankAccount {
                bankAccountIssue = "invoicePayment.banksUnavailable"
            }
        }
    }

    // MARK: - Customer detail refresh

    @ObservationIgnored private var customerDetailsRequest = UUID()
    private(set) var isLoadingCustomerDetails = false
    private(set) var customerDetailsIssue: String?

    /// Hydrates selected parties with cached or remotely refreshed write details.
    func loadCustomerDetails(online: Bool) async {
        // An editor without customer access cannot read or refresh the selected details.
        guard canChooseCustomers, let draftRepository else {
            return
        }
        let request = UUID()
        customerDetailsRequest = request
        isLoadingCustomerDetails = true
        customerDetailsIssue = nil
        defer { if customerDetailsRequest == request { isLoadingCustomerDetails = false } }
        let parties: [(InvoiceCustomer.Role, InvoiceCustomer?)] = [(.sender, content.senderCustomer), (.receiver, content.receiverCustomer)]
        do {
            for (role, customer) in parties {
                guard let customer else {
                    continue
                }
                guard customerDetailsRequest == request, canChooseCustomers, !Task.isCancelled else {
                    return
                }
                let cached = try await store.customerWriteSnapshot(id: customer.id)
                guard customerDetailsRequest == request, canChooseCustomers, !Task.isCancelled else {
                    return
                }
                if let cached, content.matchesCustomerDetails(cached, customer: customer) {
                    applyCustomerDetails(cached, customer: customer, role: role)
                }
                guard online else {
                    continue
                }
                let expectedCustomer = (role == .sender ? content.senderCustomer : content.receiverCustomer) ?? customer
                // Keep the response only while this selection still owns the request.
                let downloaded = try await draftRepository.refreshCustomer(id: customer.id, isCurrent: {
                    customerDetailsRequest == request && canChooseCustomers
                }, accepts: { snapshot in
                    content.matchesCustomerDetails(snapshot, customer: customer)
                })
                guard customerDetailsRequest == request, canChooseCustomers, !Task.isCancelled else {
                    return
                }
                applyCustomerDetails(downloaded, customer: expectedCustomer, role: role)
            }
            if content.senderCustomer != nil && content.senderWriteSnapshot == nil
                || content.receiverCustomer != nil && content.receiverWriteSnapshot == nil {
                if customerDetailsIssue == nil {
                    customerDetailsIssue = "invoiceCreation.customerDetailsUnavailable"
                }
            }
        } catch is CancellationError {
            return
        }
        catch {
            if customerDetailsRequest == request, isAvailable {
                customerDetailsIssue = "invoiceCreation.customerDetailsUnavailable"
            }
        }
    }

    /// Applies refreshed party details and reports an address that needs to be selected again.
    private func applyCustomerDetails(_ snapshot: InvoiceCustomerWriteSnapshot, customer: InvoiceCustomer, role: InvoiceCustomer.Role) {
        // The draft decides whether the selection and saved address are still usable.
        let needsAddress = content.applyCustomerDetails(snapshot, matching: customer, role: role)
        if needsAddress {
            customerDetailsIssue = "invoiceCreation.addressChanged"
        }
    }

    // MARK: - Payment locations

    private(set) var paymentLocations: [InvoicePickupBranch] = []
    private(set) var isLoadingPaymentLocations = false
    private(set) var paymentLocationIssue: String?
    /// Checks the session's permission to browse the branch catalog.
    var canChoosePaymentLocation: Bool { isAvailable && canViewAssignments(.branches) && client != nil }

    /// Loads payment locations from SQLite and refreshes them when allowed.
    func loadPaymentLocations(online: Bool) async {
        // Reuse an active load and skip users without branch access.
        guard canChoosePaymentLocation, !isLoadingPaymentLocations, let draftRepository else {
            return
        }
        isLoadingPaymentLocations = true
        paymentLocationIssue = nil
        defer {
            isLoadingPaymentLocations = false
        }
        do {
            let cached = try await store.pickupBranches()
            guard canChoosePaymentLocation, !Task.isCancelled else {
                return
            }
            if let cached {
                paymentLocations = uniquePaymentLocations(cached)
            }
            guard online else {
                if paymentLocations.isEmpty {
                    paymentLocationIssue = "invoiceCreation.locationsUnavailable"
                }
                return
            }
            // The repository updates the local branch catalog before returning it.
            let downloaded = try await draftRepository.refreshPaymentLocations {
                canChoosePaymentLocation
            }
            guard canChoosePaymentLocation, !Task.isCancelled else {
                return
            }
            paymentLocations = uniquePaymentLocations(downloaded)
        } catch is CancellationError {
            return
        } catch {
            if canChoosePaymentLocation {
                paymentLocationIssue = "invoiceCreation.locationsUnavailable"
            }
        }
    }

    /// Keeps the first branch for each nonempty location code.
    private func uniquePaymentLocations(_ branches: [InvoicePickupBranch]) -> [InvoicePickupBranch] {
        var codes: Set<String> = []
        return branches.filter {
            guard let code = $0.code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
                return false
            }
            return codes.insert(code).inserted
        }
    }

    // MARK: - Policy and signature confirmation

    /// Returns the acknowledgment only while it still matches the draft.
    var currentConfirmation: InvoiceDraftConfirmation? {
        content.validConfirmation
    }

    /// Returns the saved signature choice or the platform's default.
    var skipsSignature: Bool {
        currentConfirmation?.skipSignature ?? defaultsToSkippingSignature
    }

    /// Returns the default review choice for the platform's signature workflow.
    private var defaultsToSkippingSignature: Bool {
        #if os(iOS)
        return false
        #else
        return true
        #endif
    }

    /// Returns a valid signature belonging to the current acknowledgment.
    var currentSenderSignature: InvoiceSenderSignature? {
        guard let confirmation = currentConfirmation, !confirmation.skipSignature else {
            return nil
        }
        return content.senderSignature
    }

    /// Records whether the sender agreed to the downloaded policies.
    func setPoliciesAgreed(_ agreed: Bool) {
        guard content.policies != nil else {
            return
        }
        updateConfirmation { $0.policiesAgreed = agreed }
    }

    /// Records the signature choice made during invoice review.
    func setSkipSignature(_ skip: Bool) {
        updateConfirmation { $0.skipSignature = skip }
    }

    /// Updates the acknowledgment after checking the context it belongs to.
    private func updateConfirmation(_ update: (inout InvoiceDraftConfirmation) -> Void) {
        guard isAvailable, isLoaded, !isSaving, !isPreparingSignature,
              let hash = try? InvoiceDraftConfirmation.contextHash(for: content) else {
            return
        }
        // Let the draft invalidate a signature whenever the review context changes.
        content.updateConfirmation(contextHash: hash, defaultSkip: defaultsToSkippingSignature, apply: update)
    }

    /// Renders the drawing and stores it only if the draft context is still current.
    func captureSignature(_ drawing: SignatureDrawing) async -> Bool {
        guard isAvailable, isLoaded, !isSaving, !isPreparingSignature,
              content.senderCustomer?.isValid == true,
              let hash = try? InvoiceDraftConfirmation.contextHash(for: content) else {
            return false
        }
        let capturedAt = Date.now
        isPreparingSignature = true
        defer {
            isPreparingSignature = false
        }
        do {
            // Recheck the context after rendering because the editor can change while suspended.
            let png = try await drawing.pngData()
            guard isAvailable, !Task.isCancelled,
                  (try? InvoiceDraftConfirmation.contextHash(for: content)) == hash else {
                return false
            }
            let confirmation = InvoiceDraftConfirmation(contextHash: hash,
                policiesAgreed: currentConfirmation?.policiesAgreed ?? false,
                skipSignature: false)
            let signature = InvoiceSenderSignature(signerName: content.senderName,
                data: png.base64EncodedString(), contentType: "image/png")
            guard confirmation.isValid, signature.isValid else {
                return false
            }
            content.senderSignature = signature
            content.senderSignatureCapturedAt = capturedAt
            content.confirmation = confirmation
            return true
        } catch {
            return false
        }
    }

    // MARK: - Invoice items and catalog

    private(set) var catalogItems: [InvoiceCatalogItem] = []
    private(set) var isLoadingCatalog = false
    private(set) var catalogIssue: String?
    private(set) var catalogIsDownloaded = true

    /// Checks item catalog access while the draft remains editable.
    var canChooseCatalogItems: Bool { isAvailable && canViewItemCatalog() && isLoaded && !isSaving && creation == nil }

    /// Displays the local item catalog and refreshes it when the API is available.
    func loadItemCatalog(online: Bool) async {
        // Keep one load active for this editor.
        guard canChooseCatalogItems, !isLoadingCatalog else {
            return
        }
        isLoadingCatalog = true
        catalogIssue = nil
        catalogIsDownloaded = true
        defer {
            isLoadingCatalog = false
        }

        do {
            // Allow item selection from the previous download while offline.
            let saved = try await store.itemCatalog()
            guard canChooseCatalogItems, !Task.isCancelled else {
                return
            }
            catalogItems = saved
            guard online, let draftRepository else {
                return
            }

            // Replace the displayed list only after the repository saves all pages.
            let downloaded = try await draftRepository.refreshItemCatalog {
                canChooseCatalogItems
            }
            guard canChooseCatalogItems, !Task.isCancelled else {
                return
            }
            catalogItems = downloaded
            catalogIsDownloaded = false
        } catch is CancellationError {
            return
        } catch {
            // A permission denial clears cached results. Other errors leave them available.
            guard canChooseCatalogItems, !Task.isCancelled else {
                return
            }
            if let apiError = error as? APIClientError, apiError == .httpStatus(401) || apiError == .httpStatus(403) {
                catalogItems = []
                catalogIssue = "auth.unavailable"
            } else {
                catalogIssue = "itemCatalog.loadError"
            }
        }
    }

    /// Copies a catalog item's description and price into the selected row.
    func selectCatalogItem(_ selected: InvoiceCatalogItem, for itemID: UUID) -> Bool {
        guard canChooseCatalogItems, selected.isValid,
              let index = content.items.firstIndex(where: { $0.id == itemID }) else {
            return false
        }
        // Copy before mutation so bound rows never overlap exclusive array access.
        var item = content.items[index]
        item.name = selected.name
        item.unitPrice = selected.formattedPrice
        // Quantity, labels and a manually supplied total remain the user's values.
        content.items[index] = item
        return true
    }

    /// Removes the chosen row from an editable draft.
    func removeItem(id: UUID) {
        guard isAvailable, isLoaded, !isSaving, creation == nil else {
            return
        }
        // The view resolves its bound row's ID before mutation starts. Reading
        // that row inside removeAll overlaps the array's exclusive write access.
        content.items.removeAll { $0.id == id }
    }

    // MARK: - Wizard navigation and validation

    /// Returns the current wizard step or the first step for an unsaved draft.
    var step: InvoiceCreationStep { content.wizardStep ?? .details }

    /// Calculates draft totals when the line-item values are valid.
    var amounts: InvoiceDraftAmounts? { try? InvoiceDraftAmounts(items: content.items) }
    private(set) var stepIssue: String?

    /// Returns to the preceding wizard step and clears its transient error.
    func goBack() {
        guard isAvailable, !isSaving, let previous = InvoiceCreationStep(rawValue: step.rawValue - 1) else {
            return
        }
        content.wizardStep = previous
        stepIssue = nil
    }

    /// Validates the current step before advancing to the next one.
    func continueCreation() {
        guard isAvailable, isLoaded, !isSaving, !isLoadingPolicies else {
            return
        }
        if let issue = validationIssue(for: step) {
            stepIssue = issue
            return
        }
        guard let next = InvoiceCreationStep(rawValue: step.rawValue + 1) else {
            return
        }
        content.wizardStep = next
        stepIssue = nil
    }

    /// Returns the message for the first condition blocking this step.
    func validationIssue(for step: InvoiceCreationStep) -> String? {
        switch step {
        case .details:
            guard content.date.pickerDate != nil else {
                return "invoiceCreation.dateRequired"
            }
        case .customers:
            if customerDetailsIssue == "invoiceCreation.addressChanged" {
                return "invoiceCreation.addressChanged"
            }
            if content.senderCustomer?.isValid != true {
                return "invoiceCreation.senderRequired"
            }
        case .items:
            if amounts == nil {
                return "invoiceCreation.itemsRequired"
            }
        case .payment:
            guard let payment = content.payment, let subtotal = amounts?.subtotal else {
                return "invoicePayment.chooseMode"
            }
            if let issue = payment.validationIssue(subtotal: subtotal) {
                return issue
            }
            guard let totals = paymentTotals else {
                return "invoicePayment.invalidAmounts"
            }
            if totals.payment > 0 && !canRecordPayment {
                return "invoicePayment.permissionRequired"
            }
            if totals.discount > 0 && !canApplyDiscount {
                return "invoicePayment.discountPermissionRequired"
            }
            if content.paymentRegion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                return "invoiceCreation.paymentRegionRequired"
            }
        case .review:
            if !skipsSignature && currentSenderSignature == nil {
                return "invoiceCreation.signatureRequired"
            }
        }
        return nil
    }

    // MARK: - Editor access and related screens

    /// Checks the current authorization and assigned-pickup scope.
    var isAvailable: Bool {
        guard isAuthorized() else {
            return false
        }

        // Allow the initial read so a restricted user can open an assigned draft.
        if !assignedOnlyAccess || !isLoaded {
            return true
        }
        return content.assignedPickup?.matches(content) == true
    }

    /// Identifies drafts whose parties are fixed by a pickup assignment.
    var partiesAreLocked: Bool { content.assignedPickup != nil || assignedOnlyAccess }
    /// Compares the editable draft with its last saved revision.
    var hasChanges: Bool { isLoaded && content != original }
    /// Checks whether the editor can persist changes to the current draft.
    var canSave: Bool {
        // Once queued, the saved submission owns the draft's remaining changes.
        guard creation == nil, isAvailable, hasChanges else {
            return false
        }

        // A suspended operation may still update the draft and its saved revision.
        return !isLoading && !isSaving && !isLoadingPolicies
            && !isPreparingSignature && !isLoadingCustomerDetails
    }

    /// Checks whether this editor may search for and change invoice parties.
    var canChooseCustomers: Bool { !partiesAreLocked && isAvailable && canViewCustomers() && client != nil && isLoaded && !isSaving }
    /// Checks whether policy review can load in the current session.
    var canLoadPolicies: Bool { isAvailable && canReviewPolicies() && client != nil && isLoaded && !isSaving }
    /// Checks whether the editor can browse available containers.
    var canChooseContainer: Bool { isAvailable && canViewContainers() && client != nil && isLoaded && !isSaving }
    /// Checks whether payment review is available for this draft.
    var canOpenPaymentReview: Bool { isAvailable && canReviewPayments() && client != nil && isLoaded && !isSaving }

    /// Creates a payment review scoped to the current branch and session.
    func paymentReviewModel() -> InvoicePaymentReviewViewModel? {
        guard canOpenPaymentReview, let client else {
            return nil
        }
        return InvoicePaymentReviewViewModel(client: client, store: store,
            isAuthorized: { [isAuthorized, canReviewPayments] in isAuthorized() && canReviewPayments() }, currentBranchID: currentBranchID)
    }

    /// Applies a valid open-period review for the current branch.
    func selectPaymentReview(_ review: InvoicePaymentReview) {
        guard canOpenPaymentReview, review.isValid, review.branchID == currentBranchID(), review.statement?.isOpen == true else {
            return
        }
        content.paymentReview = review
    }
    /// Checks assignment permissions for the selected pickup source.
    var canChooseAssignment: Bool {
        guard let source = content.pickupSource else {
            return false
        }
        return isAvailable && client != nil && isLoaded && !isSaving
            && canViewAssignments(source == .route ? .routes : .employees)
    }

    /// Updates the source and clears assignments from the previous source.
    func setPickupSource(_ source: InvoicePickupSource?) {
        guard content.pickupSource != source else {
            return
        }
        content.pickupSource = source
        content.pickupRoute = nil
        content.pickupEmployee = nil
    }

    /// Opens the assignment choices appropriate for the selected pickup source.
    func assignmentPicker() -> InvoiceAssignmentPickerViewModel? {
        guard canChooseAssignment, let client, let source = content.pickupSource else {
            return nil
        }
        let permission: InvoiceAssignmentPermission = source == .route ? .routes : .employees
        return InvoiceAssignmentPickerViewModel(source: source, client: client, store: store,
            isAuthorized: { [isAuthorized, canViewAssignments] in isAuthorized() && canViewAssignments(permission) },
            canViewBranches: { [isAuthorized, canViewAssignments] in isAuthorized() && canViewAssignments(.branches) })
    }

    /// Applies a valid pickup route and clears an incompatible employee selection.
    func selectPickupRoute(_ route: InvoicePickupRoute) {
        guard content.pickupSource == .route, canChooseAssignment, route.isValid, route.isPickup else {
            return
        }
        content.pickupRoute = route
        content.pickupEmployee = nil
    }

    /// Applies an eligible employee in place of a previous route selection.
    func selectPickupEmployee(_ employee: InvoicePickupEmployee) {
        guard content.pickupSource == .warehouse || content.pickupSource == .office,
              canChooseAssignment, employee.isValid, employee.isEligible else {
            return
        }
        content.pickupEmployee = employee
        content.pickupRoute = nil
    }

    /// Opens the authorized container catalog search.
    func containerSearch() -> InvoiceContainerSearchViewModel? {
        guard canChooseContainer, let client else {
            return nil
        }
        return InvoiceContainerSearchViewModel(client: client, store: store,
            isAuthorized: { [isAuthorized, canViewContainers] in isAuthorized() && canViewContainers() })
    }

    /// Applies the selected container to this draft.
    func selectContainer(_ container: InvoiceContainer) {
        guard canChooseContainer, container.isValid else {
            return
        }
        content.container = container
    }

    /// Prepares the policy text shown during invoice review.
    func loadPolicies(online: Bool) async {
        // The signed-in user must have permission to review the policies.
        guard canLoadPolicies, !isLoadingPolicies, let draftRepository else {
            return
        }
        isLoadingPolicies = true
        policyIssue = nil
        defer {
            isLoadingPolicies = false
        }
        do {
            if content.policies == nil, let saved = try await store.policies() {
                guard isAvailable, canReviewPolicies(), !Task.isCancelled else {
                    return
                }
                content.policies = saved
            }
            guard online else {
                if content.policies == nil {
                    policyIssue = "policies.unavailable"
                }
                return
            }
            // Keep the downloaded list available for offline review.
            let downloaded = try await draftRepository.refreshPolicies {
                isAvailable && canReviewPolicies()
            }
            guard isAvailable, canReviewPolicies(), !Task.isCancelled else {
                return
            }
            content.policies = downloaded
        } catch is CancellationError {
            return
        } catch {
            if isAvailable, canReviewPolicies() {
                policyIssue = "policies.unavailable"
            }
        }
    }

    /// Opens a customer lookup for the requested invoice party role.
    func customerSearch(role: InvoiceCustomer.Role) -> InvoiceCustomerSearchViewModel? {
        guard canChooseCustomers, let client else {
            return nil
        }
        return InvoiceCustomerSearchViewModel(role: role, client: client, store: store,
            isAuthorized: { [isAuthorized, canViewCustomers] in isAuthorized() && canViewCustomers() })
    }

    /// Assigns a customer to the selected party field when the editor allows it.
    func selectCustomer(_ customer: InvoiceCustomer, role: InvoiceCustomer.Role) {
        // Validate the role before copying the selected search result.
        guard canChooseCustomers, customer.isValid, customer.customerType == role.rawValue else {
            return
        }
        content.selectCustomer(customer, role: role)
    }

    /// Updates the visible name and clears stale party data when the name changes.
    func setPartyName(_ name: String, role: InvoiceCustomer.Role) {
        // A pickup-assigned draft keeps its original authorized parties.
        guard !partiesAreLocked else {
            return
        }
        content.setPartyName(name, role: role)
    }

    // MARK: - Offline draft and reservation state

    /// Updates the preview from the current offline reservation pool.
    @discardableResult
    private func refreshInvoiceNumberAvailability() async -> Bool {
        guard isAuthorized() else {
            return false
        }
        do {
            let threshold = try await store.invoicePoolThreshold()
            let availability = try await store.invoiceNumberAvailability()
            guard isAuthorized(), !Task.isCancelled else {
                return false
            }
            availableReservations = availability.count
            nextInvoiceNumber = availability.nextNumber
            poolThreshold = threshold
            return true
        } catch {
            guard isAuthorized(), !Task.isCancelled else {
                return false
            }
            availableReservations = 0
            nextInvoiceNumber = nil
            issue = "invoicePool.loadError"
            return false
        }
    }

    /// Restores the saved draft, submission state, and attachment information.
    func load() async {
        guard await refreshInvoiceNumberAvailability() else {
            return
        }
        guard !isLoaded, !isLoading else {
            return
        }
        isLoading = true
        issue = nil
        defer {
            isLoading = false
        }
        do {
            guard let draft = try await store.draft(id: draftID) else {
                if isAuthorized() {
                    issue = "drafts.missing"
                }
                return
            }
            let submission = try await store.invoiceCreation(draftID: draftID)
            // An offline submission may still have only its reserved number.
            let created: Invoice?
            if let invoiceID = submission?.invoiceID {
                created = try await store.invoice(id: invoiceID)
            } else {
                created = nil
            }
            guard isAuthorized(), !Task.isCancelled else {
                return
            }
            // Use the persisted submission when resolving each attachment's status.
            creation = submission
            await refreshAttachmentStatuses()
            guard isAuthorized(), !Task.isCancelled else {
                return
            }
            createdInvoice = created
            createdInvoiceNumber = created?.number ?? submission?.plan.reservation?.number
            content = draft.content
            applyPaymentDefaults()
            original = content
            expectedRevision = draft.revision
            isLoaded = true
        } catch {
            if isAuthorized(), !Task.isCancelled {
                issue = "drafts.loadError"
            }
        }
    }

    /// Persists the current draft or creates a copy to recover from an editing conflict.
    func save(asCopy: Bool = false) async {
        guard canSave, !asCopy || hasConflict else {
            return
        }
        isSaving = true
        issue = nil
        defer {
            isSaving = false
        }
        let submitted = content
        do {
            let saved = if asCopy {
                try await store.copyDraft(sourceID: draftID, content: submitted)
            } else {
                try await store.saveDraft(id: draftID, content: submitted, expectedRevision: expectedRevision)
            }
            guard isAuthorized() else {
                return
            }
            draftID = saved.id
            expectedRevision = saved.revision
            original = saved.content
            hasConflict = false
            didSave = true
        } catch InvoiceStore.StoreError.draftChanged {
            if isAuthorized() {
                hasConflict = true
                issue = "drafts.changed"
            }
        } catch {
            if isAuthorized() {
                issue = "drafts.saveError"
            }
        }
    }
}
