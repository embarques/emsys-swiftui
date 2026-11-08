import SwiftUI

struct InvoiceDraftEditorView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @Environment(NetworkConnection.self) private var connection
    @Environment(SynchronizationState.self) private var synchronization
    @Environment(AuthenticationSession.self) private var session: AuthenticationSession?
    @Environment(AppPreferences.self) private var preferences: AppPreferences?
    @State private var preview = InvoicePreviewModel()
    @State private var createdDetail: InvoiceDetailModel?
    @State var model: InvoiceDraftEditorModel
    @State private var confirmsDiscard = false
    @State private var customerSearch: InvoiceCustomerSearchModel?
    @State private var showsCloseoutSetup = false
    @State private var showsSignature = false
    @State private var importsAttachment = false
    @State private var catalogSelection: CatalogSelection?
    @State private var selectedCatalogItemRow: UUID?
    @State private var priceFocusRequest: UUID?

    private struct CatalogSelection: Identifiable { let id: UUID }

    var body: some View {
        NavigationStack {
            Group {
                if model.isAvailable {
                    if model.creation != nil { ScrollView { creationStatus } } else { editorForm }
                } else {
                    ContentUnavailableView("auth.unavailable", systemImage: "lock")
                }
            }
            .sheet(isPresented: $showsCloseoutSetup) {
                if let session, let branch = closeoutBranch {
                    let contextID = session.contextID
                    InvoiceCloseoutSetupView(branch: branch) { currency, rate in
                        try await model.openCloseout(branch: branch, currency: currency, rate: rate) {
                            session.contextID == contextID && session.user?.branch?.id == branch.id
                                && session.permissions?.contains("canCreateIncomeStatement", resourceType: "income_statement") == true
                        }
                    }
                }
            }
            .navigationTitle(model.creation == nil ? "invoiceCreation.title" : "invoiceCreation.confirmationTitle")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom, spacing: 0) { wizardFooter }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ConnectionStatusView()
                    if model.creation == nil {
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
            .fileImporter(isPresented: $importsAttachment, allowedContentTypes: InvoiceAttachment.allowedTypes) { result in
                if case .success(let url) = result { Task { await model.importAttachment(url: url) } }
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
            .sheet(item: $customerSearch) { search in
                InvoiceCustomerSearchView(model: search) {
                    model.selectCustomer($0, role: search.role)
                    Task { await model.loadCustomerDetails(online: connection.status != .unavailable) }
                }
            }
            .sheet(item: $catalogSelection, onDismiss: {
                priceFocusRequest = selectedCatalogItemRow
                selectedCatalogItemRow = nil
            }) { selection in
                InvoiceItemCatalogView(model: model) { selected in
                    if model.selectCatalogItem(selected, for: selection.id) {
                        selectedCatalogItemRow = selection.id
                    }
                    catalogSelection = nil
                }
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

    private var editorForm: some View {
        Form {
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
            case .payment: paymentSummary; InvoicePaymentFields(model: model); paymentContext
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

    private var invoiceItems: some View {
        @Bindable var model = model
        return Group {
            ForEach($model.content.items) { $item in
                let itemID = item.id
                InvoiceDraftItemFields(item: $item, priceFocusRequest: $priceFocusRequest,
                    canChooseCatalogItems: model.canChooseCatalogItems,
                    choose: { catalogSelection = CatalogSelection(id: itemID) },
                    remove: { model.removeItem(id: itemID) })
                    .disabled(!model.isLoaded || model.isSaving)
            }
            Section {
                Button { model.content.items.append(InvoiceDraft.Item()) } label: {
                    Label("drafts.addItem", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!model.isLoaded || model.isSaving)
            }
            if let amounts = model.amounts {
                Section {
                    LabeledContent("invoiceCreation.subtotal") {
                        Text(amounts.subtotal, format: .number.precision(.fractionLength(2)))
                            .font(.title3.bold()).monospacedDigit()
                    }
                }
            }
        }
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

    private var closeoutBranch: AuthenticatedUser.Branch? {
        guard let session, let branch = session.user?.branch, let operation = model.creation,
              let code = branch.code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              session.permissions?.contains("canCreateIncomeStatement", resourceType: "income_statement") == true,
              operation.plan.branch.id == branch.id,
              operation.plan.content.pickupRoute == nil || operation.plan.content.pickupRoute?.branch?.id == branch.id
        else { return nil }
        return branch
    }

    private var creationStatus: some View {
        VStack(spacing: 20) {
            if let operation = model.creation {
                VStack(alignment: .leading, spacing: 12) {
                    Label(LocalizedStringKey(operation.state.title),
                          systemImage: operation.state == .completed ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                        .font(.title2.bold())
                        .foregroundStyle(AppStyle.Colors.accent)
                    Text(operation.state == .completed ? "invoiceCreation.confirmedHint" : "invoiceCreation.pendingHint")
                        .foregroundStyle(.secondary)
                    Divider()
                    if let number = model.createdInvoiceNumber {
                        LabeledContent("invoiceCreation.number", value: number)
                    }
                    let content = operation.plan.content
                    LabeledContent("drafts.date", value: content.date.apiValue)
                    LabeledContent("invoices.sender", value: content.senderName)
                    if !content.receiverName.isEmpty {
                        LabeledContent("invoices.receiver", value: content.receiverName)
                    }
                    ForEach(content.items) { item in
                        LabeledContent {
                            if let total = model.amounts?.lineTotals[item.id] {
                                Text(total, format: .number.precision(.fractionLength(2))).monospacedDigit()
                            }
                        } label: {
                            Text("\(item.quantity) × \(item.name)")
                        }
                    }
                    Divider()
                    if let subtotal = model.amounts?.subtotal, let totals = model.paymentTotals {
                        LabeledContent("invoices.total") {
                            Text(subtotal - totals.discount, format: .number.precision(.fractionLength(2)))
                                .bold().monospacedDigit()
                        }
                    }
                }
                .padding(AppStyle.Spacing.medium)
                .background(AppStyle.Colors.surface, in: .rect(cornerRadius: AppStyle.Layout.cornerRadius))

                if operation.plan.requiresJournal, let totals = model.paymentTotals {
                    LabeledContent(operation.state == .completed ? "invoices.payment" : "invoicePayment.plannedPayment") {
                        Text(totals.payment, format: .number.precision(.fractionLength(2))).monospacedDigit()
                    }
                    .padding(AppStyle.Spacing.medium)
                    .background(AppStyle.Colors.surface, in: .rect(cornerRadius: AppStyle.Layout.cornerRadius))
                }
                if let failure = operation.failure {
                    VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                        Label(LocalizedStringKey(failure.stage.title), systemImage: "exclamationmark.circle")
                        if failure.requiresCloseout {
                            Text(closeoutBranch == nil ? "invoiceCreation.closeout.ask" : "invoiceCreation.closeout.required")
                                .font(.callout).foregroundStyle(.secondary)
                        } else if let message = failure.message, !message.isEmpty {
                            Text(verbatim: message).font(.callout).foregroundStyle(.secondary)
                        } else if let status = failure.status {
                            Text("HTTP \(status.formatted(.number.grouping(.never)))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("invoiceCreation.failure.receipt").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppStyle.Spacing.medium)
                    .background(AppStyle.Colors.surface, in: .rect(cornerRadius: AppStyle.Layout.cornerRadius))
                }
                if let issue = model.issue { Text(LocalizedStringKey(issue)) }
                if !model.attachmentStatuses.isEmpty {
                    Text("invoiceAttachments.title").font(.headline)
                    ForEach(model.attachmentStatuses) { pending in
                        VStack(spacing: 4) {
                            Label(pending.attachment.name, systemImage: pending.state == .completed ? "checkmark.circle" : "clock")
                                .font(.callout)
                            if pending.state == .awaitingContainer {
                                Text("invoiceAttachments.awaitingContainer").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if operation.state == .completed, model.attachmentStatuses.contains(where: { $0.state != .completed }) {
                        Text("invoiceAttachments.pendingHint").font(.caption).foregroundStyle(.secondary)
                        Button("invoiceAttachments.retry") { Task { await model.retryAttachments() } }
                            .disabled(!model.canRetryAttachments)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wizardFooter: some View {
        VStack(spacing: 12) {
            let layout = dynamicTypeSize.isAccessibilitySize
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
                        }
                        if operation.state != .completed {
                            Button {
                                Task { await model.retryCreation() }
                            } label: {
                                Label("invoiceCreation.retry", systemImage: "arrow.trianglehead.clockwise.rotate.90")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                        }
                        Button("documents.close") { dismiss() }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                } else {
                    if model.step != .details {
                        Button { model.goBack() } label: {
                            Label("invoiceCreation.back", systemImage: "chevron.left")
                                .frame(minHeight: 44)
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
        .padding(.vertical, 12)
        .background(.bar)
        .disabled(!model.isAvailable || !model.isLoaded || model.isSaving || model.isLoadingPolicies)
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

private struct InvoiceCloseoutSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let branch: AuthenticatedUser.Branch
    let submit: (String, Double) async throws -> Void
    @State private var currency = "USD"
    @State private var rate = ""
    @State private var isSubmitting = false
    @State private var serverMessage: String?
    @State private var failed = false

    private var needsCurrency: Bool {
        ["RD", "DR", "DO"].contains(branch.code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "")
    }

    private var exchangeRate: Double? {
        if currency == "USD" { return 1 }
        guard let value = try? Double(rate, format: .number.locale(locale)), value.isFinite, value > 0 else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(branch.name ?? branch.code ?? "")
                    if needsCurrency {
                        Picker("invoiceCreation.closeout.currency", selection: $currency) {
                            Text(verbatim: "USD").tag("USD")
                            Text(verbatim: "DOP").tag("DOP")
                        }
                        if currency == "DOP" {
                            TextField("invoiceCreation.closeout.rate", text: $rate)
                            #if os(iOS)
                                .keyboardType(.decimalPad)
                            #endif
                        }
                    } else {
                        LabeledContent("invoiceCreation.closeout.currency", value: "USD")
                        LabeledContent("invoiceCreation.closeout.rate", value: "1")
                    }
                } footer: {
                    Text("invoiceCreation.closeout.resume")
                }
                if let serverMessage {
                    Text(verbatim: serverMessage).foregroundStyle(.red)
                } else if failed {
                    Text("invoiceCreation.closeout.failed").foregroundStyle(.red)
                }
                Button("invoiceCreation.closeout.open") {
                    guard let exchangeRate else { return }
                    isSubmitting = true
                    serverMessage = nil
                    failed = false
                    Task {
                        defer { isSubmitting = false }
                        do {
                            try await submit(currency, exchangeRate)
                            dismiss()
                        } catch let error as APIServerFailure {
                            serverMessage = error.message
                            failed = true
                        } catch {
                            failed = true
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(exchangeRate == nil || isSubmitting)
            }
            .formStyle(.grouped)
            .navigationTitle("invoiceCreation.closeout.open")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("invoiceEdits.cancel") { dismiss() }.disabled(isSubmitting)
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 340)
        #endif
    }
}
