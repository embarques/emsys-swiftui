import Foundation
import Observation

@MainActor
@Observable
final class InvoiceDraftEditorModel: Identifiable {
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
    @ObservationIgnored private let canViewItemCatalog: () -> Bool
    @ObservationIgnored private let canViewCustomers: () -> Bool
    @ObservationIgnored private let canReviewPolicies: () -> Bool
    @ObservationIgnored private let canViewContainers: () -> Bool
    @ObservationIgnored private let canViewAssignments: (InvoiceAssignmentPermission) -> Bool
    @ObservationIgnored private let canReviewPayments: () -> Bool
    @ObservationIgnored private let financialPermission: (InvoiceFinancialPermission) -> Bool
    @ObservationIgnored private let currentBranchID: () -> UInt16?
    @ObservationIgnored private let assignedOnlyAccess: Bool

    init(assignedOnlyAccess: Bool = false, draftID: UUID? = nil, initialContent: InvoiceDraft.Content? = nil, store: InvoiceStore, client: APIClient? = nil,
         canViewItemCatalog: @escaping () -> Bool = { false },
         canViewCustomers: @escaping () -> Bool = { false }, canReviewPolicies: @escaping () -> Bool = { false },
         canViewContainers: @escaping () -> Bool = { false },
         canViewAssignments: @escaping (InvoiceAssignmentPermission) -> Bool = { _ in false },
         canReviewPayments: @escaping () -> Bool = { false }, currentBranchID: @escaping () -> UInt16? = { nil },
         financialPermission: @escaping (InvoiceFinancialPermission) -> Bool = { _ in false },
         isAuthorized: @escaping () -> Bool) {
        let content = initialContent ?? InvoiceDraft.Content()
        self.content = content
        original = initialContent == nil ? content : InvoiceDraft.Content()
        self.draftID = draftID ?? UUID()
        isLoaded = draftID == nil
        self.store = store
        self.isAuthorized = isAuthorized
        self.client = client
        self.canViewItemCatalog = canViewItemCatalog
        self.canViewCustomers = canViewCustomers
        self.canReviewPolicies = canReviewPolicies
        self.canViewContainers = canViewContainers
        self.canViewAssignments = canViewAssignments
        self.canReviewPayments = canReviewPayments
        self.currentBranchID = currentBranchID
        self.assignedOnlyAccess = assignedOnlyAccess
        self.financialPermission = financialPermission
    }

    private(set) var attachmentIssue: String?
    private(set) var attachmentsSaved = false
    private(set) var attachmentStatuses: [PendingInvoiceAttachment] = []
    var canAttachDocuments: Bool {
        !partiesAreLocked && isAvailable && financialPermission(.uploadDocument) && creation == nil && isLoaded && !isSaving && !hasConflict && !isLoadingCustomerDetails && !isLoadingPolicies && !isPreparingSignature
    }

    func importAttachment(url: URL) async {
        guard canAttachDocuments else { return }
        isSaving = true
        attachmentIssue = nil
        defer { isSaving = false }
        let submitted = content
        do {
            let prepared = try await InvoiceAttachment.prepare(url: url)
            guard isAvailable, !Task.isCancelled else { return }
            let saved = try await store.stageAttachment(prepared.attachment, bytes: prepared.bytes,
                draftID: draftID, content: submitted, expectedRevision: expectedRevision)
            guard isAvailable else { return }
            applyAttachmentSave(saved)
        } catch InvoiceStore.StoreError.draftChanged {
            hasConflict = true
            attachmentIssue = "drafts.changed"
        } catch InvoiceAttachment.AttachmentError.tooLarge {
            attachmentIssue = "invoiceAttachments.tooLarge"
        } catch InvoiceAttachment.AttachmentError.unsupportedType {
            attachmentIssue = "invoiceAttachments.unsupported"
        } catch {
            attachmentIssue = "invoiceAttachments.importError"
        }
    }

