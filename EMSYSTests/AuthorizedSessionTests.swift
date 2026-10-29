import FirebaseAuth
import XCTest
@testable import EMSYS

@MainActor
final class AuthorizedSessionTests: XCTestCase {
    func testProfileBranchPersistsWithoutBreakingOlderAuthorizedSnapshots() throws {
        let oldProfile = Data(#"{"uid":"user","name":"Test","active":true}"#.utf8)
        let legacy = try JSONDecoder().decode(AuthenticatedUser.self, from: oldProfile)
        XCTAssertNil(legacy.branch)
        var updated = legacy
        updated.branch = .init(id: 7, name: "Test Branch", code: "NY")
        let snapshot = AuthorizedSessionSnapshot(companyID: "company", user: updated,
            permissions: .init(role: .init(id: 1, name: "Test"), permissions: []))
        let restored = try JSONDecoder().decode(AuthorizedSessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertTrue(restored.matches(userID: "user", companyID: "company"))
        XCTAssertEqual(restored.user.branch?.id, 7)
        XCTAssertEqual(restored.user.branch?.code, "NY")
    }

    func testSnapshotRoundTripPreservesVerifiedScopeAndGrants() throws {
        let snapshot = AuthorizedSessionSnapshot(
            companyID: "company-a",
            user: AuthenticatedUser(uid: "user-a", name: "Test", email: nil, active: true),
            permissions: UserPermissions(
                role: .init(id: 1, name: "Test role"),
                permissions: [.init(name: "canViewInvoice", resourceType: "invoice")]
            )
        )
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(AuthorizedSessionSnapshot.self, from: data)
        XCTAssertTrue(restored.matches(userID: "user-a", companyID: nil))
        XCTAssertTrue(restored.matches(userID: "user-a", companyID: "company-a"))
        XCTAssertFalse(restored.matches(userID: "user-b", companyID: nil))
        XCTAssertFalse(restored.matches(userID: "user-a", companyID: "company-b"))
        XCTAssertTrue(restored.permissions.contains("canViewInvoice", resourceType: "invoice"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("token"))
        XCTAssertFalse(text.contains("password"))

        let obsolete = Data(text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8)
        XCTAssertFalse(try JSONDecoder().decode(AuthorizedSessionSnapshot.self, from: obsolete)
            .matches(userID: "user-a", companyID: nil))
    }

    func testVerifiedSnapshotCanBeEncodedAndCheckedAwayFromTheMainActor() async throws {
        let snapshot = AuthorizedSessionSnapshot(companyID: "company",
            user: AuthenticatedUser(uid: "user", name: nil, email: nil, active: true),
            permissions: UserPermissions(role: .init(id: 1, name: "Test"),
                permissions: [.init(name: "canViewInvoice", resourceType: "invoice")]))
        let matches = try await Task.detached {
            let payload = try JSONEncoder().encode(snapshot)
            let restored = try JSONDecoder().decode(AuthorizedSessionSnapshot.self, from: payload)
            return restored.matches(userID: "user", companyID: "company")
                && restored.permissions.contains("canViewInvoice", resourceType: "invoice")
        }.value
        XCTAssertTrue(matches)
    }

    func testInactiveAndInvalidSnapshotsCannotRestoreAccess() {
        let permissions = UserPermissions(role: .init(id: 1, name: "Test"), permissions: [])
        for (uid, company, active) in [("user", "company", false), ("user", "  ", true), ("", "company", true)] {
            let snapshot = AuthorizedSessionSnapshot(
                companyID: company,
                user: AuthenticatedUser(uid: uid, name: nil, email: nil, active: active),
                permissions: permissions
            )
            XCTAssertFalse(snapshot.matches(userID: uid, companyID: nil))
        }
    }

    func testOnlyConnectivityFailuresPermitOfflineRestoration() {
        for code: URLError.Code in [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                    .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
            XCTAssertTrue(AuthenticationSession.permitsOfflineRestoration(URLError(code)))
        }
        XCTAssertTrue(AuthenticationSession.permitsOfflineRestoration(
            NSError(domain: AuthErrorDomain, code: AuthErrorCode.networkError.rawValue)
        ))
        let failures: [Error] = [
            URLError(.cancelled), URLError(.serverCertificateUntrusted), URLError(.badServerResponse),
            APIClientError.httpStatus(401), APIClientError.httpStatus(403), APIClientError.httpStatus(500),
            AuthenticationIssue.authorization, AuthenticationIssue.company,
            NSError(domain: AuthErrorDomain, code: AuthErrorCode.userDisabled.rawValue)
        ]
        for error in failures {
            XCTAssertFalse(AuthenticationSession.permitsOfflineRestoration(error))
        }
    }
}
