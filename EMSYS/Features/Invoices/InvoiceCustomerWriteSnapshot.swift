import Foundation

/// Selected customer detail needed by the existing invoice creation contract.
/// Search results intentionally omit identity fields and cannot replace this.
nonisolated struct InvoiceCustomerWriteSnapshot: Codable, Equatable, Sendable {
    struct Phone: Codable, Equatable, Sendable {
        let type: String?
        let number: String?
        let isPrimary: Bool?
    }
    struct Address: Codable, Equatable, Sendable {
        struct Location: Codable, Equatable, Sendable {
            let type: String
            let coordinates: [Double]
        }
        struct Verification: Codable, Equatable, Sendable {
            let isVerified: Bool
            let verifiedAt: String?
            private enum CodingKeys: String, CodingKey {
                case isVerified = "is_verified"
                case verifiedAt = "verified_at"
            }
        }
        let id: String?
        let label: String?
        let isPrimary: Bool?
        let address1: String?
        let address2: String?
        let apartment: String?
        let city: String?
        let state: String?
        let zipcode: String?
        let country: String?
        let location: Location?
        let verification: Verification?
    }
    struct Party: Encodable, Sendable {
        let id: String
        let name: String
        let customerType: Int
        let phones: [Phone]
        let email: String
        let identityNumber: String
        let address: Address?
        private enum CodingKeys: String, CodingKey {
            case id, name, customerType, phones, email, address
            case identityNumber = "IDNumber"
        }
    }
    let id: String
    let name: String
    let customerType: Int
    let phones: [Phone]?
    let email: String?
    let identityNumber: String?
    private enum CodingKeys: String, CodingKey {
        case id, name, customerType, phones, email, addresses
        case identityNumber = "IDNumber"
    }
    let addresses: [Address]?

    var isValid: Bool {
        InvoiceWriteDocument.isObjectID(id) && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && [1, 2].contains(customerType)
            && (addresses ?? []).allSatisfy { address in
                (address.id == nil || InvoiceWriteDocument.isObjectID(address.id ?? ""))
                    && (address.location?.coordinates.allSatisfy(\.isFinite) ?? true)
            }
    }

    func matches(_ customer: InvoiceCustomer) -> Bool {
        isValid && id == customer.id && name == customer.name && customerType == customer.customerType
    }

    func publicCustomer(active: Bool?) -> InvoiceCustomer {
        InvoiceCustomer(id: id, name: name, customerType: customerType, active: active,
            phones: phones?.map { .init(number: $0.number, displayNumber: nil, isPrimary: $0.isPrimary) },
            addresses: addresses?.map { address in
                .init(id: address.id, label: address.label, isPrimary: address.isPrimary, active: nil,
                    address1: address.address1, address2: address.address2, apartment: address.apartment,
                    city: address.city, state: address.state, zipcode: address.zipcode, country: address.country)
            })
    }

    func party(addressID: String?) throws -> Party {
        guard isValid else { throw APIClientError.invalidResponse }
        let address = addressID.flatMap { id in addresses?.first { $0.id == id } }
        guard addressID == nil || address != nil else { throw APIClientError.invalidResponse }
        return Party(id: id, name: name, customerType: customerType, phones: phones ?? [],
                     email: email ?? "", identityNumber: identityNumber ?? "", address: address)
    }
}
