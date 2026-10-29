import Foundation

/// API field names are retained in the downloaded SQLite projection.
nonisolated struct Pickup: Codable, Identifiable, Equatable, Sendable {
    struct Reference: Codable, Equatable, Sendable {
        let id: String?
        let name: String?
    }

    struct Branch: Codable, Equatable, Sendable {
        let id: UInt16?
        let name: String?
        let code: String?
    }

    struct Party: Codable, Equatable, Sendable {
        struct Address: Codable, Equatable, Sendable {
            let address1: String?
            let address2: String?
            let apartment: String?
            let city: String?
            let state: String?
            let zipcode: String?
            let country: String?
            let isPrimary: Bool?
        }
        let id: String?
        let name: String?
        let phones: [Invoice.Phone]?
        let address: Address?
        let addresses: [Address]?

        var displayPhone: String? {
            let phone = phones?.first(where: { $0.isPrimary == true }) ?? phones?.first
            return phone?.displayNumber ?? phone?.number
        }
        var displayAddress: String {
            let selected = address ?? addresses?.first(where: { $0.isPrimary == true }) ?? addresses?.first
            return [selected?.address1, selected?.address2, selected?.apartment, selected?.city,
                    selected?.state, selected?.zipcode, selected?.country]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    struct Comment: Codable, Equatable, Sendable {
        let purpose: String?
        let unit: String?
        let quantity: UInt8?
        let description: String?
    }

    let id: UInt32
    let date: String?
    let updatedAt: String?
    let completed: Bool
    let completedAt: String?
    let completedBy: Reference?
    let route: Reference?
    let orderNumber: Int?
    let branch: Branch?
    let sender: Party?
    let receivers: [Party]?
    let purpose: String?
    let comments: [Comment]?

    var isComplete: Bool { completed || completedAt != nil || completedBy != nil }
    var searchText: String {
        ([String(id), sender?.name, sender?.displayAddress, sender?.displayPhone, route?.name, purpose]
            .compactMap { $0 } + (receivers ?? []).compactMap(\.name)
            + (comments ?? []).compactMap(\.description)).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_DO"))
    }

    var phoneURL: URL? {
        let number = (sender?.displayPhone ?? "").filter { $0.isASCII && ($0.isNumber || $0 == "+") }
        guard number.contains(where: \.isNumber) else { return nil }
        return URL(string: "tel:" + number)
    }

    var directionsURL: URL? {
        guard let address = sender?.displayAddress, !address.isEmpty else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "daddr", value: address)]
        return components?.url
    }
}
