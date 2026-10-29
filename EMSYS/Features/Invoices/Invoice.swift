import Foundation

/// Read-only projection of the current API invoice. Never use this projection
/// as an update payload: omitted fields must not replace server business data.
nonisolated struct Invoice: Codable, Identifiable, Equatable, Sendable {
    struct Party: Codable, Equatable, Sendable {
        let name: String?
        var id: String? = nil
        var phones: [Phone]? = nil
        var address: Address? = nil
        var addresses: [Address]? = nil

        var displayPhone: String? {
            let phone = phones?.first(where: { $0.isPrimary == true }) ?? phones?.first
            return phone?.displayNumber ?? phone?.number
        }

        var displayAddress: String {
            let address = address ?? addresses?.first(where: { $0.isPrimary == true }) ?? addresses?.first
            return [address?.address1, address?.address2, address?.city, address?.state, address?.zipcode]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    struct Phone: Codable, Equatable, Sendable {
        let number: String?
        let displayNumber: String?
        let isPrimary: Bool?
    }

    struct Address: Codable, Equatable, Sendable {
        let address1: String?
        let address2: String?
        let city: String?
        let state: String?
        let zipcode: String?
        let isPrimary: Bool?
        var apartment: String? = nil
    }

    struct Container: Codable, Equatable, Sendable {
        let name: String?
        var id: UInt16? = nil
        let containerNumber: String?
    }

    struct Item: Codable, Identifiable, Equatable, Sendable {
        let id: String
        let name: String?
        let description: String?
        let quantity: Decimal?
        let price: Decimal?
        let total: Decimal?

        var displayName: String? {
            Self.nonempty(name) ?? readableDescription
        }

        var supportingDescription: String? {
            guard let description = readableDescription, description != displayName else { return nil }
            return description
        }

        private var readableDescription: String? {
            guard let description = Self.nonempty(description),
                  !description.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return description
        }

        private static func nonempty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
    }

    let id: String
    let number: String?
    let date: String?
    let sender: Party?
    let receiver: Party?
    let cost: Decimal?
    let payment: Decimal?
    let balance: Decimal?
    let invoiceDetails: [Item]?
    struct PrintPerson: Codable, Equatable, Sendable {
        var name: String? = nil
        var fullName: String? = nil
        var userName: String? = nil
        var email: String? = nil
    }

    struct ReceivedBy: Codable, Equatable, Sendable {
        var type: String? = nil
        var name: String? = nil
        var route: PrintPerson? = nil
        var employee: PrintPerson? = nil
    }

    var pickup: InvoicePickupReference? = nil
    var discount: Decimal? = nil
    var surcharge: Decimal? = nil
    var receivedBy: ReceivedBy? = nil
    var employee: PrintPerson? = nil
    var paidStatus: String? = nil
    var registration: String? = nil
    var container: Container? = nil
    var itemCount: Decimal? = nil

    var hasDocumentContainer: Bool {
        (container?.id ?? 0) > 0 && container?.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var calendarDate: Date? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(date.prefix(10)))
    }

    var monthKey: String { String(date?.prefix(7) ?? "") }
    var quantity: Decimal { itemCount ?? invoiceDetails?.reduce(0, { $0 + ($1.quantity ?? 0) }) ?? 0 }
    var initials: String {
        let name = sender?.name ?? receiver?.name ?? number ?? ""
        return name.split(separator: " ").prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    }
}
