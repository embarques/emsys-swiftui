import Foundation

/// Payment information is an intention until the journal API confirms it.
nonisolated struct InvoiceDraftPayment: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable { case skip, record }
    enum Method: String, Codable, CaseIterable, Identifiable, Sendable {
        case cash = "CASH", deposit = "DEPOSIT", check = "CHECK", zelle = "ZELLE", creditCard = "CREDIT-CARD"
        var id: Self { self }
        var lookupID: UInt16 {
            switch self { case .cash: 1; case .deposit: 2; case .check: 3; case .zelle: 4; case .creditCard: 5 }
        }
        var title: String { "invoicePayment.method.\(rawValue)" }
        var requiresBankAccount: Bool { self != .cash }
    }
    struct Totals: Equatable, Sendable {
        let discount: Double
        let payment: Double
        let balance: Double
    }
    var mode: Mode
    var amount = ""
    var discount = "0"
    var method: Method?
    var bankAccount: InvoiceBankAccount?
    var checkNumber = ""
    var externalReference = ""
    var description = ""

    func totals(subtotal: Double) -> Totals? {
        guard subtotal.isFinite, subtotal >= 0,
              let discount = Self.money(discount), discount >= 0 else { return nil }
        let amount = mode == .skip ? 0 : Self.money(amount)
        guard let amount, amount >= 0 else { return nil }
        let balance = ((subtotal - discount - amount) * 100).rounded() / 100
        guard balance.isFinite, balance >= 0 else { return nil }
        return Totals(discount: discount, payment: amount, balance: balance)
    }

    func validationIssue(subtotal: Double) -> String? {
        guard let totals = totals(subtotal: subtotal) else { return "invoicePayment.invalidAmounts" }
        guard mode == .record, totals.payment > 0 else { return nil }
        guard let method else { return "invoicePayment.methodRequired" }
        if method.requiresBankAccount, bankAccount?.isValid != true { return "invoicePayment.bankRequired" }
        if method == .check, checkNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "invoicePayment.checkRequired"
        }
        return nil
    }

    private static func money(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = trimmed.isEmpty ? 0 : Double(trimmed)
        guard let parsed, parsed.isFinite, parsed >= 0, (parsed * 100).isFinite else { return nil }
        return (parsed * 100).rounded() / 100
    }
}
