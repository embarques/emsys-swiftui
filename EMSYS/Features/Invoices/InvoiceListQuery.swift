import Foundation

nonisolated struct InvoiceListQuery: Equatable, Sendable {
    enum Scope: String, CaseIterable, Identifiable, Sendable {
        case all, due, paid, incomplete
        var id: Self { self }
        var title: String { "invoiceList.\(rawValue)" }
    }

    static let batchSize = 50
    var text = ""
    var scope: Scope = .all
    var startDate = ""
    var endDate = ""
    var container = ""

    var hasAdditionalFilters: Bool { !startDate.isEmpty || !endDate.isEmpty || !container.isEmpty }
    var normalizedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var requiresSearch: Bool { !normalizedText.isEmpty || scope != .all || hasAdditionalFilters }

    struct Sort: Encodable { let field: String; let direction = "desc" }
    struct Request: Encodable {
        let sort = [Sort(field: "date"), Sort(field: "id")]
        let filters: [Filter]
        let page: Int
        let limit = InvoiceListQuery.batchSize
        let `operator` = "and"
    }
    enum Value: Encodable {
        case text(String)
        case number(Int)
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            }
        }
    }
    struct Filter: Encodable {
        let field: String?
        let `operator`: String
        let value: Value?
        let filters: [Filter]?

        static func leaf(_ field: String, _ operation: String, _ value: String) -> Self {
            Self(field: field, operator: operation, value: .text(value), filters: nil)
        }
        static func group(_ operation: String, _ filters: [Self]) -> Self {
            Self(field: nil, operator: operation, value: nil, filters: filters)
        }
    }

    func request(page: Int) -> Request {
        var filters: [Filter] = []
        if !normalizedText.isEmpty {
            filters.append(.group("or", ["number", "sender.name", "receiver.name", "container.name", "container.containerNumber"].map {
                .leaf($0, "contains", normalizedText)
            }))
        }
        switch scope {
        case .all: break
        case .due: filters.append(Filter(field: "balance", operator: "gt", value: .number(0), filters: nil))
        case .paid: filters.append(.leaf("paidStatus", "eq", "CLOSED"))
        case .incomplete: filters.append(.leaf("registration", "eq", "PENDING"))
        }
        if !startDate.isEmpty { filters.append(.leaf("date", "gte", startDate + "T00:00:00Z")) }
        if !endDate.isEmpty { filters.append(.leaf("date", "lte", endDate + "T23:59:59.999999999Z")) }
        if !container.isEmpty { filters.append(.leaf("container.name", "contains", container)) }
        return Request(filters: filters, page: page)
    }
}
