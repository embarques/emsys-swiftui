import SwiftUI

/// Presents the result and recovery actions for an invoice already saved on this device.
struct InvoiceCreationConfirmationView: View {
    @Environment(SynchronizationState.self) private var synchronization
    @State private var showsSyncError = false
    let model: InvoiceDraftEditorViewModel
    let operation: PendingInvoiceCreation
    let canOpenCloseout: Bool
    var isWaitingForSync = false
    var isOffline = false

    /// Displays the confirmation and its recovery states in a scrollable surface.
    var body: some View {
        ScrollView {
            creationStatus
        }
        .background(confirmationBackground.ignoresSafeArea())
        .sheet(isPresented: $showsSyncError) {
            // Present the saved API response for the currently displayed invoice.
            if let failure = syncFailure {
                syncErrorDetails(failure)
            }
        }
        .onChange(of: syncFailure != nil) { _, hasFailure in
            // Close details when successful synchronization clears the failure.
            if !hasFailure {
                showsSyncError = false
            }
        }
    }

    /// Uses the native grouped background on each platform.
    private var confirmationBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    /// Uses the platform’s grouped surface for the confirmation cards.
    private var confirmationCardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    /// Wraps a section in the confirmation screen’s standard card treatment.
    private func confirmationCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(AppStyle.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(confirmationCardBackground, in: .rect(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary) }
    }

    /// Exposes the saved failure only while the invoice awaits confirmation.
    private var syncFailure: PendingInvoiceCreation.Failure? {
        // Older builds could leave a failure on a completed invoice.
        guard operation.state != .completed else {
            return nil
        }
        return operation.failure
    }

    /// Shows the invoice status, number, and amounts from the saved operation.
    private func confirmationSummary(_ operation: PendingInvoiceCreation) -> some View {
        let completed = operation.state == .completed
        let pending = operation.state == .pending
        // Keep the symbol and its tint consistent with the server confirmation state.
        let tint: Color
        let statusIcon: String
        if completed {
            tint = .green
            statusIcon = "checkmark"
        } else if syncFailure != nil {
            tint = .orange
            statusIcon = "exclamationmark.triangle"
        } else if pending {
            tint = AppStyle.Colors.accent
            statusIcon = "clock.arrow.circlepath"
        } else {
            tint = .orange
            statusIcon = "exclamationmark"
        }
        return confirmationCard {
            VStack(spacing: AppStyle.Spacing.small) {
                Text(LocalizedStringKey(operation.state.title))
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                if operation.state != .replacementReady {
                    Text(completed ? "invoiceCreation.confirmedHint" : "invoiceCreation.pendingHint")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                // Give the complete row a touch target while an error is available.
                if syncFailure != nil {
                    syncErrorRow
                }
                Divider().padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 8) {
                    if let number = model.createdInvoiceNumber {
                        LabeledContent("invoiceCreation.number") {
                            Text(number).fontWeight(.semibold).monospacedDigit()
                        }
                    }
                    if let subtotal = model.amounts?.subtotal, let totals = model.paymentTotals {
                        LabeledContent("invoices.total") {
                            Text(subtotal - totals.discount, format: .number.precision(.fractionLength(2)))
                                .font(.title3.bold()).monospacedDigit()
                        }
                    }
                    if operation.plan.requiresJournal, operation.paymentReceipt == nil, let totals = model.paymentTotals {
                        LabeledContent("invoicePayment.plannedPayment") {
                            Text(totals.payment, format: .number.precision(.fractionLength(2))).monospacedDigit()
                        }
                    }
                }
                .multilineTextAlignment(.leading)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 30)
        }
        .overlay(alignment: .top) {
            Image(systemName: statusIcon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 66, height: 66)
                .background(tint.opacity(0.16), in: .circle)
                .background(confirmationCardBackground, in: .circle)
                .overlay { Circle().strokeBorder(confirmationCardBackground, lineWidth: 4) }
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                .offset(y: -33)
                .accessibilityHidden(true)
        }
        .padding(.top, 33)
    }

