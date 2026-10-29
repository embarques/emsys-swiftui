import Foundation

/// Restoring an established session uses its device copy. Explicit login and
/// permission sync bypass that copy; business requests remain server-authorized.
@MainActor
enum AuthorizedSessionLoader {
    struct Loaded {
        let snapshot: AuthorizedSessionSnapshot
        let usedCache: Bool
    }

    static func load(userID: String, companyID: String?, refreshPermissions: Bool,
                     cached: () async throws -> AuthorizedSessionSnapshot?,
                     refreshed: () async throws -> AuthorizedSessionSnapshot) async throws -> Loaded {
        if !refreshPermissions {
            do {
                if let snapshot = try await cached(), snapshot.matches(userID: userID, companyID: companyID) {
                    try Task.checkCancellation()
                    return Loaded(snapshot: snapshot, usedCache: true)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // An unreadable device copy requires fresh authorization.
            }
        }
        try Task.checkCancellation()
        let snapshot = try await refreshed()
        try Task.checkCancellation()
        guard snapshot.matches(userID: userID, companyID: companyID) else { throw AuthenticationIssue.authorization }
        return Loaded(snapshot: snapshot, usedCache: false)
    }
}
