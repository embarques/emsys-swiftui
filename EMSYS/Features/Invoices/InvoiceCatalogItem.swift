import Foundation

nonisolated struct InvoiceCatalogItem: Codable, Identifiable, Equatable, Sendable {
    let id: UInt16
    let name: String
    let price: Double
    let createdAt: String?

    var isValid: Bool {
        id > 0 && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && price.isFinite && price >= 0
    }

    var formattedPrice: String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), price) }

    static func matching(_ items: [Self], query: String) -> [Self] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter {
            term.isEmpty || $0.name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.sorted {
            if $0.createdAt == $1.createdAt { return $0.id > $1.id }
            return ($0.createdAt ?? "") > ($1.createdAt ?? "")
        }
    }
}
