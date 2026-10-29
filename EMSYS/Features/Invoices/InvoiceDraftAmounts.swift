import Foundation

/// Local arithmetic follows the portal's positive line totals and cent rounding.
/// It never represents payment processing or authoritative server balances.
nonisolated struct InvoiceDraftAmounts: Equatable, Sendable {
    enum ValidationError: Error { case items, quantity, price, labels, total }
    let lineTotals: [UUID: Double]
    let subtotal: Double

    init(items: [InvoiceDraft.Item]) throws {
        guard !items.isEmpty else { throw ValidationError.items }
        var totals: [UUID: Double] = [:]
        var sum = 0.0
        for item in items {
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  totals[item.id] == nil else { throw ValidationError.items }
            guard let quantity = Double(item.quantity.trimmingCharacters(in: .whitespacesAndNewlines)), quantity.isFinite, quantity > 0 else { throw ValidationError.quantity }
            guard let price = Double(item.unitPrice.trimmingCharacters(in: .whitespacesAndNewlines)), price.isFinite, price >= 0 else { throw ValidationError.price }
            let labels = item.labelCount.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (labels.isEmpty ? UInt8(exactly: quantity) : UInt8(labels)) != nil else { throw ValidationError.labels }
            let override = item.total.trimmingCharacters(in: .whitespacesAndNewlines)
            let amount = override.isEmpty ? quantity * price : Double(override) ?? .nan
            guard amount.isFinite, amount >= 0, (amount * 100).isFinite else { throw ValidationError.total }
            let rounded = (amount * 100).rounded() / 100
            totals[item.id] = rounded
            sum += rounded
            guard sum.isFinite, (sum * 100).isFinite else { throw ValidationError.total }
        }
        lineTotals = totals
        subtotal = (sum * 100).rounded() / 100
    }
}
