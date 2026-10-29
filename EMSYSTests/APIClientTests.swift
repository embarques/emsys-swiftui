import XCTest
@testable import EMSYS

@MainActor
final class APIClientTests: XCTestCase {
    func testReportPostPreservesExactJSONAcrossTokenRefresh() async throws {
        struct ReportRequest: Encodable {
            let invoiceIds: [String]
        }
        let session = makeSession(statuses: [401, 200])
        defer { session.invalidateAndCancel() }
        let client = try APIClient(baseURL: baseURL, session: session) { _ in self.firstCredentials }
        let body = ReportRequest(invoiceIds: ["68f800000000000000000001"])
        let profile = try await client.post("reports/invoices/signature-options", body: body, as: Profile.self)
        XCTAssertEqual(profile.name, "Test User")
        XCTAssertEqual(APIStubProtocol.requests.count, 2)
        let expected = try JSONEncoder().encode(body)
        for request in APIStubProtocol.requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            // URLSession may deliver a body stream to URLProtocol instead of
            // retaining httpBody. Read the fixture stream without logging it.
            if let payload = request.httpBody {
                XCTAssertEqual(payload, expected)
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                var payload = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    payload.append(buffer, count: count)
                }
                XCTAssertEqual(payload, expected)
            }
        }
    }
    func testSavedPostPreservesExactBytesAcrossRefresh() async throws {
        let session = makeSession(statuses: [401, 200])
        defer { session.invalidateAndCancel() }
        let client = try APIClient(baseURL: baseURL, session: session) { _ in self.firstCredentials }
        // Formatting and key order distinguish saved JSON from a re-encoded value.
        let payload = Data(#"{ "requestId": "1331d28d-846d-42f4-8c99-a828d8f482ae", "invoice": {"cost":10.00} }"#.utf8)
        let result = try await client.post("invoices/sync/create", encodedBody: payload, as: Profile.self)
        XCTAssertEqual(result.name, "Test User")
        XCTAssertEqual(APIStubProtocol.requests.count, 2)
        for request in APIStubProtocol.requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/invoices/sync/create")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(try requestBody(request), payload)
        }
    }

    func testSavedPostNeverFallsBackAfterUnavailableSyncRoute() async throws {
        let session = makeSession(statuses: [404])
        defer { session.invalidateAndCancel() }
        let client = try APIClient(baseURL: baseURL, session: session) { _ in self.firstCredentials }
        do {
            let _: Profile = try await client.post("journals/sync", encodedBody: Data("{}".utf8), as: Profile.self)
            XCTFail("An unavailable route must remain an error")
        } catch {
            XCTAssertEqual(error as? APIClientError, .httpStatus(404))
        }
        XCTAssertEqual(APIStubProtocol.requests.count, 1)
        XCTAssertEqual(APIStubProtocol.requests.first?.url?.path, "/v1/journals/sync")
    }

    func testMultipartUploadPreservesBytesAndTenantAcrossTokenRefresh() async throws {
        let session = makeSession(statuses: [401, 200])
        defer { session.invalidateAndCancel() }
        let client = try APIClient(baseURL: baseURL, session: session) { _ in self.firstCredentials }
        let file = try InvoiceAttachment.prepare(name: "proof.pdf", bytes: Data("%PDF-1.7\nfixture".utf8))
        let payload = try file.attachment.multipart(bytes: file.bytes)
        let _: Profile = try await client.upload("invoices/000000000000000000000001/documents", encodedBody: payload,
            boundary: file.attachment.boundary, as: Profile.self)
        XCTAssertEqual(APIStubProtocol.requests.count, 2)
        for request in APIStubProtocol.requests {
            XCTAssertEqual(try requestBody(request), payload)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=\(file.attachment.boundary)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Company-ID"), "test-company")
        }
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        var body = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }

    private struct Profile: Decodable {
        let name: String
    }

    private let sessionID = UUID()

    private var firstCredentials: APICredentials {
        APICredentials(
            sessionID: sessionID, userID: "test-user",
            companyID: "test-company", idToken: "initial-token"
        )
    }

    func testUnauthorizedRefreshesOnceAndPreservesTenant() async throws {
        let session = makeSession(statuses: [401, 200])
        defer { session.invalidateAndCancel() }
        var refreshCount = 0
        let client = try APIClient(baseURL: baseURL, session: session) { forceRefresh in
            if forceRefresh { refreshCount += 1 }
            return APICredentials(
                sessionID: self.sessionID, userID: "test-user", companyID: "test-company",
                idToken: refreshCount == 0 ? "initial-token" : "refreshed-token"
            )
        }

        let profile = try await client.get("users/current", as: Profile.self)
        XCTAssertEqual(profile.name, "Test User")
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(APIStubProtocol.requests.count, 2)
        XCTAssertEqual(APIStubProtocol.requests.first?.url?.path, "/v1/users/current")
        XCTAssertEqual(APIStubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-token")
        XCTAssertTrue(APIStubProtocol.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Company-ID") == "test-company"
                && $0.value(forHTTPHeaderField: "App-Id") == nil
                && $0.value(forHTTPHeaderField: "Api-Key") == nil
        })
    }

    func testRepeatedUnauthorizedDoesNotLoop() async throws {
        let session = makeSession(statuses: [401, 401])
        defer { session.invalidateAndCancel() }
        var refreshCount = 0
        let client = try APIClient(baseURL: baseURL, session: session) { forceRefresh in
            if forceRefresh { refreshCount += 1 }
            return self.firstCredentials
        }
        do {
            _ = try await client.get("users/current", as: Profile.self)
            XCTFail("Expected unauthorized response")
        } catch {
            XCTAssertEqual(error as? APIClientError, .httpStatus(401))
        }
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(APIStubProtocol.requests.count, 2)
    }

    func testForbiddenDoesNotRefresh() async throws {
        let session = makeSession(statuses: [403])
        defer { session.invalidateAndCancel() }
        var refreshCount = 0
        let client = try APIClient(baseURL: baseURL, session: session) { forceRefresh in
            if forceRefresh { refreshCount += 1 }
            return self.firstCredentials
        }
        do {
            _ = try await client.get("users/permissions", as: Profile.self)
            XCTFail("Expected forbidden response")
        } catch {
            XCTAssertEqual(error as? APIClientError, .httpStatus(403))
        }
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(APIStubProtocol.requests.count, 1)
    }

    func testTenantChangeDuringRefreshPreventsRetry() async throws {
        let session = makeSession(statuses: [401])
        defer { session.invalidateAndCancel() }
        let client = try APIClient(baseURL: baseURL, session: session) { forceRefresh in
            APICredentials(
                sessionID: self.sessionID, userID: "test-user", companyID: forceRefresh ? "other-company" : "test-company",
                idToken: "test-token"
            )
        }
        do {
            _ = try await client.get("users/current", as: Profile.self)
            XCTFail("Expected session boundary failure")
        } catch {
            XCTAssertEqual(error as? APIClientError, .sessionChanged)
        }
        XCTAssertEqual(APIStubProtocol.requests.count, 1)
    }

    func testSessionChangeDiscardsSuccessfulResponse() async throws {
        let session = makeSession(statuses: [200])
        defer { session.invalidateAndCancel() }
        var credentialReads = 0
        let client = try APIClient(baseURL: baseURL, session: session) { _ in
            credentialReads += 1
            return APICredentials(
                sessionID: self.sessionID, userID: credentialReads == 1 ? "test-user" : "replacement-user",
                companyID: "test-company", idToken: "test-token"
            )
        }
        do {
            _ = try await client.get("users/current", as: Profile.self)
            XCTFail("Expected old response to be discarded")
        } catch {
            XCTAssertEqual(error as? APIClientError, .sessionChanged)
        }
    }

    func testInvalidPathsNeverSendCredentials() async throws {
        let session = makeSession(statuses: [])
        defer { session.invalidateAndCancel() }
        let client = try APIClient(baseURL: baseURL, session: session) { _ in
            XCTFail("Invalid path must be rejected before requesting a token")
            return self.firstCredentials
        }
        for path in ["https://other.example/users", "/users", "../users", "users/%2e%2e", "users?token=x"] {
            do {
                _ = try await client.get(path, as: Profile.self)
                XCTFail("Expected invalid path")
            } catch {
                XCTAssertEqual(error as? APIClientError, .invalidPath)
            }
        }
        XCTAssertTrue(APIStubProtocol.requests.isEmpty)
    }

    func testNewSessionForSameUserDiscardsOldResponse() async throws {
        let session = makeSession(statuses: [200])
        defer { session.invalidateAndCancel() }
        var credentialReads = 0
        let client = try APIClient(baseURL: baseURL, session: session) { _ in
            credentialReads += 1
            return APICredentials(
                sessionID: credentialReads == 1 ? self.sessionID : UUID(),
                userID: "test-user", companyID: "test-company", idToken: "test-token"
            )
        }
        do {
            _ = try await client.get("users/current", as: Profile.self)
            XCTFail("A fresh sign-in must not receive the prior session's response")
        } catch {
            XCTAssertEqual(error as? APIClientError, .sessionChanged)
        }
    }

    func testOnlineListShowsServerFailureWithoutReplacingItWithCachedInvoices() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "EMSYS.Tests.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "test-user", companyID: "test-company")
        let invoice = try JSONDecoder().decode(Invoice.self, from:
            Data(#"{"id":"68f800000000000000000001","number":"CACHED-001"}"#.utf8)
        )
        try await store.saveDownloaded([invoice], page: 1)
        let session = makeSession(statuses: [503])
        defer { session.invalidateAndCancel() }
        let client = try APIClient(baseURL: baseURL, session: session) { _ in self.firstCredentials }
        let model = InvoiceListModel(client: client, store: store)
        await model.load()
        XCTAssertTrue(model.invoices.isEmpty)
        XCTAssertFalse(model.isShowingDownloaded)
        XCTAssertEqual(model.issue, "invoices.refreshError")
        XCTAssertFalse(model.isLoading)
        let query = try XCTUnwrap(APIStubProtocol.requests.first?.url)
        let components = try XCTUnwrap(URLComponents(url: query, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "sort" }?.value, "date:desc,id:desc")
    }

    private var baseURL: URL { URL(string: "https://api.example.test/v1")! }

    func testSynchronizationRefreshesSavedPagesAndDetails() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "EMSYS.Tests.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "test-user", companyID: "test-company")
        let invoice = try JSONDecoder().decode(Invoice.self, from:
            Data(#"{"id":"68f800000000000000000001","number":"OLD"}"#.utf8))
        try await store.saveDownloaded([invoice])
        try await store.saveDownloaded([invoice], page: 2)
        let session = makeSession(statuses: [200, 200, 200])
        defer { session.invalidateAndCancel() }
        APIStubProtocol.bodies = [
            Data(#"{"success":true,"data":[]}"#.utf8),
            Data(#"{"success":true,"data":[]}"#.utf8),
            Data("""
                {"success":true,"data":{"revision":"v1:\(String(repeating: "a", count: 64))",
                  "invoice":{"id":"68f800000000000000000001","number":"UPDATED"}}}
                """.utf8)
        ]
        let client = try APIClient(baseURL: baseURL, session: session) { _ in self.firstCredentials }
        try await InvoiceSynchronizer(client: client, store: store).synchronize()
        let saved = try await store.invoice(id: invoice.id)
        XCTAssertEqual(saved?.number, "UPDATED")
        XCTAssertEqual(APIStubProtocol.requests.count, 3)
        let pageNumbers = APIStubProtocol.requests.prefix(2).compactMap {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
        }
        XCTAssertEqual(pageNumbers, ["1", "2"])
        let pages = try await store.downloadedPages()
        XCTAssertEqual(pages, [1, 2])
        let editable = try await store.editSnapshot(invoiceID: invoice.id)
        XCTAssertNotNil(editable)
    }

    func testUnavailableSyncReadFallsBackWithoutCreatingAWritableSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let session = makeSession(statuses: [404, 200])
        defer { session.invalidateAndCancel() }
        APIStubProtocol.bodies = [Data("{}".utf8), Data(#"{"success":true,"data":{"id":"68f800000000000000000001","number":"READ-ONLY"}}"#.utf8)]
        let client = try APIClient(baseURL: baseURL, session: session) { _ in self.firstCredentials }
        try await InvoiceDetailDownloader(client: client, store: store).download(invoiceID: "68f800000000000000000001")
        let saved = try await store.invoice(id: "68f800000000000000000001")
        let editable = try await store.editSnapshot(invoiceID: "68f800000000000000000001")
        XCTAssertEqual(saved?.number, "READ-ONLY")
        XCTAssertNil(editable)
        XCTAssertEqual(APIStubProtocol.requests.map { $0.httpMethod }, ["GET", "GET"])
    }

    private func makeSession(statuses: [Int]) -> URLSession {
        APIStubProtocol.statuses = statuses
        APIStubProtocol.requests = []
        APIStubProtocol.bodies = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIStubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class APIStubProtocol: URLProtocol {
    // XCTest runs this suite serially; each awaited request completes before the
    // next fixture is installed. No real network or account is used.
    nonisolated(unsafe) static var statuses: [Int] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard !Self.statuses.isEmpty, let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: Self.statuses.removeFirst(),
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = Self.bodies.isEmpty
            ? Data(#"{"success":true,"data":{"name":"Test User"}}"#.utf8)
            : Self.bodies.removeFirst()
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
