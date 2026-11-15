import SwiftUI

struct InvoicePoolWarningView: View {
    let issue: String?
    let count: Int?
    let threshold: Int
    let openPool: () -> Void

    /// Presents reservation status in the same panel as other app messages.
    var body: some View {
        VStack(spacing: AppStyle.Spacing.small) {
            // A failed refresh and a low local balance can be relevant at the same time.
            if let issue {
                MessagePanel(message: LocalizedStringKey(issue), icon: "exclamationmark.triangle")
            }
            if let count, count <= threshold {
                let message: LocalizedStringKey = count == 0 ? "invoicePool.empty" : "invoicePool.low"
                MessagePanel(message: message, icon: "exclamationmark.triangle",
                             actionTitle: "invoicePool.title", action: openPool)
            }
        }
    }
}

struct InvoicePoolCountView: View {
    let count: Int
    let threshold: Int

    /// Checks whether the available numbers reached the warning threshold.
    var isLow: Bool { count <= threshold }

    /// Displays the count and a warning icon when the pool is low.
    var body: some View {
        HStack {
            Label("invoicePool.available", systemImage: isLow ? "exclamationmark.triangle.fill" : "number")
            Spacer()
            Text(String(count)).monospacedDigit().fontWeight(.semibold)
        }
        .foregroundStyle(isLow ? Color.red : Color.primary)
        .accessibilityElement(children: .combine)
    }
}
