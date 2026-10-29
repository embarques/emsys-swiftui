import XCTest
@testable import EMSYS

@MainActor
final class InvoiceCustomerTests: XCTestCase {
    func testDownloadedCustomersSurviveReopenAndRemainScopedAndRoleFiltered() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let sender = try customer(name: "José 100%", role: 1)
        let receiver = try customer(id: "000000000000000000000002", name: "Recipient", role: 2)
        try await store.saveCustomers([sender, receiver])
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let accentMatch = try await reopened.customers(matching: "JOSE", role: .sender)
        XCTAssertEqual(accentMatch, [sender])
        let literal = try await reopened.customers(matching: "%", role: .sender)
        XCTAssertEqual(literal, [sender])
        let wrongRole = try await reopened.customers(matching: "José", role: .receiver)
        XCTAssertTrue(wrongRole.isEmpty)
        let addressMatch = try await reopened.customers(matching: "Sample Street", role: .sender)
        XCTAssertEqual(addressMatch, [sender])
        for (user, company, environment) in [
            ("other", "company", APIConfiguration.defaultRoot),
            ("user", "other", APIConfiguration.defaultRoot),
            ("user", "company", "https://other.example.test/v1")
        ] {
            let other = try await InvoiceStore.open(directory: directory, userID: user, companyID: company, apiEnvironment: environment)
            let saved = try await other.customers(matching: "", role: .sender)
            XCTAssertTrue(saved.isEmpty)
        }
    }

    func testInvalidCustomerBatchCannotReplaceDownloadedData() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let original = try customer(name: "Original")
        try await store.saveCustomers([original])
        do {
            try await store.saveCustomers([customer(name: "Changed"), customer(id: "invalid")])
            XCTFail("The entire malformed batch must be rejected")
        } catch InvoiceStore.StoreError.invalidPageContents { }
        let saved = try await store.customers(matching: "", role: .sender)
        XCTAssertEqual(saved, [original])
    }

    func testCustomerSelectionAndAddressSurviveDraftReopenAndTypingClearsIdentity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let client = try makeClient()
        let editor = InvoiceDraftEditorModel(store: store, client: client, canViewCustomers: { true }, isAuthorized: { true })
        let sender = try customer()
        editor.selectCustomer(sender, role: .sender)
        editor.content.senderAddressID = "000000000000000000000010"
        let draft = try await store.saveDraft(id: UUID(), content: editor.content, expectedRevision: nil)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let restored = try await reopened.draft(id: draft.id)
        XCTAssertEqual(restored?.content.senderCustomer, sender)
        XCTAssertEqual(restored?.content.senderAddressID, editor.content.senderAddressID)
        editor.setPartyName("Someone else", role: .sender)
        XCTAssertNil(editor.content.senderCustomer)
        XCTAssertNil(editor.content.senderAddressID)
        var invalid = draft.content
        invalid.senderName = "Mismatched identity"
        do {
            _ = try await store.saveDraft(id: draft.id, content: invalid, expectedRevision: draft.revision)
            XCTFail("A name must not retain a different customer's identity")
        } catch InvoiceStore.StoreError.invalidDraft { }
        invalid = draft.content
        invalid.senderAddressID = "000000000000000000000099"
        do {
            _ = try await store.saveDraft(id: draft.id, content: invalid, expectedRevision: draft.revision)
            XCTFail("An address must belong to the selected customer")
        } catch InvoiceStore.StoreError.invalidDraft { }
        let unchanged = try await store.draft(id: draft.id)
        XCTAssertEqual(unchanged?.content, draft.content)
    }

    func testLegacyDraftsDecodeWithoutCustomerReferences() throws {
        var content = InvoiceDraft.Content()
        content.senderName = "Unfinished sender"
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [String: Any])
        for key in ["senderCustomer", "receiverCustomer", "senderAddressID", "receiverAddressID"] { object.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(InvoiceDraft.Content.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored, content)
        XCTAssertNil(restored.senderCustomer)
    }

    func testAutocompleteUsesActualContractAndOfflineFailurePreservesDownloadedMatches() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let customer = try customer()
        CustomerSearchProtocol.responses = [(200, try envelope(customer))]
        CustomerSearchProtocol.requests = []
        let model = InvoiceCustomerSearchModel(role: .sender, client: try makeClient(), store: store, isAuthorized: { true })
        model.query = "Sample"
        await model.search(online: true)
        XCTAssertEqual(model.customers, [customer])
        XCTAssertFalse(model.isShowingDownloaded)
        let request = try XCTUnwrap(CustomerSearchProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/customers/autocomplete")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "customerType" })?.value, "1")
        XCTAssertEqual(query.first(where: { $0.name == "q" })?.value, "Sample")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Company-ID"), "company")
        CustomerSearchProtocol.nextError = .notConnectedToInternet
        await model.search(online: true)
        XCTAssertEqual(model.customers, [customer])
        XCTAssertTrue(model.isShowingDownloaded)
        XCTAssertEqual(model.issue, "customers.searchError")
        CustomerSearchProtocol.responses = [(403, Data())]
        await model.search(online: true)
        XCTAssertTrue(model.customers.isEmpty)
        XCTAssertEqual(model.issue, "auth.unavailable")
    }

    func testRevokedCustomerAccessPreventsSearchAndDraftSelection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        try await store.saveCustomers([customer()])
        var authorized = true
        let client = try makeClient()
        let search = InvoiceCustomerSearchModel(role: .sender, client: client, store: store, isAuthorized: { authorized })
        await search.search(online: false)
        XCTAssertFalse(search.customers.isEmpty)
        let editor = InvoiceDraftEditorModel(store: store, client: client, canViewCustomers: { authorized }, isAuthorized: { true })
        authorized = false
        await search.search(online: true)
        XCTAssertTrue(search.customers.isEmpty)
        XCTAssertNil(editor.customerSearch(role: .sender))
        editor.selectCustomer(try customer(), role: .sender)
        XCTAssertNil(editor.content.senderCustomer)
    }

    func testBothPartiesSelectFirstAddressAndKeepManualChoiceThroughRefreshAndReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let editor = InvoiceDraftEditorModel(store: store, client: try makeClient(), canViewCustomers: { true }, isAuthorized: { true })
        let first = "000000000000000000000010"
        let second = "000000000000000000000011"
        for role in [InvoiceCustomer.Role.sender, .receiver] {
            let payload = try JSONSerialization.data(withJSONObject: [
                "id": role == .sender ? "000000000000000000000001" : "000000000000000000000002",
                "name": "Fixture party", "customerType": role.rawValue,
                "addresses": [["id": first, "address1": "First address"],
                              ["id": second, "address1": "Second address", "isPrimary": true]]
            ])
            let customer = try JSONDecoder().decode(InvoiceCustomer.self, from: payload)
            try await store.saveCustomerWriteSnapshot(JSONDecoder().decode(InvoiceCustomerWriteSnapshot.self, from: payload))
            editor.selectCustomer(customer, role: role)
            XCTAssertEqual(role == .sender ? editor.content.senderAddressID : editor.content.receiverAddressID, first)
            if role == .sender { editor.content.senderAddressID = second }
            else { editor.content.receiverAddressID = second }
        }
        await editor.loadCustomerDetails(online: false)
        XCTAssertEqual(editor.content.senderAddressID, second)
        XCTAssertEqual(editor.content.receiverAddressID, second)
        let saved = try await store.saveDraft(id: UUID(), content: editor.content, expectedRevision: nil)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let restored = try await reopened.draft(id: saved.id)
        XCTAssertEqual(restored?.content.senderAddressID, second)
        XCTAssertEqual(restored?.content.receiverAddressID, second)
    }

    func testAddressesArrivingWithDetailsDefaultForBothPartiesAndEmptyCustomersClearOldSelection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let editor = InvoiceDraftEditorModel(store: store, client: try makeClient(), canViewCustomers: { true }, isAuthorized: { true })
        for role in [InvoiceCustomer.Role.sender, .receiver] {
            let full = try customer(id: role == .sender ? "000000000000000000000001" : "000000000000000000000002", role: role.rawValue)
            let snapshot = try JSONDecoder().decode(InvoiceCustomerWriteSnapshot.self, from: JSONEncoder().encode(full))
            try await store.saveCustomerWriteSnapshot(snapshot)
            let minimal = InvoiceCustomer(id: full.id, name: full.name, customerType: role.rawValue, active: true, phones: nil, addresses: nil)
            editor.selectCustomer(minimal, role: role)
            XCTAssertNil(role == .sender ? editor.content.senderAddressID : editor.content.receiverAddressID)
            await editor.loadCustomerDetails(online: false)
            XCTAssertEqual(role == .sender ? editor.content.senderAddressID : editor.content.receiverAddressID, "000000000000000000000010")
            let empty = InvoiceCustomer(id: "000000000000000000000003", name: "No addresses", customerType: role.rawValue, active: true, phones: nil, addresses: [])
            editor.selectCustomer(empty, role: role)
            XCTAssertNil(role == .sender ? editor.content.senderAddressID : editor.content.receiverAddressID)
        }
    }

    private func customer(id: String = "000000000000000000000001", name: String = "Sample Sender", role: Int = 1) throws -> InvoiceCustomer {
        let object: [String: Any] = ["id": id, "name": name, "customerType": role, "active": true,
            "addresses": [["id": "000000000000000000000010", "address1": "100 Sample Street", "city": "Test City"]]]
        return try JSONDecoder().decode(InvoiceCustomer.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func envelope(_ customer: InvoiceCustomer) throws -> Data {
        struct Result: Encodable { let customer: InvoiceCustomer }
        struct Envelope: Encodable { let success = true; let data: [Result] }
        return try JSONEncoder().encode(Envelope(data: [Result(customer: customer)]))
    }

    private func makeClient() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CustomerSearchProtocol.self]
        let contextID = UUID()
        return try APIClient(baseURL: URL(string: "https://example.test/v1")!, session: URLSession(configuration: configuration)) { _ in
            APICredentials(sessionID: contextID, userID: "user", companyID: "company", idToken: "test-token")
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "customer-tests-\(UUID())", directoryHint: .isDirectory)
    }
}

private final class CustomerSearchProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var nextError: URLError.Code?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let code = Self.nextError {
            Self.nextError = nil
            client?.urlProtocol(self, didFailWithError: URLError(code)); return
        }
        guard !Self.responses.isEmpty, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: Self.responses[0].0, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (_, data) = Self.responses.removeFirst()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
