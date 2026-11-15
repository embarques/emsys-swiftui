import Foundation

/// The public customer fields needed to identify a draft party. Private identity
/// documents, account balances and unrelated customer notes are not cached.
nonisolated struct InvoiceCustomer: Codable, Equatable, Identifiable, Sendable {
    enum Role: Int, Codable, Sendable {
        case sender = 1
        case receiver = 2
    }

    struct Address: Codable, Equatable, Identifiable, Sendable {
        let id: String?
        let label: String?
        let isPrimary: Bool?
        let active: Bool?
        let address1: String?
        let address2: String?
        let apartment: String?
        let city: String?
        let state: String?
        let zipcode: String?
        let country: String?

        var displayText: String {
            [address1, address2, apartment, city, state, zipcode, country]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    struct SearchResult: Decodable, Sendable {
        let customer: InvoiceCustomer
        let matchedAddressId: String?
    }

    let id: String
    let name: String
    let customerType: Int?
    let active: Bool?
    let phones: [Invoice.Phone]?
    let addresses: [Address]?

    var displayPhone: String? {
        let phone = phones?.first(where: { $0.isPrimary == true }) ?? phones?.first
        return phone?.displayNumber ?? phone?.number
    }

    var isValid: Bool {
        InvoiceWriteDocument.isObjectID(id) && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var searchText: String {
        ([name] + (phones ?? []).compactMap(\.number) + (addresses ?? []).map(\.displayText))
            .joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_DO"))
    }
}
