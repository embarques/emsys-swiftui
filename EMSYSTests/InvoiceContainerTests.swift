import XCTest
@testable import EMSYS

@MainActor
final class InvoiceContainerTests: XCTestCase {
    func testUnnamedLegacyContainerKeepsItsActualIdentityInsteadOfInventingAName() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let container = InvoiceContainer(id: 67, name: "", containerNumber: nil)
        XCTAssertTrue(container.isValid)
        XCTAssertEqual(container.displayName, "67")
        try await store.saveContainers([container])
        let saved = try await store.containers(matching: "")
        XCTAssertEqual(saved, [container])
        XCTAssertEqual(saved.first?.name, "")
    }

    func testSelectedContainerSurvivesDraftReopenAndOtherScopesCannotReadTheCache() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let container = fixture(67)
        try await store.saveContainers([container])
        let editor = InvoiceDraftEditorModel(store: store, client: try makeClient(), canViewContainers: { true }, isAuthorized: { true })
        editor.selectContainer(container)
        let draft = try await store.saveDraft(id: UUID(), content: editor.content, expectedRevision: nil)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let restored = try await reopened.draft(id: draft.id)
        XCTAssertEqual(restored?.content.container, container)
        let downloaded = try await reopened.containers(matching: "ship")
        XCTAssertEqual(downloaded, [container])
        for (user, company, environment) in [
            ("other", "company", APIConfiguration.defaultRoot),
            ("user", "other", APIConfiguration.defaultRoot),
            ("user", "company", "https://other.example.test/v1")
        ] {
            let other = try await InvoiceStore.open(directory: directory, userID: user, companyID: company, apiEnvironment: environment)
            let saved = try await other.containers(matching: "")
            XCTAssertTrue(saved.isEmpty)
        }
    }

    func testActualContainerPaginationPreservesRowsAfterFailureAndRejectsRepeatedPages() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let first = (100...139).reversed().map { fixture(UInt32($0)) }
        ContainerLookupProtocol.responses = [(200, try envelope(first)), (500, Data())]
        ContainerLookupProtocol.requests = []
        let model = InvoiceContainerSearchModel(client: try makeClient(), store: store, isAuthorized: { true })
        model.query = "Ship"
        await model.search(online: true)
        XCTAssertEqual(model.containers, first)
        XCTAssertTrue(model.hasMore)
        await model.loadMore(online: true)
        XCTAssertEqual(model.containers, first)
        XCTAssertEqual(model.issue, "containers.searchError")
        ContainerLookupProtocol.responses = [(200, try envelope(first))]
        await model.loadMore(online: true)
        XCTAssertEqual(model.containers, first)
        XCTAssertEqual(model.issue, "containers.searchError")
        let last = fixture(99)
        ContainerLookupProtocol.responses = [(200, try envelope([last]))]
        await model.loadMore(online: true)
        XCTAssertEqual(model.containers, first + [last])
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.issue)
        let request = try XCTUnwrap(ContainerLookupProtocol.requests.last)
        XCTAssertEqual(request.url?.path, "/v1/containers")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "page" })?.value, "2")
        XCTAssertEqual(query?.first(where: { $0.name == "field" })?.value, "name")
        XCTAssertEqual(query?.first(where: { $0.name == "operator" })?.value, "contains")
        XCTAssertEqual(query?.first(where: { $0.name == "value" })?.value, "Ship")
    }

    func testOfflineLookupNeedsNoRequestAndAuthorizationDenialHidesChoices() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        try await store.saveContainers([fixture(67)])
        ContainerLookupProtocol.requests = []
        var authorized = true
        let model = InvoiceContainerSearchModel(client: try makeClient(), store: store, isAuthorized: { authorized })
        await model.search(online: false)
        XCTAssertEqual(model.containers, [fixture(67)])
        XCTAssertTrue(model.isShowingDownloaded)
        XCTAssertTrue(ContainerLookupProtocol.requests.isEmpty)
        ContainerLookupProtocol.responses = [(403, Data())]
        await model.search(online: true)
        XCTAssertTrue(model.containers.isEmpty)
        XCTAssertEqual(model.issue, "auth.unavailable")
        authorized = false
        let count = ContainerLookupProtocol.requests.count
        await model.search(online: true)
        XCTAssertTrue(model.containers.isEmpty)
        XCTAssertEqual(ContainerLookupProtocol.requests.count, count)
    }

    func testInvalidContainerCannotReplaceCacheOrDraftAndLegacyDraftHasNoContainer() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        try await store.saveContainers([fixture(67)])
        let invalid = InvoiceContainer(id: 0, name: "Invalid", containerNumber: nil)
        do {
            try await store.saveContainers([fixture(68), invalid])
            XCTFail("A malformed batch must not be partially cached")
        } catch InvoiceStore.StoreError.invalidPageContents { }
        let cached = try await store.containers(matching: "")
        XCTAssertEqual(cached, [fixture(67)])
        var content = InvoiceDraft.Content()
        let saved = try await store.saveDraft(id: UUID(), content: content, expectedRevision: nil)
        content.container = invalid
        do {
            _ = try await store.saveDraft(id: saved.id, content: content, expectedRevision: saved.revision)
            XCTFail("An invalid container identity must not replace a draft")
        } catch InvoiceStore.StoreError.invalidDraft { }
        let restored = try await store.draft(id: saved.id)
        XCTAssertEqual(restored?.content, saved.content)
        XCTAssertNil(restored?.content.container)
        XCTAssertThrowsError(try JSONDecoder().decode(InvoiceContainer.self, from: Data(#"{"id":"67","name":"Ship"}"#.utf8)))
    }

    private func fixture(_ id: UInt32) -> InvoiceContainer {
        InvoiceContainer(id: id, name: "Ship \(id)", containerNumber: "TEST-\(id)")
    }

    private func envelope(_ containers: [InvoiceContainer]) throws -> Data {
        struct Envelope: Encodable { let success = true; let data: [InvoiceContainer] }
        return try JSONEncoder().encode(Envelope(data: containers))
    }

    private func makeClient() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContainerLookupProtocol.self]
        let contextID = UUID()
        return try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.test/v1")), session: URLSession(configuration: configuration)) { _ in
            APICredentials(sessionID: contextID, userID: "user", companyID: "company", idToken: "test-token")
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "container-tests-\(UUID())", directoryHint: .isDirectory)
    }
}

private final class ContainerLookupProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
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
