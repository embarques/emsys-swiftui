import SwiftUI

struct InvoicePoolCountView: View {
    let count: Int
    let threshold: Int

    var isLow: Bool { count <= threshold }

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
