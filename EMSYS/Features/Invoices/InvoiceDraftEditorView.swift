import SwiftUI

struct InvoiceDraftEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NetworkConnection.self) private var connection
    @Environment(SynchronizationState.self) private var synchronization
    @State var model: InvoiceDraftEditorModel
    @State private var confirmsDiscard = false
    @State private var customerSearch: InvoiceCustomerSearchModel?
    @State private var showsSignature = false
    @State private var importsAttachment = false
    @State private var catalogSelection: CatalogSelection?

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
            .navigationTitle("invoiceCreation.title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom, spacing: 0) { wizardFooter }
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionStatusView() }
            .toolbar {
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
            .confirmationDialog("invoiceEdits.discardPrompt", isPresented: $confirmsDiscard) {
                Button("invoiceEdits.discard", role: .destructive) { dismiss() }
                Button("invoiceEdits.continueEditing", role: .cancel) { }
            }
            .fileImporter(isPresented: $importsAttachment, allowedContentTypes: InvoiceAttachment.allowedTypes) { result in
                if case .success(let url) = result { Task { await model.importAttachment(url: url) } }
            }
            .task { await model.load() }
            .onChange(of: synchronization.lastFinishedAt) { Task { await model.refreshAttachmentStatuses() } }
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
            .sheet(item: $catalogSelection) { selection in
                InvoiceItemCatalogView(model: model) { selected in
                    model.selectCatalogItem(selected, for: selection.id)
                    catalogSelection = nil
                }
            }
            .sheet(isPresented: $showsSignature) { InvoiceSenderSignatureView(model: model) }
            .onChange(of: model.didQueueCreation) {
                if model.didQueueCreation { synchronization.requestUpload(); dismiss() }
            }
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
                    Text("drafts.localHint").font(.caption).foregroundStyle(.secondary)
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
            case .payment: paymentContext; InvoicePaymentFields(model: model)
            case .review: reviewSummary; attachmentSection; policyReview; signatureReview
            }
            if !model.isLoaded && !model.isLoading {
                Button("auth.retry") { Task { await model.load() } }
            }
        }
        .formStyle(.grouped)
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
                LabeledContent("invoiceCreation.number") { Text("invoiceCreation.automaticNumber") }
        }
    }

    private var customerDetails: some View {
        @Bindable var model = model
        return Section("invoiceCreation.step.customers") {
                TextField("invoices.sender", text: Binding(
                    get: { model.content.senderName }, set: { model.setPartyName($0, role: .sender) }))
                if model.canChooseCustomers {
                    Button("customers.chooseSender") { customerSearch = model.customerSearch(role: .sender) }
                }
                customerAddress(model.content.senderCustomer, selection: $model.content.senderAddressID)
                TextField("invoices.receiver", text: Binding(
                    get: { model.content.receiverName }, set: { model.setPartyName($0, role: .receiver) }))
                if model.canChooseCustomers {
                    Button("customers.chooseReceiver") { customerSearch = model.customerSearch(role: .receiver) }
                }
                customerAddress(model.content.receiverCustomer, selection: $model.content.receiverAddressID)
                if model.isLoadingCustomerDetails { ProgressView() }
                if let issue = model.customerDetailsIssue { Text(LocalizedStringKey(issue)).foregroundStyle(.secondary) }
                if model.content.senderWriteSnapshot != nil {
                    Label("invoiceCreation.customerDetailsSaved", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.canChooseCustomers {
                    Button("invoiceCreation.refreshCustomerDetails") {
                        Task { await model.loadCustomerDetails(online: connection.status != .unavailable) }
                    }
                    .disabled(model.isLoadingCustomerDetails)
                }
        }
    }

    private var invoiceItems: some View {
        @Bindable var model = model
        return Group {
            ForEach($model.content.items) { $item in
                Section {
                    TextField("invoiceEdits.description", text: $item.name, axis: .vertical)
                    if model.canChooseCatalogItems {
                        Button { catalogSelection = CatalogSelection(id: item.id) } label: {
                            Label("itemCatalog.choose", systemImage: "list.bullet.rectangle")
                        }
                    }
                    TextField("invoices.quantity", text: $item.quantity)
                    TextField("drafts.unitPrice", text: $item.unitPrice)
                    TextField("drafts.labelCount", text: $item.labelCount)
                    TextField("drafts.totalOverride", text: $item.total)
                    Button("drafts.removeItem", role: .destructive) {
                        model.removeItem(id: item.id)
                    }
                }
                .disabled(!model.isLoaded || model.isSaving)
            }
            Button("drafts.addItem") { model.content.items.append(InvoiceDraft.Item()) }
                .disabled(!model.isLoaded || model.isSaving)
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
                get: { model.currentConfirmation?.skipSignature ?? true },
                set: { model.setSkipSignature($0) }))
            if model.currentConfirmation?.skipSignature == false {
                if let png = model.currentSenderSignature?.pngData {
                    InvoiceSignaturePreview(png: png)
                    Label("invoiceCreation.signatureCaptured", systemImage: "checkmark.circle")
                }
                Button("invoiceCreation.captureSignature") { showsSignature = true }
                    .disabled(model.content.senderCustomer?.isValid != true)
            }
        }
    }

    private var reviewSummary: some View {
        Section("invoiceCreation.step.review") {
            LabeledContent("drafts.date", value: model.content.date.apiValue)
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

    private var creationStatus: some View {
        VStack(spacing: 20) {
            if let operation = model.creation {
                Image(systemName: operation.state == .completed ? "checkmark.circle" : "clock.arrow.circlepath")
                    .font(.largeTitle).foregroundStyle(.tint)
                Text(LocalizedStringKey(operation.state.title)).font(.title2.bold())
                if let number = model.createdInvoiceNumber { Text(number).font(.headline) }
                Text(operation.state == .completed ? "invoiceCreation.confirmedHint" : "invoiceCreation.pendingHint")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
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
                if operation.state != .completed {
                    Button("invoiceCreation.retry") { Task { await model.retryCreation() } }
                        .buttonStyle(.borderedProminent).disabled(model.isSaving)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wizardFooter: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                if model.creation != nil {
                    Button("documents.close") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
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

    @ViewBuilder
    private func customerAddress(_ customer: InvoiceCustomer?, selection: Binding<String?>) -> some View {
        if let customer {
            Text("customers.selectedHint").font(.caption).foregroundStyle(.secondary)
            Picker("customers.address", selection: selection) {
                Text("customers.chooseAddress").tag(nil as String?)
                ForEach((customer.addresses ?? []).filter { $0.id != nil }) { address in
                    Text(address.displayText).tag(address.id)
                }
            }
        }
    }

    private var paymentContext: some View {
        Section("invoicePayment.location") {
            if model.canChoosePaymentLocation {
                Picker("paymentReview.region", selection: Binding(
                    get: { model.content.paymentRegion ?? "" }, set: { model.content.paymentRegion = $0 }
                )) {
                    Text("invoiceCreation.chooseLocation").tag("")
                    if let code = model.content.paymentRegion, !code.isEmpty,
                       !model.paymentLocations.contains(where: { $0.code == code }) {
                        Text(verbatim: code).tag(code)
                    }
                    ForEach(model.paymentLocations) { branch in
                        Text(verbatim: "\(branch.name ?? "") (\(branch.code ?? ""))").tag(branch.code ?? "")
                    }
                }
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
