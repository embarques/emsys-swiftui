import Foundation

/// Public tenant settings persisted in the same user/company database as invoices.
nonisolated struct InvoicePrintCompany: Codable, Sendable {
    let id: String
    let name: String
    var policyUrl: String? = nil
    var logo: String? = nil
    var logoImage: Data? = nil
}
