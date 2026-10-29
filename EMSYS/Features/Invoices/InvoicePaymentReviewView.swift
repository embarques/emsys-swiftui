import SwiftUI

struct InvoicePaymentReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NetworkConnection.self) private var connection
    @State var model: InvoicePaymentReviewModel
    let select: (InvoicePaymentReview) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.isAvailable { reviewContent }
                else { ContentUnavailableView("auth.unavailable", systemImage: "lock") }
            }
            .navigationTitle("paymentReview.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("invoiceEdits.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("paymentReview.use") {
                        guard model.canSelect, let review = model.review else { return }
                        select(review)
                        dismiss()
                    }
                    .disabled(!model.canSelect)
                }
            }
            .task { await model.load(online: false) }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private var reviewContent: some View {
        Form {
            Text("paymentReview.hint").foregroundStyle(.secondary)
            if let branch = model.branchID { LabeledContent("pickupAssignment.branch", value: String(branch)) }
            if let date = model.day.pickerDate {
                LabeledContent("drafts.date") { Text(date, style: .date).environment(\.timeZone, .gmt) }
            }
            if model.isShowingDownloaded { Text("paymentReview.cachedHint").font(.callout).foregroundStyle(.secondary) }
            if let issue = model.issue { Text(LocalizedStringKey(issue)) }
            if model.isLoading { ProgressView() }
            if let review = model.review {
                if let statement = review.statement {
                    LabeledContent("paymentReview.statement", value: String(statement.id))
                    if let name = statement.branch?.name { LabeledContent("pickupAssignment.branch", value: name) }
                    LabeledContent("paymentReview.status") { status(statement.status) }
                    if let currency = statement.currency { LabeledContent("paymentReview.currency", value: currency) }
                } else {
                    Text("paymentReview.none")
                }
                LabeledContent("paymentReview.downloadedAt") { Text(review.downloadedAt, format: .dateTime) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("paymentReview.refresh") {
                Task { await model.load(online: connection.status != .unavailable) }
            }
            .disabled(model.isLoading)
        }
        .formStyle(.grouped)
    }

    private func status(_ value: String?) -> Text {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "open": Text("paymentReview.open")
        case "closing": Text("paymentReview.closing")
        case "closed": Text("paymentReview.closed")
        default: value.map { Text($0) } ?? Text("paymentReview.unknownStatus")
        }
    }
}
