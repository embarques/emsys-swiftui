import Foundation

nonisolated struct AuthenticatedUser: Codable, Sendable {
    struct Branch: Codable, Equatable, Sendable {
        let id: UInt16
        let name: String?
        let code: String?
    }
    let uid: String
    let name: String?
    let email: String?
    let active: Bool
    var branch: Branch? = nil
}

nonisolated struct UserPermissions: Codable, Sendable {
    struct Role: Codable, Sendable {
        let id: Int
        let name: String
    }

    struct Permission: Codable, Sendable {
        let name: String
        let resourceType: String
    }

    let role: Role
    let permissions: [Permission]

    func contains(_ name: String, resourceType: String) -> Bool {
        permissions.contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name.lowercased()
                && $0.resourceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == resourceType.lowercased()
        }
    }
}
