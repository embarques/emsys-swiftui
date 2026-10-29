import Foundation

/// Minimum Cuadre identity needed for a draft review. Journal totals and payment
/// information are not inferred from a statement status or cached locally here.
nonisolated struct InvoiceIncomeStatement: Codable, Equatable, Identifiable, Sendable {
    let id: UInt32
    let businessDate: String?
    let date: String?
    let timezone: String?
    let automated: Bool?
    let branch: AuthenticatedUser.Branch?
    let currency: String?
    let status: String?

    var isOpen: Bool { status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "open" }

    func matches(branchID: UInt16, day: InvoiceDate) -> Bool {
        guard id > 0, branch?.id == branchID else { return false }
        if let businessDate, !businessDate.isEmpty { return InvoiceDate(apiValue: businessDate) == day }
        guard automated != true, let date else { return false }
        return InvoiceDate(apiValue: String(date.prefix(10))) == day
    }
}

nonisolated struct InvoicePaymentReview: Codable, Equatable, Sendable {
    let branchID: UInt16
    let day: InvoiceDate
    let statement: InvoiceIncomeStatement?
    let downloadedAt: Date

    var isValid: Bool {
        branchID > 0 && day.pickerDate != nil && downloadedAt.timeIntervalSince1970.isFinite
            && (statement == nil || statement?.matches(branchID: branchID, day: day) == true)
    }
}

nonisolated struct InvoiceIncomeStatementQuery: Encodable {
    struct Sort: Encodable { let field = "date"; let direction = "desc" }
    enum Value: Encodable {
        case number(UInt16), text(String), boolean(Bool)
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let value): try container.encode(value)
            case .text(let value): try container.encode(value)
            case .boolean(let value): try container.encode(value)
            }
        }
    }
    struct Filter: Encodable {
        let field: String?
        let `operator`: String
        let value: Value?
        let filters: [Filter]?
    }
    let sort = [Sort()]
    let page = 1
    let limit = 1
    let offset = 0
    let `operator` = "and"
    let filters: [Filter]

    init(branchID: UInt16, day: InvoiceDate) {
        filters = [Filter(field: "branch.id", operator: "eq", value: .number(branchID), filters: nil),
            Filter(field: nil, operator: "or", value: nil, filters: [
                Filter(field: "businessDate", operator: "eq", value: .text(day.apiValue), filters: nil),
                Filter(field: nil, operator: "and", value: nil, filters: [
                    Filter(field: "automated", operator: "neq", value: .boolean(true), filters: nil),
                    Filter(field: "date", operator: "eq", value: .text(day.apiValue), filters: nil)
                ])
            ])]
    }
}
