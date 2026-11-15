import SwiftUI

struct InvoicePoolWarningView: View {
    let issue: String?
    let count: Int?
    let threshold: Int
    let openPool: () -> Void

    var body: some View {
        if issue != nil || isLow {
            VStack(alignment: .leading, spacing: 0) {
                if let issue {
                    Text(LocalizedStringKey(issue))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppStyle.Spacing.small)
                }
                if isLow {
                    Button(action: openPool) {
                        Label(count == 0 ? "invoicePool.empty" : "invoicePool.low",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, AppStyle.Spacing.small)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .background(.background, ignoresSafeAreaEdges: [])
        }
    }

    private var isLow: Bool { count.map { $0 <= threshold } ?? false }
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
