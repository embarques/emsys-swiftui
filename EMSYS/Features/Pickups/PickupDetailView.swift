import SwiftUI

struct PickupDetailView: View {
    @Environment(NetworkConnection.self) private var connection
    @State var model: PickupDetailModel
    @Environment(SynchronizationState.self) private var synchronization
    @State private var confirmsCompletion = false
    @State private var confirmsDiscard = false
    var createInvoice: ((Pickup, String?) async throws -> InvoiceDraftEditorModel)? = nil
    @State private var invoiceEditor: InvoiceDraftEditorModel?
    @State private var choosesReceiver = false
    @State private var isPreparingInvoice = false
    @State private var invoiceIssue: String?

    var body: some View {
        Group {
            if model.isUnavailable {
                ContentUnavailableView("pickups.noLongerAvailable", systemImage: "lock")
            } else {
                detailList
            }
        }
        .navigationTitle(Text(verbatim: "#\(model.pickup.id)"))
        .toolbar {
            Button { Task { await model.refresh(online: online) } } label: {
                Label("sync.now", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading || !online)
        }
        .confirmationDialog("pickups.confirmComplete", isPresented: $confirmsCompletion, titleVisibility: .visible) {
            Button("pickups.complete") { Task { await model.complete(online: online); synchronization.requestUpload() } }
            Button("invoiceEdits.cancel", role: .cancel) { }
        } message: { Text("pickupSync.confirmHint") }
        .confirmationDialog("pickupSync.discardPrompt", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("pickupSync.useServer", role: .destructive) { Task { await model.discardRejectedCompletion() } }
            Button("invoiceEdits.cancel", role: .cancel) { }
        }
        .onChange(of: synchronization.lastFinishedAt) { Task { await model.refresh(online: false) } }
        .confirmationDialog("pickups.chooseInvoiceReceiver", isPresented: $choosesReceiver, titleVisibility: .visible) {
            ForEach(PickupInvoicePrefill.receivers(in: model.pickup), id: \.id) { receiver in
                Button(receiver.name ?? "—") { prepareInvoice(receiverID: receiver.id) }
            }
            Button("invoiceEdits.cancel", role: .cancel) { }
        }
        .modifier(InvoiceCreationPresentation(editor: $invoiceEditor))
        .task { await model.refresh(online: online) }
    }

    private var detailList: some View {
        List {
            Section {
                HStack {
                    Label(model.pickup.pendingCompletion == true ? "pickupSync.pending" : (model.pickup.isComplete ? "pickups.completed" : "pickups.pending"),
                        systemImage: model.pickup.isComplete ? "checkmark.circle.fill" : "clock")
                        .font(.headline)
                    Spacer()
                    if model.isLoading { ProgressView() }
                }
                if let date = model.pickup.date {
                    LabeledContent("pickups.date") { Text(verbatim: String(date.prefix(10))) }
                }
                if let route = model.pickup.route?.name { LabeledContent("pickups.route", value: route) }
                if let order = model.pickup.orderNumber, order > 0 {
                    LabeledContent("pickups.stop", value: String(order))
                }
                if let branch = model.pickup.branch?.name { LabeledContent("pickups.branch", value: branch) }
            }
            if let issue = model.issue {
                Section {
                    Label(LocalizedStringKey(issue), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("auth.retry") { Task { await model.refresh(online: online) } }
                        .disabled(model.isLoading || !online)
                }
            }
            Section("invoices.sender") {
                party(model.pickup.sender)
                contactActions
            }
            if let receivers = model.pickup.receivers, !receivers.isEmpty {
                Section("pickups.receivers") {
                    ForEach(Array(receivers.enumerated()), id: \.offset) { _, receiver in party(receiver) }
                }
            }
            Section("pickups.instructions") {
                if let purpose = model.pickup.purpose, !purpose.isEmpty { Text(verbatim: purpose).font(.headline) }
                ForEach(Array((model.pickup.comments ?? []).enumerated()), id: \.offset) { _, comment in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(verbatim: comment.purpose ?? "").font(.subheadline.weight(.semibold))
                            Spacer()
                            if let quantity = comment.quantity {
                                Text(verbatim: "\(quantity) \(comment.unit ?? "")").foregroundStyle(.secondary)
                            }
                        }
                        if let description = comment.description, !description.isEmpty { Text(verbatim: description) }
                    }
                    .padding(.vertical, 4)
                }
                if model.pickup.purpose?.isEmpty != false, model.pickup.comments?.isEmpty != false {
                    Text("pickups.noInstructions").foregroundStyle(.secondary)
                }
            }
            if createInvoice != nil {
                Section {
                    Button {
                        if PickupInvoicePrefill.receivers(in: model.pickup).count > 1 { choosesReceiver = true }
                        else { prepareInvoice(receiverID: nil) }
                    } label: {
                        Label("pickups.createInvoice", systemImage: "doc.badge.plus")
                            .font(.headline).padding(.vertical, 8)
                    }
                    .disabled(isPreparingInvoice || model.isLoading || model.requiresRefresh)
                    if isPreparingInvoice { ProgressView() }
                    if let invoiceIssue { Text(LocalizedStringKey(invoiceIssue)).foregroundStyle(.secondary) }
                } footer: { Text("pickups.createInvoiceHint") }
            }
            if let operation = model.completion {
                Section {
                    Label(LocalizedStringKey(operation.state.title), systemImage: "arrow.triangle.2.circlepath")
                    Text("pickupSync.retryHint").font(.caption).foregroundStyle(.secondary)
                    if model.canRetry {
                        Button("auth.retry") { Task { await model.retryCompletion() } }.disabled(!online || model.isLoading)
                    }
                    if operation.state == .needsReview {
                        Button("pickupSync.useServer") { confirmsDiscard = true }.disabled(!online || model.isLoading)
                    }
                }
            }
            if model.canPrepareCompletion {
                Section {
                    Button { confirmsCompletion = true } label: {
                        Label("pickups.complete", systemImage: "checkmark.circle")
                            .font(.headline).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
                    }
                    .disabled(!model.canComplete)
                } footer: { Text(model.revision == nil ? "pickupSync.downloadRequired" : "pickupSync.offlineHint") }
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private func prepareInvoice(receiverID: String?) {
        guard let createInvoice, !isPreparingInvoice else { return }
        isPreparingInvoice = true
        invoiceIssue = nil
        Task {
            defer { isPreparingInvoice = false }
            do { invoiceEditor = try await createInvoice(model.pickup, receiverID) }
            catch { invoiceIssue = "pickups.invoicePreparationError" }
        }
    }

    private var online: Bool { connection.status != .unavailable }

    @ViewBuilder
    private var contactActions: some View {
        if let url = model.pickup.phoneURL {
            Link(destination: url) { Label("pickups.call", systemImage: "phone").padding(.vertical, 8) }
                .labelStyle(.titleAndIcon)
        }
        if let url = model.pickup.directionsURL {
            Link(destination: url) { Label("pickups.directions", systemImage: "map").padding(.vertical, 8) }
                .labelStyle(.titleAndIcon)
        }
    }

    @ViewBuilder
    private func party(_ party: Pickup.Party?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: party?.name ?? "—").font(.headline)
            if let phone = party?.displayPhone { Text(verbatim: phone).foregroundStyle(.secondary) }
            if let address = party?.displayAddress, !address.isEmpty { Text(verbatim: address).foregroundStyle(.secondary) }
        }
        .textSelection(.enabled).padding(.vertical, 4)
    }
}
