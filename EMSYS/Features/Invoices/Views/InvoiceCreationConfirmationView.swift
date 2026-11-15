import SwiftUI

/// Presents the result and recovery actions for an invoice already saved on this device.
struct InvoiceCreationConfirmationView: View {
    @Environment(SynchronizationState.self) private var synchronization
    let model: InvoiceDraftEditorViewModel
    let operation: PendingInvoiceCreation
    let canOpenCloseout: Bool

    /// Displays the confirmation and its recovery states in a scrollable surface.
    var body: some View {
        ScrollView {
            creationStatus
        }
        .background(confirmationBackground.ignoresSafeArea())
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
            // Put the saved server reason and recovery action before the invoice summary.
            if let failure = operation.failure {
                failurePanel(failure)
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

    /// Shows the failed stage and server reason with the available recovery action.
    private func failurePanel(_ failure: PendingInvoiceCreation.Failure) -> some View {
        let message = LocalizedStringKey(failure.stage.title)
        var panel = MessagePanel(message: message, icon: "exclamationmark.triangle",
                                 detail: failureDetail(failure))
        // The saved operation determines whether changing its reservation is safe.
        if operation.canReplaceInvoiceNumber {
            panel.actionTitle = "invoiceCreation.replaceNumber"
            panel.action = {
                Task {
                    await model.replaceDuplicateInvoiceNumber()
                }
            }
        }
        return panel.disabled(synchronization.isRunning)
    }

    /// Selects the most specific explanation available for the failure.
    private func failureDetail(_ failure: PendingInvoiceCreation.Failure) -> Text {
        // A closeout rejection has a localized recovery instruction.
        if failure.requiresCloseout {
            return Text(canOpenCloseout ? "invoiceCreation.closeout.required" : "invoiceCreation.closeout.ask")
        }
        if let reason = failure.message, !reason.isEmpty {
            return Text(verbatim: reason)
        }
        if let status = failure.status {
            return Text("HTTP \(status.formatted(.number.grouping(.never)))")
        }
        return Text("invoiceCreation.failure.receipt")
    }
}
