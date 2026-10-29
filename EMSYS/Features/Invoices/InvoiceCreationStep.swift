import Foundation

nonisolated enum InvoiceCreationStep: Int, Codable, CaseIterable, Identifiable, Sendable {
    case details, customers, items, payment, review
    var id: Self { self }
    var title: String { "invoiceCreation.step.\(self)" }
    var symbol: String {
        switch self {
        case .details: "doc.text"
        case .customers: "person.2"
        case .items: "shippingbox"
        case .payment: "banknote"
        case .review: "checkmark.seal"
        }
    }
}