    /// Renders the parties and line items captured when the draft was queued.
    private func confirmationDetails(_ operation: PendingInvoiceCreation) -> some View {
        // Calculate the line totals once before rendering the individual rows.
        let content = operation.plan.content
        let lineTotals = model.amounts?.lineTotals
        return VStack(spacing: AppStyle.Spacing.medium) {
            confirmationCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("invoices.detailTitle", systemImage: "doc.text")
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    LabeledContent("invoices.sender", value: content.senderName)
                    if !content.receiverName.isEmpty {
                        LabeledContent("invoices.receiver", value: content.receiverName)
                    }
                    Divider()
                    LabeledContent {
                        Text(content.date.apiValue)
                    } label: {
                        Label("drafts.date", systemImage: "calendar")
                    }
                }
            }
            confirmationCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("invoiceCreation.step.items", systemImage: "shippingbox")
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(content.items) { item in
                        Divider()
                        LabeledContent {
                            if let total = lineTotals?[item.id] {
                                Text(total, format: .number.precision(.fractionLength(2))).monospacedDigit()
                            }
                        } label: {
                            Text("\(item.quantity) × \(item.name)")
                        }
                    }
                }
            }
        }
    }

    /// Presents the saved invoice, payment acknowledgement, and recovery actions.
    private var creationStatus: some View {
        VStack(spacing: 20) {
            // Give each attempt immediate feedback even before the worker starts.
            if operation.state == .completed {
                MessagePanel(message: "invoiceCreation.syncSucceeded", icon: "checkmark.circle")
            } else if isWaitingForSync && isOffline {
                MessagePanel(message: "invoiceCreation.syncOffline", icon: "wifi.slash")
            } else if isWaitingForSync || synchronization.isRunning {
                MessagePanel(message: "sync.running", icon: "arrow.trianglehead.clockwise.rotate.90")
            } else if let failure = syncFailure {
                MessagePanel(message: LocalizedStringKey(failure.stage.title),
                    icon: "exclamationmark.triangle", actionTitle: "invoiceCreation.syncError.details",
                    action: { showsSyncError = true }, detail: failure.message.map { Text(verbatim: $0) })
            } else if synchronization.failed {
                MessagePanel(message: "sync.failed", icon: "exclamationmark.triangle")
            }
            confirmationSummary(operation)
            // Show money as recorded only when the server supplied a payment receipt.
            if let receipt = operation.paymentReceipt {
                confirmationCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("invoiceCreation.paymentRecorded", systemImage: "checkmark.circle.fill")
                            .font(.headline).foregroundStyle(.green)
                        LabeledContent("navigation.dailyIncome") {
                            Text(verbatim: "#\(receipt.incomeStatement.id)").monospacedDigit()
                        }
                        LabeledContent("invoices.payment") {
                            Text(receipt.transactionAmount, format: .number.precision(.fractionLength(2)))
                                .fontWeight(.semibold).monospacedDigit()
                        }
                        if let method = operation.plan.content.payment?.method {
                            LabeledContent("invoicePayment.method") {
                                Text(LocalizedStringKey(method.title))
                            }
                        }
                    }
                }
            }
            confirmationDetails(operation)
            // A chosen replacement stays pending until the user retries synchronization.
            if operation.state == .replacementReady {
                confirmationCard {
                    HStack {
                        Text("invoiceCreation.replacementHint")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("invoiceCreation.replaceNumber") {
                            Task {
                                await model.replaceDuplicateInvoiceNumber()
                            }
                        }
                        .disabled(!model.canReplaceInvoiceNumber || synchronization.isRunning)
                    }
                }
            }
            if let issue = model.issue {
                Text(LocalizedStringKey(issue))
            }
            // File upload status is independent of invoice confirmation.
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
                    Button("invoiceAttachments.retry") {
                        Task {
                            await model.retryAttachments()
                        }
                    }
                    .disabled(!model.canRetryAttachments)
                }
            }
        }
        .padding(.horizontal, AppStyle.Spacing.medium)
        .padding(.vertical, AppStyle.Spacing.large)
        .frame(maxWidth: AppStyle.Layout.readableContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Opens the stored synchronization error from the invoice summary.
    private var syncErrorRow: some View {
        Button {
            showsSyncError = true
        } label: {
            HStack(spacing: AppStyle.Spacing.small) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("invoiceCreation.syncError.title").font(.headline)
                    Text("invoiceCreation.syncError.details").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: AppStyle.Spacing.small)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .frame(minHeight: 44)
            .padding(.horizontal, AppStyle.Spacing.small)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Shows the exact API message and any recovery action for the saved failure.
    private func syncErrorDetails(_ failure: PendingInvoiceCreation.Failure) -> some View {
        NavigationStack {
            ScrollView {
                confirmationCard {
                    VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                        Label(LocalizedStringKey(failure.stage.title), systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        if let number = model.createdInvoiceNumber {
                            LabeledContent("invoiceCreation.number", value: number)
                        }
                        Divider()
                        // Keep the actual response visible alongside any localized closeout guidance.
                        if let message = failure.message, !message.isEmpty {
                            Text("invoiceCreation.syncError.apiMessage").font(.subheadline.bold())
                            Text(verbatim: message).textSelection(.enabled)
                        } else if let status = failure.status {
                            Text("HTTP \(status.formatted(.number.grouping(.never)))")
                        } else {
                            Text("invoiceCreation.failure.receipt")
                        }
                        if failure.requiresCloseout {
                            Text(canOpenCloseout ? "invoiceCreation.closeout.required" : "invoiceCreation.closeout.ask")
                                .foregroundStyle(.secondary)
                        }
                        // Keep the existing duplicate-number recovery on the error screen.
                        if operation.canReplaceInvoiceNumber {
                            Button("invoiceCreation.replaceNumber") {
                                Task {
                                    await model.replaceDuplicateInvoiceNumber()
                                }
                            }
                            .disabled(!model.canReplaceInvoiceNumber || synchronization.isRunning)
                        }
                    }
                }
                .padding(AppStyle.Spacing.medium)
            }
            .background(confirmationBackground)
            .navigationTitle("invoiceCreation.syncError.title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("documents.close") { showsSyncError = false }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 340)
        #endif
    }
}
