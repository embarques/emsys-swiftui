import SwiftUI

struct PickupRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let pickup: Pickup
    var invoiceNumbers: [String] = []

    private var invoiceLabels: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(invoiceNumbers, id: \.self) { number in
                Label {
                    Text(verbatim: number).monospacedDigit()
                } icon: {
                    Image(systemName: "doc.text")
                }
                .accessibilityLabel(Text("invoiceCreation.number"))
                .accessibilityValue(Text(verbatim: number))
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(AppStyle.Colors.accent)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: pickup.sender?.name ?? "#\(pickup.id)").font(.headline)
                Spacer(minLength: 12)
                if !invoiceNumbers.isEmpty, !dynamicTypeSize.isAccessibilitySize { invoiceLabels }
                Image(systemName: pickup.pendingCompletion == true ? "arrow.triangle.2.circlepath" : (pickup.isComplete ? "checkmark.circle.fill" : "shippingbox"))
                    .foregroundStyle(pickup.isComplete ? .green : .secondary)
                    .accessibilityLabel(Text(pickup.pendingCompletion == true ? "pickupSync.pending" : (pickup.isComplete ? "pickups.completed" : "pickups.pending")))
            }
            if !invoiceNumbers.isEmpty, dynamicTypeSize.isAccessibilitySize {
                invoiceLabels.frame(maxWidth: .infinity, alignment: .trailing)
            }
            if pickup.pendingCompletion == true { Text("pickupSync.pending").font(.caption).foregroundStyle(.secondary) }
            if let address = pickup.sender?.displayAddress, !address.isEmpty {
                Text(verbatim: address).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Text(verbatim: "#\(pickup.id)")
                if let date = pickup.date { Text(verbatim: String(date.prefix(10))) }
                Spacer()
                if let route = pickup.route?.name { Text(verbatim: route).lineLimit(1) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }
}
