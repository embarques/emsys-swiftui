import Foundation

/// Local arithmetic follows the portal's positive line totals and cent rounding.
/// It never represents payment processing or authoritative server balances.
nonisolated struct InvoiceDraftAmounts: Equatable, Sendable {
    enum ValidationError: Error { case items, quantity, price, labels, total }
    let lineTotals: [UUID: Double]
    let subtotal: Double

    /// Validates entered line values and calculates the invoice subtotal rounded to cents.
    init(items: [InvoiceDraft.Item]) throws {
        guard !items.isEmpty else {
            throw ValidationError.items
        }
        var totals: [UUID: Double] = [:]
        var subtotal = 0.0

        for item in items {
            // Every line must have a description and a unique identity.
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, totals[item.id] == nil else {
                throw ValidationError.items
            }

            // Validate the quantity, price, and label count before calculating the total.
            let quantityText = item.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let quantity = Double(quantityText), quantity.isFinite, quantity > 0 else {
                throw ValidationError.quantity
            }
            let priceText = item.unitPrice.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let price = Double(priceText), price.isFinite, price >= 0 else {
                throw ValidationError.price
            }
            guard item.resolvedLabelCount(quantity: quantity) != nil else {
                throw ValidationError.labels
            }

            // A populated line total overrides multiplication before rounding to cents.
            let enteredTotal = item.total.trimmingCharacters(in: .whitespacesAndNewlines)
            let amount: Double
            if enteredTotal.isEmpty {
                amount = quantity * price
            } else {
                guard let override = Double(enteredTotal) else {
                    throw ValidationError.total
                }
                amount = override
            }
            let cents = amount * 100
            guard amount.isFinite, amount >= 0, cents.isFinite else {
                throw ValidationError.total
            }
            let rounded = cents.rounded() / 100
            totals[item.id] = rounded
            subtotal += rounded
            guard subtotal.isFinite, (subtotal * 100).isFinite else {
                throw ValidationError.total
            }
        }

        lineTotals = totals
        self.subtotal = (subtotal * 100).rounded() / 100
    }
}
