import XCTest
@testable import EMSYS

@MainActor
final class CompanyProfileLookupTests: XCTestCase {
    func testSuccessfulLookupAndMissingProfile() async throws {
        let company = try await CompanyProfileLookup.read { completion in
            completion("test-company", nil)
        }
        XCTAssertEqual(company, "test-company")
        let missing = try await CompanyProfileLookup.read { completion in
            completion(nil, nil)
        }
        XCTAssertNil(missing)
    }

    func testTimeoutReturnsAndLateCallbackIsIgnored() async throws {
        var lateCompletion: CompanyProfileLookup.Completion?
        do {
            _ = try await CompanyProfileLookup.read(timeout: .milliseconds(10)) { completion in
                lateCompletion = completion
            }
            XCTFail("Expected the lookup deadline to expire")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        // SDK cancellation is not assumed. Its callback may arrive after timeout.
        lateCompletion?("late-company", nil)
        await Task.yield()
    }

    func testSDKFailureIsPreserved() async {
        do {
            _ = try await CompanyProfileLookup.read { completion in
                completion(nil, URLError(.notConnectedToInternet))
            }
            XCTFail("Expected the SDK error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }
}