    func removeAttachment(id: UUID) async {
        guard canAttachDocuments, let expectedRevision else { return }
        isSaving = true
        attachmentIssue = nil
        defer { isSaving = false }
        do {
            let saved = try await store.removeAttachment(id: id, draftID: draftID, content: content, expectedRevision: expectedRevision)
            guard isAvailable else { return }
            applyAttachmentSave(saved)
        } catch InvoiceStore.StoreError.draftChanged {
            hasConflict = true
            attachmentIssue = "drafts.changed"
        } catch { attachmentIssue = "invoiceAttachments.importError" }
    }

    private func applyAttachmentSave(_ saved: InvoiceDraft) {
        expectedRevision = saved.revision
        content = saved.content
        original = saved.content
        attachmentsSaved = true
    }

    func refreshAttachmentStatuses() async {
        guard isAvailable else { return }
        do {
            let statuses = try await store.invoiceAttachments(draftID: draftID)
            guard isAvailable else { return }
            attachmentStatuses = statuses
        } catch { if isAvailable { attachmentIssue = "invoiceAttachments.loadError" } }
    }

    var canRetryAttachments: Bool {
        isAvailable && financialPermission(.uploadDocument) && !isSaving
            && attachmentStatuses.contains { $0.invoiceID != nil && $0.state != .completed && $0.state != .awaitingContainer }
    }

