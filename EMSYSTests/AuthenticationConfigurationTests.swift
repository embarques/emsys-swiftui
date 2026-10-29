import FirebaseCore
import XCTest
@testable import EMSYS

@MainActor
final class AuthenticationConfigurationTests: XCTestCase {
    func testMissingConfigurationExplainsWhyRecheckingCannotSignIn() {
        let session = AuthenticationSession(configurationProvider: { nil })
        session.start()
        XCTAssertEqual(session.phase, .unavailable)
        XCTAssertEqual(session.configurationIssue, .missing)
        XCTAssertFalse(session.canSignOut)
        XCTAssertFalse(session.didRecheckConfiguration)
        session.retry()
        XCTAssertEqual(session.configurationIssue, .missing)
        XCTAssertTrue(session.didRecheckConfiguration)
        XCTAssertFalse(session.canViewInvoices)
        XCTAssertFalse(session.canSignOut)
    }

    func testMismatchedIdentityNeverInitializesAnAuthenticatedSession() {
        let options = FirebaseOptions(googleAppID: "1:123:ios:testconfiguration", gcmSenderID: "123")
        options.bundleID = "test.fixture.mismatched-identity"
        options.projectID = "test-project"
        let session = AuthenticationSession(configurationProvider: { options })
        session.start()
        XCTAssertEqual(session.configurationIssue, .identityMismatch)
        XCTAssertEqual(session.phase, .unavailable)
        XCTAssertFalse(session.canSignOut)
        session.retry()
        XCTAssertTrue(session.didRecheckConfiguration)
        XCTAssertEqual(session.configurationIssue, .identityMismatch)
        XCTAssertNil(session.user)
    }
}
