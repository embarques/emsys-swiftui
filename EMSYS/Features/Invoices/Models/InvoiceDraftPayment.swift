import Foundation

/// Payment information is an intention until the journal API confirms it.
nonisolated struct InvoiceDraftPayment: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable { case skip, record }
    enum Method: String, Codable, CaseIterable, Identifiable, Sendable {
        case cash = "CASH", deposit = "DEPOSIT", check = "CHECK", zelle = "ZELLE", creditCard = "CREDIT-CARD"
        var id: Self { self }
        /// Returns the method identifier from the API's payment catalog.
        var lookupID: UInt16 {
            switch self {
            case .cash:
                1
            case .deposit:
                3
            case .check:
                2
            case .zelle:
                4
            case .creditCard:
                5
            }
        }
        var symbol: String {
            switch self {
            case .cash: "banknote"
            case .deposit: "building.columns"
            case .check: "doc.text"
            case .zelle: "arrow.left.arrow.right"
            case .creditCard: "creditcard"
            }
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

    /// Calculates the recorded amount and remaining balance for a validated subtotal.
    func totals(subtotal: Double) -> Totals? {
        guard subtotal.isFinite, subtotal >= 0,
              let discount = Self.money(discount), discount >= 0 else {
            return nil
        }

        // Keep a previously entered amount in the draft, but exclude it when payment is skipped.
        let recordedPayment: Double?
        if mode == .skip {
            recordedPayment = 0
        } else {
            recordedPayment = Self.money(amount)
        }
        guard let amount = recordedPayment, amount >= 0 else {
            return nil
        }
        let balance = ((subtotal - discount - amount) * 100).rounded() / 100
        guard balance.isFinite, balance >= 0 else {
            return nil
        }
        return Totals(discount: discount, payment: amount, balance: balance)
    }

    /// Returns the first issue preventing submission of the selected payment method.
    func validationIssue(subtotal: Double) -> String? {
        guard let totals = totals(subtotal: subtotal) else {
            return "invoicePayment.invalidAmounts"
        }
        // Funding and check details are required only for a positive recorded payment.
        guard mode == .record, totals.payment > 0 else {
            return nil
        }
        guard let method else {
            return "invoicePayment.methodRequired"
        }
        if method.requiresBankAccount, bankAccount?.isValid != true {
            return "invoicePayment.bankRequired"
        }
        if method == .check, checkNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "invoicePayment.checkRequired"
        }
        return nil
    }

    /// Parses a nonnegative currency amount using the decimal separator entered by the user.
    private static func money(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return 0
        }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let parsed = Double(normalized), parsed.isFinite, parsed >= 0 else {
            return nil
        }
        let cents = parsed * 100
        guard cents.isFinite else {
            return nil
        }
        return cents.rounded() / 100
    }
}

/// Only the destination reference needed by a journal; no banking credentials.
nonisolated struct InvoiceBankAccount: Codable, Equatable, Identifiable, Sendable {
    let id: UInt32
    let name: String?
    let displayName: String?
    let type: String

    var isValid: Bool { id > 0 && type == "BANK" }
    var title: String { displayName ?? name ?? String(id) }
}