    func retryAttachments() async {
        guard isAvailable, financialPermission(.uploadDocument), !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            for attachment in attachmentStatuses where attachment.state != .completed && attachment.state != .awaitingContainer && attachment.invoiceID != nil {
                try await store.setAttachmentState(id: attachment.id, state: .pending)
            }
            guard isAvailable else { return }
            didQueueCreation = true
        } catch { attachmentIssue = "invoiceAttachments.loadError" }
    }

    private(set) var creation: PendingInvoiceCreation?
    private(set) var createdInvoiceNumber: String?
    private(set) var didQueueCreation = false
    var canQueueCreation: Bool {
        isAvailable && financialPermission(.createInvoice) && creation == nil && isLoaded
            && !isSaving && !isLoading && !isPreparingSignature && !isLoadingCustomerDetails && !isLoadingPolicies
    }

    func queueCreation() async {
        guard canQueueCreation else { return }
        for step in InvoiceCreationStep.allCases {
            if let issue = validationIssue(for: step) {
                content.wizardStep = step
                stepIssue = issue
                return
            }
        }
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
        defer { isSaving = false }
        do {
            let plan = try InvoiceCreationPlan(content: content, branch: branch)
            let operation = try await store.queueInvoiceCreation(draftID: draftID, expectedRevision: expectedRevision, plan: plan)
            guard isAvailable else { return }
            creation = operation
            original = content
            didQueueCreation = true
        } catch InvoiceStore.StoreError.draftChanged {
            if isAvailable { hasConflict = true; issue = "drafts.changed" }
        } catch InvoiceCreationPlan.PlanError.changedReview {
            if isAvailable { stepIssue = "invoiceCreation.reviewRequired" }
        } catch {
            if isAvailable { issue = "invoiceCreation.queueError" }
        }
    }

    func retryCreation() async {
        guard isAvailable, financialPermission(.createInvoice), let creation,
              creation.state != .completed, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.setInvoiceCreationState(id: creation.id, state: .pending)
            let updated = try await store.invoiceCreation(draftID: draftID)
            guard isAvailable else { return }
            self.creation = updated
            didQueueCreation = true
        } catch {
            if isAvailable { issue = "invoiceCreation.queueError" }
        }
    }

    var canRecordPayment: Bool { isAvailable && financialPermission(.recordPayment) }
    var canApplyDiscount: Bool { isAvailable && financialPermission(.applyDiscount) }
    var canChooseBankAccount: Bool { isAvailable && !bankAccountAccessDenied && financialPermission(.viewBankAccounts) && client != nil }
    var paymentTotals: InvoiceDraftPayment.Totals? {
        guard let subtotal = amounts?.subtotal else { return nil }
        return content.payment?.totals(subtotal: subtotal)
    }
    private(set) var bankAccountAccessDenied = false
    private(set) var bankAccounts: [InvoiceBankAccount] = []
    private(set) var isLoadingBankAccounts = false
    private(set) var bankAccountIssue: String?

    func setPaymentMode(_ mode: InvoiceDraftPayment.Mode) {
        guard isAvailable, !isSaving, mode != .record || canRecordPayment else { return }
        var payment = content.payment ?? InvoiceDraftPayment(mode: mode)
        payment.mode = mode
        content.payment = payment
    }

    func setPaymentMethod(_ method: InvoiceDraftPayment.Method?) {
        guard canRecordPayment, !isSaving, content.payment?.method != method else { return }
        content.payment?.method = method
        content.payment?.bankAccount = nil
        content.payment?.checkNumber = ""
        content.payment?.externalReference = ""
    }

    func selectBankAccount(id: UInt32?) {
        guard canChooseBankAccount, !isSaving else { return }
        content.payment?.bankAccount = bankAccounts.first { $0.id == id }
    }

    func loadBankAccounts(online: Bool) async {
        guard canChooseBankAccount, !isLoadingBankAccounts, let client else { return }
        isLoadingBankAccounts = true
        bankAccountIssue = nil
        defer { isLoadingBankAccounts = false }
        do {
            let cached = try await store.invoiceBankAccounts()
            guard canChooseBankAccount, !Task.isCancelled else { return }
            bankAccounts = cached
            guard online else { return }
            var downloaded: [InvoiceBankAccount] = []
            var ids: Set<UInt32> = []
            for page in 1...26 {
                let batch = try await client.get("chart-accounts", queryItems: [
                    .init(name: "page", value: String(page)), .init(name: "limit", value: "40"),
                    .init(name: "field", value: "type"), .init(name: "operator", value: "eq"),
                    .init(name: "value", value: "BANK"), .init(name: "sort", value: "id:asc")
                ], as: [InvoiceBankAccount]?.self) ?? []
                guard canChooseBankAccount, !Task.isCancelled else { return }
                guard batch.count <= 40, batch.allSatisfy(\.isValid),
                      batch.allSatisfy({ ids.insert($0.id).inserted }), downloaded.count + batch.count <= 1000 else {
                    throw APIClientError.invalidResponse
                }
                downloaded += batch
                if batch.count < 40 {
                    try await store.saveInvoiceBankAccounts(downloaded)
                    guard canChooseBankAccount, !Task.isCancelled else { return }
                    bankAccounts = downloaded
                    return
                }
            }
            throw APIClientError.invalidResponse
        } catch is CancellationError { return }
        catch APIClientError.httpStatus(let status) where [401, 403].contains(status) {
            bankAccountAccessDenied = true
            bankAccounts = []
            bankAccountIssue = "invoicePayment.permissionRequired"
        } catch {
            if canChooseBankAccount { bankAccountIssue = "invoicePayment.banksUnavailable" }
        }
    }

    @ObservationIgnored private var customerDetailsRequest = UUID()
    private(set) var isLoadingCustomerDetails = false
    private(set) var customerDetailsIssue: String?

    func loadCustomerDetails(online: Bool) async {
        guard canChooseCustomers, let client else { return }
        let request = UUID()
        customerDetailsRequest = request
        isLoadingCustomerDetails = true
        customerDetailsIssue = nil
        defer { if customerDetailsRequest == request { isLoadingCustomerDetails = false } }
        let parties: [(InvoiceCustomer.Role, InvoiceCustomer?)] = [(.sender, content.senderCustomer), (.receiver, content.receiverCustomer)]
        do {
            for (role, customer) in parties {
                guard let customer else { continue }
                guard customerDetailsRequest == request, canChooseCustomers, !Task.isCancelled else { return }
                let cached = try await store.customerWriteSnapshot(id: customer.id)
                guard customerDetailsRequest == request, canChooseCustomers, !Task.isCancelled else { return }
                if let cached, matchesCustomerDetails(cached, customer: customer) {
                    applyCustomerDetails(cached, customer: customer, role: role)
                }
                guard online else { continue }
                let expectedCustomer = (role == .sender ? content.senderCustomer : content.receiverCustomer) ?? customer
                let downloaded = try await client.get("customers/\(customer.id)", as: InvoiceCustomerWriteSnapshot.self)
                guard customerDetailsRequest == request, canChooseCustomers, !Task.isCancelled else { return }
                guard matchesCustomerDetails(downloaded, customer: customer) else { throw APIClientError.invalidResponse }
                try await store.saveCustomerWriteSnapshot(downloaded)
                guard customerDetailsRequest == request, canChooseCustomers, !Task.isCancelled else { return }
                applyCustomerDetails(downloaded, customer: expectedCustomer, role: role)
            }
            if content.senderCustomer != nil && content.senderWriteSnapshot == nil
                || content.receiverCustomer != nil && content.receiverWriteSnapshot == nil {
                if customerDetailsIssue == nil { customerDetailsIssue = "invoiceCreation.customerDetailsUnavailable" }
            }
        } catch is CancellationError { return }
        catch {
            if customerDetailsRequest == request, isAvailable { customerDetailsIssue = "invoiceCreation.customerDetailsUnavailable" }
        }
    }

    private func matchesCustomerDetails(_ snapshot: InvoiceCustomerWriteSnapshot, customer: InvoiceCustomer) -> Bool {
        if content.pickup != nil {
            // Pickup parties are historical snapshots. A customer's current name
            // may have changed; identity and party role still have to match.
            return snapshot.isValid && snapshot.id == customer.id && snapshot.customerType == customer.customerType
        }
        return snapshot.matches(customer)
    }

    private func applyCustomerDetails(_ snapshot: InvoiceCustomerWriteSnapshot, customer: InvoiceCustomer, role: InvoiceCustomer.Role) {
        let selected = role == .sender ? content.senderCustomer : content.receiverCustomer
        guard selected?.id == customer.id, selected?.name == customer.name else { return }
        var addressID = role == .sender ? content.senderAddressID : content.receiverAddressID
        // Search results may omit addresses; choose the first once details arrive.
        // A later refresh must preserve an address the operator already selected.
        if addressID == nil, selected?.addresses?.isEmpty != false {
            addressID = snapshot.addresses?.first { InvoiceWriteDocument.isObjectID($0.id ?? "") }?.id
        }
        let addressExists = addressID == nil || snapshot.addresses?.contains { $0.id == addressID } == true
        let refreshed = snapshot.publicCustomer(active: selected?.active)
        switch role {
        case .sender:
            content.senderCustomer = refreshed
            if content.pickup != nil { content.senderName = refreshed.name }
            content.senderWriteSnapshot = addressExists ? snapshot : nil
            content.senderAddressID = addressExists ? addressID : nil
        case .receiver:
            content.receiverCustomer = refreshed
            if content.pickup != nil { content.receiverName = refreshed.name }
            content.receiverWriteSnapshot = addressExists ? snapshot : nil
            content.receiverAddressID = addressExists ? addressID : nil
        }
        if !addressExists { customerDetailsIssue = "invoiceCreation.addressChanged" }
    }

    private(set) var paymentLocations: [InvoicePickupBranch] = []
    private(set) var isLoadingPaymentLocations = false
    private(set) var paymentLocationIssue: String?
    var canChoosePaymentLocation: Bool { isAvailable && canViewAssignments(.branches) && client != nil }

    func loadPaymentLocations(online: Bool) async {
        guard canChoosePaymentLocation, !isLoadingPaymentLocations, let client else { return }
        isLoadingPaymentLocations = true
        paymentLocationIssue = nil
        defer { isLoadingPaymentLocations = false }
        do {
            let cached = try await store.pickupBranches()
            guard canChoosePaymentLocation, !Task.isCancelled else { return }
            if let cached { paymentLocations = uniquePaymentLocations(cached) }
            guard online else {
                if paymentLocations.isEmpty { paymentLocationIssue = "invoiceCreation.locationsUnavailable" }
                return
            }
            let downloaded = try await InvoiceAssignmentDownloader(client: client).branches {
                canChoosePaymentLocation
            }
            guard canChoosePaymentLocation, !Task.isCancelled else { return }
            try await store.savePickupBranches(downloaded)
            guard canChoosePaymentLocation, !Task.isCancelled else { return }
            paymentLocations = uniquePaymentLocations(downloaded)
        } catch is CancellationError {
            return
        } catch {
            if canChoosePaymentLocation { paymentLocationIssue = "invoiceCreation.locationsUnavailable" }
        }
    }

    private func uniquePaymentLocations(_ branches: [InvoicePickupBranch]) -> [InvoicePickupBranch] {
        var codes: Set<String> = []
        return branches.filter {
            guard let code = $0.code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else { return false }
            return codes.insert(code).inserted
        }
    }

    var currentConfirmation: InvoiceDraftConfirmation? {
        guard let confirmation = content.confirmation, confirmation.matches(content), confirmation.isValid,
              content.senderSignature.map({ $0.isValid && $0.signerName == content.senderName }) != false else { return nil }
        return confirmation
    }

    var currentSenderSignature: InvoiceSenderSignature? {
        guard let confirmation = currentConfirmation, !confirmation.skipSignature else { return nil }
        return content.senderSignature
    }

    func setPoliciesAgreed(_ agreed: Bool) {
        guard content.policies != nil else { return }
        updateConfirmation { $0.policiesAgreed = agreed }
    }

    func setSkipSignature(_ skip: Bool) {
        updateConfirmation { $0.skipSignature = skip }
    }

    private func updateConfirmation(_ update: (inout InvoiceDraftConfirmation) -> Void) {
        guard isAvailable, isLoaded, !isSaving, !isPreparingSignature,
              let hash = try? InvoiceDraftConfirmation.contextHash(for: content) else { return }
        var confirmation = currentConfirmation ?? InvoiceDraftConfirmation(
            contextHash: hash, policiesAgreed: false, skipSignature: true)
        if currentConfirmation == nil { content.senderSignature = nil }
        update(&confirmation)
        if confirmation.skipSignature { content.senderSignature = nil }
        content.confirmation = confirmation
    }

    func captureSignature(_ drawing: SignatureDrawing) async -> Bool {
        guard isAvailable, isLoaded, !isSaving, !isPreparingSignature,
              content.senderCustomer?.isValid == true,
              let hash = try? InvoiceDraftConfirmation.contextHash(for: content) else { return false }
        isPreparingSignature = true
        defer { isPreparingSignature = false }
        do {
            let png = try await drawing.pngData()
            guard isAvailable, !Task.isCancelled,
                  (try? InvoiceDraftConfirmation.contextHash(for: content)) == hash else { return false }
            let confirmation = InvoiceDraftConfirmation(contextHash: hash,
                policiesAgreed: currentConfirmation?.policiesAgreed ?? false,
                skipSignature: false)
            let signature = InvoiceSenderSignature(signerName: content.senderName,
                data: png.base64EncodedString(), contentType: "image/png")
            guard confirmation.isValid, signature.isValid else { return false }
            content.senderSignature = signature
            content.confirmation = confirmation
            return true
        } catch { return false }
    }

    private(set) var catalogItems: [InvoiceCatalogItem] = []
    private(set) var isLoadingCatalog = false
    private(set) var catalogIssue: String?
    private(set) var catalogIsDownloaded = true

    var canChooseCatalogItems: Bool { isAvailable && canViewItemCatalog() && isLoaded && !isSaving && creation == nil }

    func loadItemCatalog(online: Bool) async {
        guard canChooseCatalogItems, !isLoadingCatalog else { return }
        isLoadingCatalog = true
        catalogIssue = nil
        catalogIsDownloaded = true
        defer { isLoadingCatalog = false }
        do {
            let saved = try await store.itemCatalog()
            guard canChooseCatalogItems, !Task.isCancelled else { return }
            catalogItems = saved
            guard online, let client else { return }
            var downloaded: [InvoiceCatalogItem] = []
            var identities: Set<UInt16> = []
            for page in 1...26 {
                guard canChooseCatalogItems else { return }
                try Task.checkCancellation()
                let batch = try await client.get("invoice-descriptions", queryItems: [
                    URLQueryItem(name: "sort", value: "createdAt:desc,id:desc"),
                    URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: "40")
                ], as: [InvoiceCatalogItem]?.self) ?? []
                guard canChooseCatalogItems, !Task.isCancelled else { return }
                guard batch.count <= 40, downloaded.count + batch.count <= 1_000,
                      batch.allSatisfy({ $0.isValid && identities.insert($0.id).inserted }) else {
                    throw APIClientError.invalidResponse
                }
                downloaded += batch
                if batch.count < 40 {
                    try await store.saveItemCatalog(downloaded)
                    guard canChooseCatalogItems, !Task.isCancelled else { return }
                    catalogItems = downloaded
                    catalogIsDownloaded = false
                    return
                }
            }
            throw APIClientError.invalidResponse
        } catch is CancellationError { return }
        catch {
            guard canChooseCatalogItems, !Task.isCancelled else { return }
            if let error = error as? APIClientError, error == .httpStatus(401) || error == .httpStatus(403) {
                catalogItems = []
                catalogIssue = "auth.unavailable"
            } else { catalogIssue = "itemCatalog.loadError" }
        }
    }

    func selectCatalogItem(_ selected: InvoiceCatalogItem, for itemID: UUID) {
        guard canChooseCatalogItems, selected.isValid,
              let index = content.items.firstIndex(where: { $0.id == itemID }) else { return }
        // Copy before mutation so bound rows never overlap exclusive array access.
        var item = content.items[index]
        item.name = selected.name
        item.unitPrice = selected.formattedPrice
        // Quantity, labels and a manually supplied total remain the user's values.
        content.items[index] = item
    }

    func removeItem(id: UUID) {
        guard isAvailable, isLoaded, !isSaving, creation == nil else { return }
        // The view resolves its bound row's ID before mutation starts. Reading
        // that row inside removeAll overlaps the array's exclusive write access.
        content.items.removeAll { $0.id == id }
    }

    var step: InvoiceCreationStep { content.wizardStep ?? .details }
    var amounts: InvoiceDraftAmounts? { try? InvoiceDraftAmounts(items: content.items) }
    private(set) var stepIssue: String?

    func goBack() {
        guard isAvailable, !isSaving, let previous = InvoiceCreationStep(rawValue: step.rawValue - 1) else { return }
        content.wizardStep = previous
        stepIssue = nil
    }

    func continueCreation() {
        guard isAvailable, isLoaded, !isSaving, !isLoadingPolicies else { return }
        if let issue = validationIssue(for: step) { stepIssue = issue; return }
        guard let next = InvoiceCreationStep(rawValue: step.rawValue + 1) else { return }
        content.wizardStep = next
        stepIssue = nil
    }

    func validationIssue(for step: InvoiceCreationStep) -> String? {
        switch step {
        case .details:
            guard content.date.pickerDate != nil else { return "invoiceCreation.dateRequired" }
        case .customers:
            if customerDetailsIssue == "invoiceCreation.addressChanged" { return "invoiceCreation.addressChanged" }
            if content.senderCustomer?.isValid != true { return "invoiceCreation.senderRequired" }
        case .items:
            if amounts == nil { return "invoiceCreation.itemsRequired" }
        case .payment:
            guard let payment = content.payment, let subtotal = amounts?.subtotal else { return "invoicePayment.chooseMode" }
            if let issue = payment.validationIssue(subtotal: subtotal) { return issue }
            guard let totals = paymentTotals else { return "invoicePayment.invalidAmounts" }
            if totals.payment > 0 && !canRecordPayment { return "invoicePayment.permissionRequired" }
            if totals.discount > 0 && !canApplyDiscount { return "invoicePayment.discountPermissionRequired" }
            if content.paymentRegion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                return "invoiceCreation.paymentRegionRequired"
            }
        case .review: break
        }
        return nil
    }

    var isAvailable: Bool { isAuthorized() && (!assignedOnlyAccess || !isLoaded || content.assignedPickup?.matches(content) == true) }
    var partiesAreLocked: Bool { content.assignedPickup != nil || assignedOnlyAccess }
    var hasChanges: Bool { isLoaded && content != original }
    var canSave: Bool { creation == nil && isAvailable && hasChanges && !isLoading && !isSaving && !isLoadingPolicies && !isPreparingSignature && !isLoadingCustomerDetails }
    var canChooseCustomers: Bool { !partiesAreLocked && isAvailable && canViewCustomers() && client != nil && isLoaded && !isSaving }
    var canLoadPolicies: Bool { isAvailable && canReviewPolicies() && client != nil && isLoaded && !isSaving }
    var canChooseContainer: Bool { isAvailable && canViewContainers() && client != nil && isLoaded && !isSaving }
    var canOpenPaymentReview: Bool { isAvailable && canReviewPayments() && client != nil && isLoaded && !isSaving }

    func paymentReviewModel() -> InvoicePaymentReviewModel? {
        guard canOpenPaymentReview, let client else { return nil }
        return InvoicePaymentReviewModel(client: client, store: store,
            isAuthorized: { [isAuthorized, canReviewPayments] in isAuthorized() && canReviewPayments() }, currentBranchID: currentBranchID)
    }

    func selectPaymentReview(_ review: InvoicePaymentReview) {
        guard canOpenPaymentReview, review.isValid, review.branchID == currentBranchID(), review.statement?.isOpen == true else { return }
        content.paymentReview = review
    }
    var canChooseAssignment: Bool {
        guard let source = content.pickupSource else { return false }
        return isAvailable && client != nil && isLoaded && !isSaving
            && canViewAssignments(source == .route ? .routes : .employees)
    }

    func setPickupSource(_ source: InvoicePickupSource?) {
        guard content.pickupSource != source else { return }
        content.pickupSource = source
        content.pickupRoute = nil
        content.pickupEmployee = nil
    }

    func assignmentPicker() -> InvoiceAssignmentPickerModel? {
        guard canChooseAssignment, let client, let source = content.pickupSource else { return nil }
        let permission: InvoiceAssignmentPermission = source == .route ? .routes : .employees
        return InvoiceAssignmentPickerModel(source: source, client: client, store: store,
            isAuthorized: { [isAuthorized, canViewAssignments] in isAuthorized() && canViewAssignments(permission) },
            canViewBranches: { [isAuthorized, canViewAssignments] in isAuthorized() && canViewAssignments(.branches) })
    }

    func selectPickupRoute(_ route: InvoicePickupRoute) {
        guard content.pickupSource == .route, canChooseAssignment, route.isValid, route.isPickup else { return }
        content.pickupRoute = route
        content.pickupEmployee = nil
    }

    func selectPickupEmployee(_ employee: InvoicePickupEmployee) {
        guard content.pickupSource == .warehouse || content.pickupSource == .office,
              canChooseAssignment, employee.isValid, employee.isEligible else { return }
        content.pickupEmployee = employee
        content.pickupRoute = nil
    }

    func containerSearch() -> InvoiceContainerSearchModel? {
        guard canChooseContainer, let client else { return nil }
        return InvoiceContainerSearchModel(client: client, store: store,
            isAuthorized: { [isAuthorized, canViewContainers] in isAuthorized() && canViewContainers() })
    }

    func selectContainer(_ container: InvoiceContainer) {
        guard canChooseContainer, container.isValid else { return }
        content.container = container
    }

    func loadPolicies(online: Bool) async {
        guard canLoadPolicies, !isLoadingPolicies, let client else { return }
        isLoadingPolicies = true
        policyIssue = nil
        defer { isLoadingPolicies = false }
        do {
            if content.policies == nil, let saved = try await store.policies() {
                guard isAvailable, canReviewPolicies(), !Task.isCancelled else { return }
                content.policies = saved
            }
            guard online else {
                if content.policies == nil { policyIssue = "policies.unavailable" }
                return
            }
            let downloaded = try await InvoicePolicyDownloader(client: client).download {
                isAvailable && canReviewPolicies()
            }
            guard isAvailable, canReviewPolicies(), !Task.isCancelled else { return }
            try await store.savePolicies(downloaded)
            guard isAvailable, canReviewPolicies(), !Task.isCancelled else { return }
            content.policies = downloaded
        } catch is CancellationError {
            return
        } catch {
            if isAvailable, canReviewPolicies() { policyIssue = "policies.unavailable" }
        }
    }

    func customerSearch(role: InvoiceCustomer.Role) -> InvoiceCustomerSearchModel? {
        guard canChooseCustomers, let client else { return nil }
        return InvoiceCustomerSearchModel(role: role, client: client, store: store,
            isAuthorized: { [isAuthorized, canViewCustomers] in isAuthorized() && canViewCustomers() })
    }

    func selectCustomer(_ customer: InvoiceCustomer, role: InvoiceCustomer.Role) {
        guard canChooseCustomers, customer.isValid, customer.customerType == role.rawValue else { return }
        let firstAddressID = customer.addresses?.first {
            InvoiceWriteDocument.isObjectID($0.id ?? "")
        }?.id
        switch role {
        case .sender:
            content.senderName = customer.name
            content.senderCustomer = customer
            content.senderWriteSnapshot = nil
            content.senderAddressID = firstAddressID
        case .receiver:
            content.receiverName = customer.name
            content.receiverCustomer = customer
            content.receiverWriteSnapshot = nil
            content.receiverAddressID = firstAddressID
        }
    }

    func setPartyName(_ name: String, role: InvoiceCustomer.Role) {
        guard !partiesAreLocked else { return }
        switch role {
        case .sender:
            if content.senderName != name { content.senderCustomer = nil; content.senderWriteSnapshot = nil; content.senderAddressID = nil }
            content.senderName = name
        case .receiver:
            if content.receiverName != name { content.receiverCustomer = nil; content.receiverWriteSnapshot = nil; content.receiverAddressID = nil }
            content.receiverName = name
        }
    }

    func load() async {
        guard !isLoaded, !isLoading, isAuthorized() else { return }
        isLoading = true
        issue = nil
        defer { isLoading = false }
        do {
            guard let draft = try await store.draft(id: draftID) else {
                if isAuthorized() { issue = "drafts.missing" }
                return
            }
            let submission = try await store.invoiceCreation(draftID: draftID)
            let created = if let id = submission?.invoiceID { try await store.invoice(id: id) } else { nil as Invoice? }
            guard isAuthorized(), !Task.isCancelled else { return }
            creation = submission
            await refreshAttachmentStatuses()
            guard isAuthorized(), !Task.isCancelled else { return }
            createdInvoiceNumber = created?.number
            content = draft.content
            original = draft.content
            expectedRevision = draft.revision
            isLoaded = true
        } catch {
            if isAuthorized(), !Task.isCancelled { issue = "drafts.loadError" }
        }
    }

    func save(asCopy: Bool = false) async {
        guard canSave, !asCopy || hasConflict else { return }
        isSaving = true
        issue = nil
        defer { isSaving = false }
        let submitted = content
        do {
            let saved = if asCopy {
                try await store.copyDraft(sourceID: draftID, content: submitted)
            } else {
                try await store.saveDraft(id: draftID, content: submitted, expectedRevision: expectedRevision)
            }
            guard isAuthorized() else { return }
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
            if isAuthorized() { issue = "drafts.saveError" }
        }
    }
}
