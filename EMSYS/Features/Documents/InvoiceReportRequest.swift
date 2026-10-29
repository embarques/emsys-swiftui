import Foundation

nonisolated struct InvoiceSignatureSelection: Codable, Equatable, Sendable {
    let invoiceID: String
    let includeSender: Bool
    let receiverSignatureID: String?

    private enum CodingKeys: String, CodingKey {
        case includeSender
        case invoiceID = "invoiceId"
        case receiverSignatureID = "receiverSignatureId"
    }
}

struct InvoiceReportRequest: Encodable {
    let type = "invoice"
    let collection = "invoices"
    let lookupField = "id"
    let values: [String]
    let signatureSelections: [InvoiceSignatureSelection]
    let language: String

    init(selections: [InvoiceSignatureSelection], language: AppLanguage) {
        values = selections.map(\.invoiceID)
        signatureSelections = selections
        self.language = language == .english ? "en" : "es"
    }

    private enum CodingKeys: String, CodingKey {
        case type, collection, values, signatureSelections, language
        case lookupField = "lookup_field"
    }
}
