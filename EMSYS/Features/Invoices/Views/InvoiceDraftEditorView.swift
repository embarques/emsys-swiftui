import SwiftUI

struct InvoiceDraftEditorView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @Environment(NetworkConnection.self) private var connection
    @Environment(SynchronizationState.self) private var synchronization
    @Environment(AuthenticationSession.self) private var session: AuthenticationSession?
    @Environment(AppPreferences.self) private var preferences: AppPreferences?
    @State private var preview = InvoicePreviewViewModel()
    @State private var createdDetail: InvoiceDetailViewModel?
    @State var model: InvoiceDraftEditorViewModel
    @State private var confirmsDiscard = false
    @State private var customerSearch: InvoiceCustomerSearchViewModel?
    @State private var showsCloseoutSetup = false
    @State private var showsSignature = false
    @State private var importsAttachment = false
    @State private var itemBeingEdited: InvoiceDraft.Item?

    private var usesMobileEntryLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone && (model.step == .items || model.step == .payment)
        #else
        false
        #endif
    }

    private var editorTitle: LocalizedStringKey {
        if model.creation != nil { return "invoiceCreation.confirmationTitle" }
        return usesMobileEntryLayout ? LocalizedStringKey(model.step.title) : "invoiceCreation.title"
    }

    private struct PaymentCloseoutRefresh: Equatable {
        let branchID: UInt16?
        let connection: NetworkConnection.Status
    }

    /// Identifies the current Payment screen and its connection state.
    private var paymentCloseoutRefresh: PaymentCloseoutRefresh {
        let branchID = model.step == .payment && model.creation == nil ? closeoutBranch?.id : nil
        return PaymentCloseoutRefresh(branchID: branchID, connection: connection.status)
    }

    /// Presents the draft workflow and its native file picker and confirmation sheets.
    var body: some View {
        NavigationStack {
            Group {
                if model.isAvailable {
                    if let operation = model.creation {
                        InvoiceCreationConfirmationView(
                            model: model,
                            operation: operation,
                            canOpenCloseout: closeoutBranch != nil
                        )
                    } else {
                        editorForm
                    }
                } else {
                    ContentUnavailableView("auth.unavailable", systemImage: "lock")
                }
            }
            .sheet(isPresented: $showsCloseoutSetup) {
                if let session, let branch = closeoutBranch {
                    let contextID = session.contextID
                    IncomeCloseoutSetupView(branch: branch, resumesInvoice: model.creation != nil) { currency, rate in
                        try await model.openCloseout(branch: branch, currency: currency, rate: rate) {
                            session.contextID == contextID && session.user?.branch?.id == branch.id
                                && session.canOpenIncomeCloseout && connection.status != .unavailable
                        }
                    }
                }
            }
            .navigationTitle(editorTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom, spacing: 0) { wizardFooter }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if model.creation == nil, !usesMobileEntryLayout {
                        InvoicePoolCountView(count: model.availableReservations, threshold: model.poolThreshold)
                            .font(.caption).padding(.horizontal).padding(.vertical, 8)
                        if model.availableReservations == 0 {
                            Text("invoicePool.empty").font(.caption).foregroundStyle(.red).padding(.bottom, 8)
                        }
                    }
                }
                .background(.background, ignoresSafeAreaEdges: [])
            }
            .toolbar {
                if model.creation == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("invoiceEdits.cancel") {
                            if model.hasChanges { confirmsDiscard = true } else { dismiss() }
                        }
                        .disabled(model.isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("drafts.saveShort") { Task { await model.save() } }
                            .accessibilityLabel(Text("drafts.save"))
                            .disabled(!model.canSave)
                    }
                }
            }
            .confirmationDialog("invoiceEdits.discardPrompt", isPresented: $confirmsDiscard) {
                Button("invoiceEdits.discard", role: .destructive) { dismiss() }
                Button("invoiceEdits.continueEditing", role: .cancel) { }
            }
            .fileImporter(isPresented: $importsAttachment, allowedContentTypes: InvoiceAttachmentFile.allowedTypes) { result in
                // Forward a selected file to the editor. Dismissing the picker leaves the draft alone.
                if case .success(let url) = result {
                    Task {
                        await model.importAttachment(url: url)
                    }
                }
            }
            .task { await model.load() }
            .onChange(of: synchronization.lastFinishedAt) { Task {
                await model.load()
                await model.refreshCreation()
                await model.refreshAttachmentStatuses()
            } }
            .task(id: model.step) {
                if model.step == .customers { await model.loadCustomerDetails(online: connection.status != .unavailable) }
                if model.step == .payment {
                    await model.loadPaymentLocations(online: connection.status != .unavailable)
                    await model.loadBankAccounts(online: connection.status != .unavailable)
                }
                if model.step == .review, model.content.policies == nil {
                    await model.loadPolicies(online: connection.status != .unavailable)
                }
            }
            .task(id: paymentCloseoutRefresh) {
                // Refresh when Payment becomes visible or connectivity changes.
                if let branchID = paymentCloseoutRefresh.branchID, connection.status != .unavailable {
                    await model.refreshPaymentCloseout(branchID: branchID)
                }
            }
            .sheet(item: $customerSearch) { search in
                InvoiceCustomerSearchView(model: search) {
                    model.selectCustomer($0, role: search.role)
                    Task { await model.loadCustomerDetails(online: connection.status != .unavailable) }
                }
            }
            .sheet(item: $itemBeingEdited) { item in
                // Keep edits in the form until the user confirms them.
                InvoiceDraftItemForm(model: model, item: item, usesMobileLayout: usesMobileEntryLayout)
            }
            .sheet(isPresented: $showsSignature) { InvoiceSenderSignatureView(model: model) }
            .onChange(of: model.didQueueCreation) {
                if model.didQueueCreation {
                    model.acknowledgeUploadRequest()
                    synchronization.requestUpload()
                }
            }
            .task(id: model.createdInvoice?.id) {
                createdDetail = model.makeCreatedInvoiceDetail()
                if session?.canPrintInvoices == true, connection.status != .unavailable {
                    await createdDetail?.preparePrinting()
                }
            }
            .modifier(InvoicePreviewModifier(preview: preview))
            .onChange(of: session?.contextID) { preview.cancel() }
            .onChange(of: model.didSave) { if model.didSave { dismiss() } }
        }
        .interactiveDismissDisabled(model.hasChanges || model.isSaving)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    /// Presents the fields and available actions for the current wizard step.
    private var editorForm: some View {
        Form {
            if !usesMobileEntryLayout { wizardStepHeader }
            else if let pickup = model.content.pickup {
                LabeledContent("pickups.invoiceAssociation", value: "#\(pickup.id)").font(.footnote)
            }
            if model.isLoading || model.isSaving { ProgressView() }
            if let issue = model.issue {
                Text(LocalizedStringKey(issue)).foregroundStyle(.red)
                if model.hasConflict {
                    Button("drafts.saveCopy") { Task { await model.save(asCopy: true) } }
                        .disabled(!model.canSave)
                }
            }
            if let issue = model.stepIssue {
                Label(LocalizedStringKey(issue), systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
            switch model.step {
            case .details: invoiceDetails
            case .customers: customerDetails
            case .items: invoiceItems
            case .payment:
                if !usesMobileEntryLayout { paymentSummary }
                // Let authorized operators open the closeout before entering a payment.
                if closeoutBranch != nil, model.canOpenPaymentCloseout {
                    Section {
                        Button("invoiceCreation.closeout.open", systemImage: "calendar.badge.plus") {
                            showsCloseoutSetup = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(connection.status == .unavailable || model.isCheckingPaymentCloseout)
                    }
                }
                InvoicePaymentFields(model: model, usesMobileLayout: usesMobileEntryLayout)
                paymentContext
            case .review: reviewSummary; attachmentSection; policyReview; signatureReview
            }
            if !model.isLoaded && !model.isLoading {
                Button("auth.retry") { Task { await model.load() } }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 840)
        .frame(maxWidth: .infinity)
        .disabled(!model.isLoaded || model.isSaving)
    }

    private var wizardStepHeader: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(LocalizedStringKey(model.step.title), systemImage: model.step.symbol)
                        .font(.title2.bold())
                    Spacer()
                    Text("\(model.step.rawValue + 1) / \(InvoiceCreationStep.allCases.count)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(model.step.rawValue + 1), total: Double(InvoiceCreationStep.allCases.count))
                    .accessibilityLabel(Text(LocalizedStringKey(model.step.title)))
                if model.step == .details {
                    Text("drafts.localHint").font(.caption).foregroundStyle(.secondary)
                }
                if let pickup = model.content.pickup {
                    LabeledContent("pickups.invoiceAssociation", value: "#\(pickup.id)").font(.subheadline)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var attachmentSection: some View {
        Section("invoiceAttachments.title") {
            Text("invoiceAttachments.hint").font(.caption).foregroundStyle(.secondary)
            ForEach(model.content.attachments ?? []) { attachment in
                HStack {
                    Image(systemName: attachment.mimeType == "application/pdf" ? "doc.richtext" : "photo")
                    VStack(alignment: .leading) {
                        Text(attachment.name).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { Task { await model.removeAttachment(id: attachment.id) } } label: {
                        Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(Text("invoiceAttachments.remove"))
                    .disabled(!model.canAttachDocuments)
                }
            }
            Button { importsAttachment = true } label: { Label("invoiceAttachments.add", systemImage: "paperclip") }
                .disabled(!model.canAttachDocuments)
            if model.attachmentsSaved { Label("invoiceAttachments.saved", systemImage: "internaldrive").font(.caption) }
            if let issue = model.attachmentIssue { Text(LocalizedStringKey(issue)).foregroundStyle(.red) }
        }
    }

    private var invoiceDetails: some View {
        @Bindable var model = model
        return Section("invoiceCreation.step.details") {
                DatePicker("drafts.date", selection: Binding(
                    get: { model.content.date.pickerDate ?? .now },
                    set: { model.content.date = InvoiceDate(date: $0, calendar: InvoiceDate.calendar) }
                ), displayedComponents: .date)
                .environment(\.timeZone, .gmt)
                VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    Label("invoiceCreation.number", systemImage: "doc.text")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(verbatim: model.nextInvoiceNumber ?? "—").font(.headline).monospacedDigit()
                }
                .padding(.vertical, 8)
        }
    }

    private var customerDetails: some View {
        Group {
            InvoiceCustomerFields(model: model, role: .sender) {
                customerSearch = model.customerSearch(role: .sender)
            }
            InvoiceCustomerFields(model: model, role: .receiver) {
                customerSearch = model.customerSearch(role: .receiver)
            }
            Section {
                if model.isLoadingCustomerDetails { ProgressView() }
                if let issue = model.customerDetailsIssue { Text(LocalizedStringKey(issue)).foregroundStyle(.secondary) }
                if model.content.senderWriteSnapshot != nil {
                    Label("invoiceCreation.customerDetailsSaved", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.canChooseCustomers {
                    Button {
                        Task { await model.loadCustomerDetails(online: connection.status != .unavailable) }
                    } label: {
                        Label("invoiceCreation.refreshCustomerDetails", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoadingCustomerDetails)
                }
            }
        }
    }

    /// Lists the draft's items and opens the form for a new or existing line.
    private var invoiceItems: some View {
        Group {
            Section {
                // Keep each line tappable across the full width.
                ForEach(model.listedItems) { item in
                    Button {
                        itemBeingEdited = item
                    } label: {
                        invoiceItemRow(item)
                    }
                    .buttonStyle(.plain)
                }
                if model.listedItems.isEmpty {
                    Text("invoiceDetail.noItems")
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("invoices.items")
                    Spacer()
                    Button {
                        itemBeingEdited = InvoiceDraft.Item()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(Text("drafts.addItem"))
                }
            }
            // Keep the wide-layout subtotal visible below the list.
            if !usesMobileEntryLayout, let amounts = model.amounts {
                Section {
                    LabeledContent("invoiceCreation.subtotal") {
                        Text(amounts.subtotal, format: .number.precision(.fractionLength(2)))
                            .font(.title3.bold()).monospacedDigit()
                    }
                }
            }
        }
    }

    /// Shows a line's description, quantity, price and calculated total.
    private func invoiceItemRow(_ item: InvoiceDraft.Item) -> some View {
        // Let the amount wrap below the description at larger text sizes.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading))
            : AnyLayout(HStackLayout(alignment: .center))
        return HStack(spacing: AppStyle.Spacing.medium) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            layout {
                VStack(alignment: .leading, spacing: 4) {
                    if item.name.isEmpty {
                        Text("invoiceWizard.item").font(.headline)
                    } else {
                        Text(item.name).font(.headline)
                    }
                    Text("\(item.quantity) × \(item.unitPrice)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Use the same arithmetic as the item form, even alongside an incomplete line.
                if let amount = try? InvoiceDraftAmounts(items: [item]),
                   let total = amount.lineTotals[item.id] {
                    Text(total, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .accessibilityLabel(Text("invoices.total"))
                        .accessibilityValue(Text(total, format: .number.precision(.fractionLength(2))))
                }
            }
            Image(systemName: "chevron.forward")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }


    private var policyReview: some View {
        Group {
            Section("policies.title") {
                Text("policies.previewHint").font(.callout).foregroundStyle(.secondary)
                if let policies = model.content.policies {
                    if policies.isEmpty { Text("policies.none") }
                    ForEach(policies) { policy in
                        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                            Text(policy.title).font(.headline)
                            Text(policy.body).textSelection(.enabled)
                        }
                    }
                } else {
                    Text("policies.notDownloaded").foregroundStyle(.secondary)
                }
                if let issue = model.policyIssue { Text(LocalizedStringKey(issue)) }
                if model.isLoadingPolicies { ProgressView() }
                if model.canLoadPolicies {
                    Button("policies.load") {
                        Task { await model.loadPolicies(online: connection.status != .unavailable) }
                    }
                    .disabled(model.isLoadingPolicies)
                }
            }
        }
    }

    private var signatureReview: some View {
        Section("invoiceCreation.senderSignature") {
            if model.content.confirmation != nil && model.currentConfirmation == nil {
                Label("invoiceCreation.reviewChanged", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            if let policies = model.content.policies, !policies.isEmpty {
                Toggle("invoiceCreation.agreePolicies", isOn: Binding(
                    get: { model.currentConfirmation?.policiesAgreed == true },
                    set: { model.setPoliciesAgreed($0) }))
            }
            Toggle("invoiceCreation.skipSignature", isOn: Binding(
                get: { model.skipsSignature },
                set: { model.setSkipSignature($0) }))
            if !model.skipsSignature {
                if let signature = model.currentSenderSignature, let png = signature.pngData {
                    InvoiceSignaturePreview(png: png, signerName: signature.signerName,
                        capturedAt: model.content.senderSignatureCapturedAt,
                        canEdit: model.content.senderCustomer?.isValid == true && !model.isSaving,
                        edit: { showsSignature = true })
                } else {
                    Button("invoiceCreation.captureSignature") { showsSignature = true }
                        .disabled(model.content.senderCustomer?.isValid != true)
                }
            }
        }
    }

    private var paymentSummary: some View {
        Section("invoiceCreation.step.review") {
            LabeledContent("invoices.sender", value: model.content.senderName)
            if let subtotal = model.amounts?.subtotal {
                LabeledContent("invoiceCreation.subtotal") {
                    Text(subtotal, format: .number.precision(.fractionLength(2))).monospacedDigit()
                }
            }
        }
    }

    private var reviewSummary: some View {
        Section("invoiceCreation.step.review") {
            LabeledContent("drafts.date", value: model.content.date.apiValue)
            if let number = model.nextInvoiceNumber {
                LabeledContent("invoiceCreation.number") {
                    Text(verbatim: number).monospacedDigit()
                }
            }
            LabeledContent("invoices.sender", value: model.content.senderName)
            if !model.content.receiverName.isEmpty {
                LabeledContent("invoices.receiver", value: model.content.receiverName)
            }
            ForEach(model.content.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name).font(.headline)
                    HStack {
                        Text("\(item.quantity) × \(item.unitPrice)").foregroundStyle(.secondary)
                        Spacer()
                        if let total = model.amounts?.lineTotals[item.id] {
                            Text(total, format: .number.precision(.fractionLength(2))).monospacedDigit()
                        }
                    }
                }
            }
            if let amounts = model.amounts {
                LabeledContent("invoiceCreation.subtotal") {
                    Text(amounts.subtotal, format: .number.precision(.fractionLength(2))).bold().monospacedDigit()
                }
            }
            if let totals = model.paymentTotals {
                LabeledContent("invoicePayment.discount") { Text(totals.discount, format: .number.precision(.fractionLength(2))) }
                LabeledContent("invoicePayment.plannedPayment") { Text(totals.payment, format: .number.precision(.fractionLength(2))) }
                LabeledContent("invoicePayment.plannedBalance") { Text(totals.balance, format: .number.precision(.fractionLength(2))).bold() }
            }
            Text("invoiceCreation.submissionPending").font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Returns the authenticated branch when the current invoice can use its closeout.
    private var closeoutBranch: AuthenticatedUser.Branch? {
        // Exclude routed invoices assigned to another branch.
        guard let session, session.canOpenIncomeCloseout, let branch = session.user?.branch,
              let code = branch.code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let content = model.creation?.plan.content ?? model.content
        guard content.pickupRoute == nil || content.pickupRoute?.branch?.id == branch.id else {
            return nil
        }
        if let operation = model.creation, operation.plan.branch.id != branch.id {
            return nil
        }
        return branch
    }

    private var wizardFooter: some View {
        VStack(spacing: usesMobileEntryLayout ? 6 : 12) {
            if model.creation == nil, usesMobileEntryLayout {
                mobileEntryTotal
            }
            let layout = dynamicTypeSize.isAccessibilitySize && !usesMobileEntryLayout
                ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
            layout {
                if let operation = model.creation {
                    VStack(spacing: 8) {
                        if let session, let preferences, session.canPrintInvoices {
                            Button {
                                let contextID = session.contextID
                                let language = preferences.language.rawValue
                                let printedBy = session.user?.email ?? session.user?.name ?? ""
                                preview.generate(isAuthorized: { session.contextID == contextID && session.canPrintInvoices }) {
                                    if let createdDetail {
                                        return try await createdDetail.localPrintDocument(language: language, printedBy: printedBy)
                                    }
                                    return try await model.printSavedCreation(language: language, printedBy: printedBy)
                                }
                            } label: {
                                Label("invoiceCreation.printInvoice", systemImage: "printer")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(preview.isGenerating)
                        }
                        if operation.failure?.requiresCloseout == true, closeoutBranch != nil {
                            Button("invoiceCreation.closeout.open") { showsCloseoutSetup = true }
                                .buttonStyle(.bordered)
                                .disabled(model.isSaving || synchronization.isRunning)
                        }
                        if operation.state != .completed {
                            Button {
                                Task { await model.retryCreation() }
                            } label: {
                                Label("invoiceCreation.retry", systemImage: "arrow.trianglehead.clockwise.rotate.90")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isSaving || synchronization.isRunning)
                        }
                        Button("documents.close") { dismiss() }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                } else {
                    if model.step != .details {
                        Button { model.goBack() } label: {
                            if usesMobileEntryLayout {
                                Label("invoiceCreation.back", systemImage: "chevron.left")
                                    .labelStyle(.iconOnly).frame(minWidth: 24, minHeight: 44)
                            } else {
                                Label("invoiceCreation.back", systemImage: "chevron.left").frame(minHeight: 44)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    if model.step == .review {
                        Button { Task { await model.queueCreation() } } label: {
                            Label("invoiceCreation.submit", systemImage: "checkmark")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canQueueCreation)
                    } else {
                        Button { model.continueCreation() } label: {
                            Label("invoiceCreation.continue", systemImage: "chevron.right")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, usesMobileEntryLayout ? 8 : 12)
        .background(.bar)
        .disabled(!model.isAvailable || !model.isLoaded || model.isSaving || model.isLoadingPolicies)
    }

    @ViewBuilder
    private var mobileEntryTotal: some View {
        if model.step == .payment, let totals = model.paymentTotals {
            entryTotal("invoicePayment.plannedBalance", amount: totals.balance)
        } else if model.step == .items, let amounts = model.amounts {
            entryTotal("invoiceCreation.subtotal", amount: amounts.subtotal)
        }
    }

    private func entryTotal(_ title: LocalizedStringKey, amount: Double) -> some View {
        LabeledContent(title) {
            Text(amount, format: .number.precision(.fractionLength(2)))
                .font(.headline).monospacedDigit()
        }
    }

    private var paymentContext: some View {
        Section("invoicePayment.location") {
            if model.canChoosePaymentLocation {
                Picker("paymentReview.region", selection: Binding(
                    get: { model.content.paymentRegion ?? "" }, set: { model.content.paymentRegion = $0 }
                )) {
                    if model.content.paymentRegion?.isEmpty != false {
                        Text("invoiceCreation.chooseLocation").tag("")
                    }
                    if let code = model.content.paymentRegion, !code.isEmpty,
                       !model.paymentLocations.contains(where: { $0.code == code }) {
                        Text(verbatim: code).tag(code)
                    }
                    ForEach(model.paymentLocations) { branch in
                        if let code = branch.code { Text(verbatim: code).tag(code) }
                    }
                }
                .pickerStyle(.menu)
                Button("invoices.refresh") {
                    Task { await model.loadPaymentLocations(online: connection.status != .unavailable) }
                }
                .disabled(model.isLoadingPaymentLocations)
            } else if let code = model.content.paymentRegion {
                LabeledContent("paymentReview.region", value: code)
            }
            if model.isLoadingPaymentLocations { ProgressView() }
            if let issue = model.paymentLocationIssue { Text(LocalizedStringKey(issue)).foregroundStyle(.secondary) }
        }
        .disabled(!model.isLoaded || model.isSaving)
    }
}
