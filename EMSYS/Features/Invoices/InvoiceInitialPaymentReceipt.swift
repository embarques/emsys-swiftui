import Foundation

/// Only server-confirmed registration fields; no inferred settlement status.
nonisolated struct InvoiceInitialPaymentReceipt: Codable, Sendable {
    struct InvoiceReference: Codable, Sendable {
        let id: String
        let number: String
        let cost: Double
        let payment: Double?
        let balance: Double?
    }
    struct Statement: Codable, Sendable { let id: UInt32 }
    let id: String
    let transactionType: String
    let transactionAmount: Double
    let invoice: InvoiceReference
    let incomeStatement: Statement
}
