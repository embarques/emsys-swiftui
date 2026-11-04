import Foundation

nonisolated struct InvoiceReservationProof: Codable, Equatable, Sendable {
    let id: String
    let token: String
    let deviceId: String
}

nonisolated struct InvoiceReservation: Codable, Equatable, Sendable, Identifiable {
    struct Allocation: Codable, Equatable, Sendable {
        let userId: UInt16?
        // Decode old local reservations without rewriting durable request proofs.
        let employeeId: UInt16?
        let token: String
        let deviceId: String?

        init(userId: UInt16, token: String, deviceId: String?) {
            self.userId = userId
            employeeId = nil
            self.token = token
            self.deviceId = deviceId
        }

        var isUnassigned: Bool {
            if let userId { return userId == 0 }
            return employeeId == 0
        }

        var hasOwner: Bool {
            if let userId { return userId > 0 }
            return (employeeId ?? 0) > 0
        }
    }
    let id: String
    let number: String
    let allocation: Allocation

    var proof: InvoiceReservationProof {
        InvoiceReservationProof(id: id, token: allocation.token, deviceId: allocation.deviceId ?? "")
    }
    func isValid(deviceID: UUID) -> Bool {
        InvoiceWriteDocument.isObjectID(id) && !number.isEmpty && allocation.hasOwner
            && UUID(uuidString: allocation.deviceId ?? "") == deviceID && !allocation.token.isEmpty
    }
}

nonisolated struct InvoicePoolPage: Decodable, Sendable {
    let items: [InvoiceReservation]
    let remaining: Int
    let lowThreshold: Int
    let nextCursor: String?
}

nonisolated struct InvoicePoolAction: Codable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case generate = "generate-self", claim, `return` }
    var id: String { requestId }
    let requestId: String
    let action: Kind
    let count: Int?
    let deviceId: String?
    let items: [InvoiceReservationProof]?

    init(action: Kind, deviceID: UUID, items: [InvoiceReservation] = []) {
        requestId = UUID().uuidString.lowercased()
        self.action = action
        count = action == .generate ? 50 : action == .claim ? 100 : nil
        deviceId = action == .generate ? nil : deviceID.uuidString.lowercased()
        self.items = action == .return ? items.map(\.proof) : nil
    }
}
