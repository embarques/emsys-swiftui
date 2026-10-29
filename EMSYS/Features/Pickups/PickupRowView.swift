import SwiftUI

struct PickupRowView: View {
    let pickup: Pickup

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: pickup.sender?.name ?? "#\(pickup.id)").font(.headline)
                Spacer(minLength: 12)
                Image(systemName: pickup.pendingCompletion == true ? "arrow.triangle.2.circlepath" : (pickup.isComplete ? "checkmark.circle.fill" : "shippingbox"))
                    .foregroundStyle(pickup.isComplete ? .green : .secondary)
                    .accessibilityLabel(Text(pickup.pendingCompletion == true ? "pickupSync.pending" : (pickup.isComplete ? "pickups.completed" : "pickups.pending")))
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
