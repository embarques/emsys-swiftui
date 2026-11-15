import Foundation

/// Retains the complete public write document. The small read-only Invoice
/// projection must never become a full-replacement update payload.
nonisolated struct InvoiceWriteDocument: Codable, Sendable {
    struct ItemNameChange: Codable, Equatable, Sendable {
        let itemID: String
        let originalName: String?
        let updatedName: String
    }

    struct Item: Identifiable, Sendable {
        let id: String
        let name: String
    }

    enum WriteError: Error {
        case invalidDocument
        case invalidItem
        case missingName
        case noChanges
        case tooLarge
    }

    private var fields: [String: Field]

    /// Returns the server identity from the complete write document.
    var id: String? { fields["id"]?.string }
    /// Returns the server invoice number when the document contains one.
    var number: String? { fields["number"]?.string }

    /// Projects item identifiers and labels for the item editor.
    var items: [Item] {
        guard case .array(let details) = fields["invoiceDetails"] else {
            return []
        }
        return details.compactMap { detail in
            guard case .object(let fields) = detail, let id = fields["id"]?.string else {
                return nil
            }
            return Item(id: id, name: fields["name"]?.string ?? "")
        }
    }

    /// Decodes all public fields, including values the native app does not edit.
    init(from decoder: Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: Field].self)
    }

    /// Encodes the complete write document in its existing API structure.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }

    /// Serializes deterministic bytes within the invoice request size limit.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        guard data.count <= 3 * 1024 * 1024 else {
            throw WriteError.tooLarge
        }
        return data
    }

    /// Builds the native read model from the complete write document.
    func projection() throws -> Invoice {
        try JSONDecoder().decode(Invoice.self, from: encoded())
    }

    /// Applies item names while preserving unrelated API fields and recording changes.
    func changingItemNames(_ names: [String: String]) throws -> (document: Self, changes: [ItemNameChange]) {
        guard let id, Self.isObjectID(id), case .array(var details) = fields["invoiceDetails"] else {
            throw WriteError.invalidDocument
        }
        // Check all item identities before allowing the write document to be replaced.
        var seen = Set<String>()
        var changes: [ItemNameChange] = []
        for index in details.indices {
            guard case .object(var item) = details[index], let itemID = item["id"]?.string,
                  Self.isObjectID(itemID), seen.insert(itemID).inserted else {
                throw WriteError.invalidItem
            }
            guard let submitted = names[itemID] else {
                continue
            }
            let name = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw WriteError.missingName
            }
            // Skip unchanged values so the outbox records only actual edits.
            let previous = item["name"]?.string
            guard previous != name else {
                continue
            }
            item["name"] = .string(name)
            // The portal stores the catalog reference in description. Typing a
            // free-text description clears that reference, rather than editing
            // a catalog ID or recalculating any financial values.
            item.removeValue(forKey: "description")
            details[index] = .object(item)
            changes.append(ItemNameChange(itemID: itemID, originalName: previous, updatedName: name))
        }
        guard Set(names.keys).isSubset(of: seen) else {
            throw WriteError.invalidItem
        }
        guard !changes.isEmpty else {
            throw WriteError.noChanges
        }
        // Preserve every other public field and validate the full replacement's size.
        var updated = self
        updated.fields["invoiceDetails"] = .array(details)
        _ = try updated.encoded()
        return (updated, changes)
    }

    /// Validates the canonical spelling of an invoice API identifier.
    static func isObjectID(_ value: String) -> Bool {
        // The API accepts exactly 24 ASCII lowercase hexadecimal digits.
        let bytes = value.utf8
        guard bytes.count == 24 else {
            return false
        }
        return bytes.allSatisfy { byte in
            let isDigit = (48...57).contains(byte)
            let isLowercaseHexLetter = (97...102).contains(byte)
            return isDigit || isLowercaseHexLetter
        }
    }

    /// Unknown public fields and exact decimal numbers survive a round trip.
    /// Unsupported numeric ranges fail decoding instead of silently rounding.
    private indirect enum Field: Codable, Sendable {
        case null
        case string(String)
        case boolean(Bool)
        case number(Decimal)
        case object([String: Field])
        case array([Field])

        /// Returns the field contents only for a JSON string.
        var string: String? {
            if case .string(let value) = self {
                return value
            }
            return nil
        }

        /// Decodes one JSON value without discarding unknown fields.
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            // Decode primitives first, keeping numbers in decimal form for exact writes.
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
            } else if let value = try? container.decode(Decimal.self) {
                self = .number(value)
            } else if let value = try? container.decode([String: Field].self) {
                self = .object(value)
            } else if let value = try? container.decode([Field].self) {
                self = .array(value)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported invoice JSON value")
            }
        }

        /// Encodes this value using its original JSON type.
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null:
                try container.encodeNil()
            case .string(let value):
                try container.encode(value)
            case .boolean(let value):
                try container.encode(value)
            case .number(let value):
                try container.encode(value)
            case .object(let value):
                try container.encode(value)
            case .array(let value):
                try container.encode(value)
            }
        }
    }
}

nonisolated struct InvoiceEditSnapshot: Codable, Sendable {
    let invoice: InvoiceWriteDocument
    let revision: String

    /// Verifies the snapshot identity and revision before reading the invoice.
    func validate(invoiceID: String) throws {
        guard invoice.id == invoiceID, InvoiceWriteDocument.isObjectID(invoiceID),
              !revision.isEmpty, revision.utf8.count <= 200 else {
            throw InvoiceWriteDocument.WriteError.invalidDocument
        }
        _ = try invoice.projection()
    }
}

nonisolated struct InvoiceUpdateSubmission: Codable, Sendable {
    let requestID: UUID
    let revision: String
    let invoice: InvoiceWriteDocument

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case revision, invoice
    }

    /// Serializes deterministic bytes within the invoice request size limit.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        guard data.count <= 3 * 1024 * 1024 else {
            throw InvoiceWriteDocument.WriteError.tooLarge
        }
        return data
    }
}
