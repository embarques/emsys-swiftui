import XCTest
@testable import EMSYS

@MainActor
final class InvoiceCustomerWriteSnapshotTests: XCTestCase {
    func testInvoicePartyPreservesContactIdentityAndSelectedAddressMetadata() throws {
        let snapshot = try JSONDecoder().decode(InvoiceCustomerWriteSnapshot.self, from: fixture())
        let party = try snapshot.party(addressID: "000000000000000000000010")
        let encoded = try JSONEncoder().encode(party)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["email"] as? String, "sender@example.test")
        XCTAssertEqual(object["IDNumber"] as? String, "TEST-ID-42")
        let phones = try XCTUnwrap(object["phones"] as? [[String: Any]])
        XCTAssertEqual(phones.first?["type"] as? String, "mobile")
        let address = try XCTUnwrap(object["address"] as? [String: Any])
        XCTAssertEqual(address["apartment"] as? String, "2A")
        XCTAssertNotNil(address["location"])
        XCTAssertNotNil(address["verification"])
        XCTAssertNil(object["notes"])
        XCTAssertNil(object["accountBalance"])
        XCTAssertThrowsError(try snapshot.party(addressID: "000000000000000000000099"))
    }

    func testScopedSnapshotAndDraftSurviveOfflineReopenWithoutPrivateSearchFields() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let snapshot = try JSONDecoder().decode(InvoiceCustomerWriteSnapshot.self, from: fixture())
        let customer = try JSONDecoder().decode(InvoiceCustomer.self, from: fixture())
        try await store.saveCustomerWriteSnapshot(snapshot)
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.test/v1"))) { _ in
            XCTFail("Offline hydration must not request credentials")
            throw APIClientError.missingCredentials
        }
        let editor = InvoiceDraftEditorModel(store: store, client: client, canViewCustomers: { true }, isAuthorized: { true })
        editor.selectCustomer(customer, role: .sender)
        editor.content.senderAddressID = "000000000000000000000010"
        await editor.loadCustomerDetails(online: false)
        XCTAssertEqual(editor.content.senderWriteSnapshot, snapshot)
        await editor.save()
        let summaries = try await store.draftSummaries()
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let draft = try await reopened.draft(id: XCTUnwrap(summaries.first?.id))
        XCTAssertEqual(draft?.content.senderWriteSnapshot?.identityNumber, "TEST-ID-42")
        let other = try await InvoiceStore.open(directory: directory, userID: "other-user", companyID: "company")
        let otherSnapshot = try await other.customerWriteSnapshot(id: snapshot.id)
        XCTAssertNil(otherSnapshot)
        editor.setPartyName("Different sender", role: .sender)
        XCTAssertNil(editor.content.senderWriteSnapshot)
        let searchData = try JSONEncoder().encode(customer)
        let searchObject = try XCTUnwrap(JSONSerialization.jsonObject(with: searchData) as? [String: Any])
        XCTAssertNil(searchObject["IDNumber"])
        XCTAssertNil(searchObject["email"])
    }

    func testChangedSelectionCannotReceiveAnOlderDownload() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CustomerDetailProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        CustomerDetailProtocol.payload = fixture()
        let started = expectation(description: "Credentials suspended")
        var resume: CheckedContinuation<Void, Never>?
        var firstRequest = true
        let context = UUID()
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.test/v1")), session: session) { _ in
            if firstRequest {
                firstRequest = false
                await withCheckedContinuation { resume = $0; started.fulfill() }
            }
            return APICredentials(sessionID: context, userID: "user", companyID: "company", idToken: "fixture-token")
        }
        let editor = InvoiceDraftEditorModel(store: store, client: client, canViewCustomers: { true }, isAuthorized: { true })
        editor.selectCustomer(try JSONDecoder().decode(InvoiceCustomer.self, from: fixture()), role: .sender)
        let task = Task { await editor.loadCustomerDetails(online: true) }
        await fulfillment(of: [started], timeout: 2)
        editor.setPartyName("Unsaved replacement", role: .sender)
        resume?.resume()
        await task.value
        XCTAssertNil(editor.content.senderWriteSnapshot)
        XCTAssertEqual(editor.content.senderName, "Unsaved replacement")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    private func fixture() -> Data {
        Data(#"{"id":"000000000000000000000001","name":"Fixture Sender","customerType":1,"active":true,"email":"sender@example.test","IDNumber":"TEST-ID-42","phones":[{"number":"+12025550123","type":"mobile","isPrimary":true}],"addresses":[{"id":"000000000000000000000010","address1":"100 Test Street","apartment":"2A","city":"Test City","location":{"type":"Point","coordinates":[-73,40]},"verification":{"is_verified":true,"verified_at":"2026-10-26T00:00:00Z"}}],"notes":"not needed","accountBalance":99}"#.utf8)
    }
}

private final class CustomerDetailProtocol: URLProtocol {
    nonisolated(unsafe) static var payload = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"success":true,"data":\#(String(decoding: Self.payload, as: UTF8.self))}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
