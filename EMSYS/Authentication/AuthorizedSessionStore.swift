import CryptoKit
import Foundation
import Security

/// A previously verified context, never a substitute for server authorization
/// of network operations. Firebase continues to own all authentication tokens.
nonisolated struct AuthorizedSessionSnapshot: Codable, Sendable {
    let version: Int
    let companyID: String
    let user: AuthenticatedUser
    let permissions: UserPermissions
    let permissionsSyncedAt: Date?

    /// Captures the verified user and grants as the current cache version.
    init(companyID: String, user: AuthenticatedUser, permissions: UserPermissions, permissionsSyncedAt: Date = .now) {
        version = 1
        self.companyID = companyID
        self.user = user
        self.permissions = permissions
        self.permissionsSyncedAt = permissionsSyncedAt
    }

    /// Checks that the saved grants still belong to the expected active account.
    func matches(userID: String, companyID: String?) -> Bool {
        version == 1 && user.active && user.uid == userID && !userID.isEmpty
            && !self.companyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (companyID == nil || companyID == self.companyID)
    }
}

/// Keychain calls run on this actor rather than blocking the UI. Accounts are
/// separated by Firebase project, API environment and Firebase user.
actor AuthorizedSessionStore {
    private let service: String
    private let environment: String

    /// Derives the Keychain namespace from the app and API environment.
    init(bundleID: String, projectID: String, apiURL: URL) {
        service = bundleID + ".authorized-session"
        environment = projectID + "\u{0}" + apiURL.absoluteString
    }

    /// Restores a valid cached session or removes a mismatched record.
    func load(userID: String, companyID: String?) throws -> AuthorizedSessionSnapshot? {
        try Task.checkCancellation()
        // Limit the lookup to one data item in the account's namespace.
        var query = query(userID: userID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data,
              data.count <= 1024 * 1024 else {
            throw AuthenticationIssue.configuration
        }
        // Remove an obsolete or foreign session so it cannot grant future offline access.
        let snapshot = try JSONDecoder().decode(AuthorizedSessionSnapshot.self, from: data)
        guard snapshot.matches(userID: userID, companyID: companyID) else {
            try remove(userID: userID)
            return nil
        }
        return snapshot
    }

    /// Stores verified grants with device-only Keychain protection.
    func save(_ snapshot: AuthorizedSessionSnapshot) throws {
        try Task.checkCancellation()
        guard snapshot.matches(userID: snapshot.user.uid, companyID: snapshot.companyID) else {
            throw AuthenticationIssue.authorization
        }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 1024 * 1024 else {
            throw AuthenticationIssue.configuration
        }
        // Update first and apply device-only protection when creating a new item.
        let query = query(userID: snapshot.user.uid)
        let attributes = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, attributes)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw AuthenticationIssue.configuration
        }
    }

    /// Deletes the cached access for this account when present.
    func remove(userID: String) throws {
        let status = SecItemDelete(query(userID: userID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthenticationIssue.configuration
        }
    }

    /// Builds the Keychain lookup for this API environment and user.
    private func query(userID: String) -> [String: Any] {
        let digest = SHA256.hash(data: Data((environment + "\u{0}" + userID).utf8))
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: digest.map { String(format: "%02x", $0) }.joined()
        ]
    }
}
