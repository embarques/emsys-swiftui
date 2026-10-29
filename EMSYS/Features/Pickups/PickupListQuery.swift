import Foundation

nonisolated struct PickupListQuery: Equatable, Sendable {
    enum Status: String, CaseIterable, Identifiable, Sendable {
        case pending, completed
        var id: Self { self }
        var title: String { "pickups." + rawValue }
    }

    static let batchSize = 50
    var text = ""
    var status: Status = .pending
    var normalizedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func matches(_ pickup: Pickup) -> Bool {
        // Match the API's completed filter; completion metadata is also shown in details.
        guard pickup.completed == (status == .completed) else { return false }
        if let id = UInt32(normalizedText), id > 0 { return pickup.id == id }
        let search = normalizedText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_DO"))
        return search.isEmpty || pickup.searchText.contains(search)
    }

    struct Request: Encodable {
        enum Value: Encodable {
            case text(String)
            case number(UInt32)

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
        }
        let page: Int
        let limit = PickupListQuery.batchSize
        let `operator` = "and"
        let filters: [Filter]
    }

    func request(page: Int) -> Request {
        let fields = ["sender.name", "sender.phones.number", "sender.address.address1", "sender.address.city", "receivers.name", "route.name", "comments.description"]
        let filters: [Request.Filter]
        if let id = UInt32(normalizedText), id > 0 {
            filters = [.init(field: "id", operator: "eq", value: .number(id), filters: nil)]
        } else if normalizedText.isEmpty {
            filters = []
        } else {
            filters = [.init(field: nil, operator: "or", value: nil, filters: fields.map {
                .init(field: $0, operator: "contains", value: .text(normalizedText), filters: nil)
            })]
        }
        return Request(page: page, filters: filters)
    }
}
