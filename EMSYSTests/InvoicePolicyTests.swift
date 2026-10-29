import XCTest
@testable import EMSYS

@MainActor
final class InvoicePolicyTests: XCTestCase {
    func testAllActivePolicyPagesAreDownloadedBeforeReturningReviewContent() async throws {
        let first = (1...40).map { policy(Int64($0)) }
        let last = [policy(41)]
        PolicyDownloadProtocol.responses = [(200, try envelope(first)), (200, try envelope(last))]
        PolicyDownloadProtocol.requests = []
        let downloaded = try await InvoicePolicyDownloader(client: makeClient()).download { true }
        XCTAssertEqual(downloaded, first + last)
        XCTAssertEqual(PolicyDownloadProtocol.requests.count, 2)
        let query = URLComponents(url: try XCTUnwrap(PolicyDownloadProtocol.requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "page" })?.value, "2")
        XCTAssertEqual(query?.first(where: { $0.name == "limit" })?.value, "40")
    }

    func testFailedLaterPageAndRepeatedPageCannotReplaceSavedPolicyReview() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let previous = [policy(99)]
        try await store.savePolicies(previous)
        let first = (1...40).map { policy(Int64($0)) }
        let editor = InvoiceDraftEditorModel(store: store, client: try makeClient(), canReviewPolicies: { true }, isAuthorized: { true })
        PolicyDownloadProtocol.responses = [(200, try envelope(first)), (500, Data())]
        await editor.loadPolicies(online: true)
        XCTAssertEqual(editor.content.policies, previous)
        XCTAssertEqual(editor.policyIssue, "policies.unavailable")
        let saved = try await store.policies()
        XCTAssertEqual(saved, previous)
        PolicyDownloadProtocol.responses = [(200, try envelope(first)), (200, try envelope(first))]
        await editor.loadPolicies(online: true)
        XCTAssertEqual(editor.content.policies, previous)
        XCTAssertEqual(editor.policyIssue, "policies.unavailable")
        let unchanged = try await store.policies()
        XCTAssertEqual(unchanged, previous)
    }

    func testUnknownAndExplicitlyEmptyPoliciesRemainDistinctAcrossDraftReopenAndScope() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let unknown = try await store.policies()
        XCTAssertNil(unknown)
        let editor = InvoiceDraftEditorModel(store: store, client: try makeClient(), canReviewPolicies: { true }, isAuthorized: { true })
        await editor.loadPolicies(online: false)
        XCTAssertNil(editor.content.policies)
        XCTAssertEqual(editor.policyIssue, "policies.unavailable")
        PolicyDownloadProtocol.responses = [(200, Data("{\"success\":true,\"data\":null}".utf8))]
        await editor.loadPolicies(online: true)
        XCTAssertEqual(editor.content.policies, [])
        XCTAssertNil(editor.policyIssue)
        let draft = try await store.saveDraft(id: UUID(), content: editor.content, expectedRevision: nil)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let restored = try await reopened.draft(id: draft.id)
        XCTAssertEqual(restored?.content.policies, [])
        let empty = try await reopened.policies()
        XCTAssertEqual(empty, [])
        let other = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "other")
        let isolated = try await other.policies()
        XCTAssertNil(isolated)
    }

    func testPoliciesPersistWithTheDraftAndInvalidReplacementRollsBack() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        var content = InvoiceDraft.Content()
        content.policies = [policy(1)]
        let saved = try await store.saveDraft(id: UUID(), content: content, expectedRevision: nil)
        content.policies = [policy(1), policy(1)]
        do {
            _ = try await store.saveDraft(id: saved.id, content: content, expectedRevision: saved.revision)
            XCTFail("Duplicate review text identities must not replace the saved draft")
        } catch InvoiceStore.StoreError.invalidDraft { }
        let restored = try await store.draft(id: saved.id)
        XCTAssertEqual(restored?.content, saved.content)
        let editor = InvoiceDraftEditorModel(draftID: saved.id, store: store, client: try makeClient(), canReviewPolicies: { true }, isAuthorized: { true })
        await editor.load()
        await editor.loadPolicies(online: false)
        XCTAssertEqual(editor.content.policies, saved.content.policies)
        XCTAssertFalse(editor.hasChanges)
    }

    func testUnavailablePermissionDoesNotLoadOrReplacePolicies() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        try await store.savePolicies([policy(1)])
        let editor = InvoiceDraftEditorModel(store: store, client: try makeClient(), canReviewPolicies: { false }, isAuthorized: { true })
        await editor.loadPolicies(online: true)
        XCTAssertNil(editor.content.policies)
        XCTAssertFalse(editor.canLoadPolicies)
        do {
            _ = try await InvoicePolicyDownloader(client: makeClient()).download { false }
            XCTFail("A revoked context must stop before requesting policies")
        } catch APIClientError.sessionChanged { }
    }

    private func policy(_ id: Int64) -> InvoicePolicy {
        InvoicePolicy(id: id, title: "Policy \(id)", body: "Synthetic policy body.\nSecond paragraph.", sortOrder: Int(id), active: true, updatedAt: nil)
    }

    private func envelope(_ policies: [InvoicePolicy]) throws -> Data {
        struct Envelope: Encodable { let success = true; let data: [InvoicePolicy] }
        return try JSONEncoder().encode(Envelope(data: policies))
    }

    private func makeClient() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PolicyDownloadProtocol.self]
        let contextID = UUID()
        return try APIClient(baseURL: URL(string: "https://example.test/v1")!, session: URLSession(configuration: configuration)) { _ in
            APICredentials(sessionID: contextID, userID: "user", companyID: "company", idToken: "test-token")
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "policy-tests-\(UUID())", directoryHint: .isDirectory)
    }
}

private final class PolicyDownloadProtocol: URLProtocol {
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
