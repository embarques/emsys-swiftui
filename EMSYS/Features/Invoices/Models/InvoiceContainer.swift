import Foundation

nonisolated struct InvoiceContainer: Codable, Equatable, Identifiable, Sendable {
    let id: UInt32
    let name: String
    let containerNumber: String?

    var isValid: Bool { id > 0 }

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(id) : name
    }

    var searchText: String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_DO"))
    }
}
