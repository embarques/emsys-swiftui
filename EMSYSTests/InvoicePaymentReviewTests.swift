import XCTest
@testable import EMSYS

@MainActor
final class InvoicePaymentReviewTests: XCTestCase {
    private var day: InvoiceDate { InvoiceDate(apiValue: "2026-10-25")! }

    func testSearchUsesNumericBranchAndTheActualBusinessDateFallbackWithoutPostingPayment() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        PaymentReviewProtocol.requests = []
        PaymentReviewProtocol.responses = [(200, try envelope([statement()]))]
        let model = InvoicePaymentReviewModel(day: day, client: try makeClient(), store: store,
            isAuthorized: { true }, currentBranchID: { 1 })
        await model.load(online: true)
        XCTAssertTrue(model.canSelect)
        XCTAssertFalse(model.isShowingDownloaded)
        let request = try XCTUnwrap(PaymentReviewProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/income-statements/search")
        XCTAssertEqual(request.httpMethod, "POST")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(object["limit"] as? Int, 1)
        let filters = try XCTUnwrap(object["filters"] as? [[String: Any]])
        XCTAssertEqual(filters.first?["field"] as? String, "branch.id")
        XCTAssertEqual(filters.first?["value"] as? Int, 1)
        let alternatives = try XCTUnwrap(filters.last?["filters"] as? [[String: Any]])
        XCTAssertEqual(alternatives.first?["field"] as? String, "businessDate")
        let legacy = try XCTUnwrap(alternatives.last?["filters"] as? [[String: Any]])
        XCTAssertEqual(legacy.first?["field"] as? String, "automated")
        XCTAssertEqual(legacy.first?["value"] as? Bool, true)
        let invoices = try await store.invoices()
        let edits = try await store.pendingEdits()
        XCTAssertTrue(invoices.isEmpty)
        XCTAssertTrue(edits.isEmpty)
        XCTAssertEqual(PaymentReviewProtocol.requests.count, 1)
    }

    func testUnknownAndConfirmedMissingCuadreRemainDistinctAndClosedCannotBeSelected() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        PaymentReviewProtocol.requests = []
        let model = InvoicePaymentReviewModel(day: day, client: try makeClient(), store: store,
            isAuthorized: { true }, currentBranchID: { 1 })
        await model.load(online: false)
        XCTAssertNil(model.review)
        XCTAssertEqual(model.issue, "paymentReview.notDownloaded")
        XCTAssertTrue(PaymentReviewProtocol.requests.isEmpty)
        PaymentReviewProtocol.responses = [(200, try envelope([InvoiceIncomeStatement]()))]
        await model.load(online: true)
        XCTAssertNotNil(model.review)
        XCTAssertNil(model.review?.statement)
        XCTAssertFalse(model.canSelect)
        XCTAssertNil(model.issue)
        PaymentReviewProtocol.responses = [(200, try envelope([statement(status: "closed")]))]
        await model.load(online: true)
        XCTAssertFalse(model.canSelect)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let saved = try await reopened.paymentReview(branchID: 1, day: day)
        XCTAssertEqual(saved?.statement?.status, "closed")
    }

    func testMismatchedStatementDoesNotReplaceCachedContextAndDenialHidesIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let previous = InvoicePaymentReview(branchID: 1, day: day, statement: statement(), downloadedAt: .now)
        try await store.savePaymentReview(previous)
        let model = InvoicePaymentReviewModel(day: day, client: try makeClient(), store: store,
            isAuthorized: { true }, currentBranchID: { 1 })
        PaymentReviewProtocol.responses = [(200, try envelope([statement(branchID: 2)]))]
        await model.load(online: true)
        XCTAssertEqual(model.review, previous)
        XCTAssertEqual(model.issue, "paymentReview.loadError")
        let unchanged = try await store.paymentReview(branchID: 1, day: day)
        XCTAssertEqual(unchanged, previous)
        PaymentReviewProtocol.responses = [(403, Data())]
        await model.load(online: true)
        XCTAssertNil(model.review)
        XCTAssertFalse(model.isAvailable)
        XCTAssertFalse(model.canSelect)
    }

    func testBranchChangeDuringRequestCannotCacheOrSelectTheOldBranchResponse() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        var currentBranch: UInt16? = 1
        let started = expectation(description: "Statement request is waiting for credentials")
        var finish: CheckedContinuation<Void, Never>?
        var first = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PaymentReviewProtocol.self]
        let contextID = UUID()
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.test/v1")), session: URLSession(configuration: configuration)) { _ in
            if first {
                first = false
                await withCheckedContinuation { continuation in finish = continuation; started.fulfill() }
            }
            return APICredentials(sessionID: contextID, userID: "user", companyID: "company", idToken: "test-token")
        }
        PaymentReviewProtocol.responses = [(200, try envelope([statement()]))]
        let model = InvoicePaymentReviewModel(day: day, client: client, store: store,
            isAuthorized: { true }, currentBranchID: { currentBranch })
        let task = Task { await model.load(online: true) }
        await fulfillment(of: [started], timeout: 3)
        currentBranch = 2
        finish?.resume()
        await task.value
        XCTAssertFalse(model.isAvailable)
        XCTAssertNil(model.review)
        let saved = try await store.paymentReview(branchID: 1, day: day)
        XCTAssertNil(saved)
    }

    func testReviewSurvivesDraftReopenAndIsScopedByUserTenantAPIBranchAndDate() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let review = InvoicePaymentReview(branchID: 1, day: day, statement: statement(), downloadedAt: .now)
        try await store.savePaymentReview(review)
        let editor = InvoiceDraftEditorModel(store: store, client: try makeClient(), canReviewPayments: { true }, currentBranchID: { 1 }, isAuthorized: { true })
        editor.selectPaymentReview(review)
        editor.content.paymentRegion = "RD"
        let draft = try await store.saveDraft(id: UUID(), content: editor.content, expectedRevision: nil)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let restored = try await reopened.draft(id: draft.id)
        XCTAssertEqual(restored?.content.paymentReview, review)
        XCTAssertEqual(restored?.content.paymentRegion, "RD")
        for (user, company, environment) in [
            ("other", "company", APIConfiguration.defaultRoot),
            ("user", "other", APIConfiguration.defaultRoot),
            ("user", "company", "https://other.example.test/v1")
        ] {
            let other = try await InvoiceStore.open(directory: directory, userID: user, companyID: company, apiEnvironment: environment)
            let saved = try await other.paymentReview(branchID: 1, day: day)
            XCTAssertNil(saved)
        }
        let wrongBranch = try await reopened.paymentReview(branchID: 2, day: day)
        let nextDay = try await reopened.paymentReview(branchID: 1, day: XCTUnwrap(InvoiceDate(apiValue: "2026-10-26")))
        XCTAssertNil(wrongBranch)
        XCTAssertNil(nextDay)
        var invalid = draft.content
        invalid.paymentReview = InvoicePaymentReview(branchID: 1, day: day, statement: statement(branchID: 2), downloadedAt: .now)
        do {
            _ = try await store.saveDraft(id: draft.id, content: invalid, expectedRevision: draft.revision)
            XCTFail("A different branch's statement must not replace saved work")
        } catch InvoiceStore.StoreError.invalidDraft { }
    }

    func testLegacyDateFallbackAndMissingProfileBranchFailSafely() async throws {
        XCTAssertNotNil(InvoiceDate(apiValue: "2024-02-29"))
        XCTAssertNil(InvoiceDate(apiValue: "2025-02-29"))
        XCTAssertNil(InvoiceDate(apiValue: "2026-02-30"))
        XCTAssertNil(InvoiceDate(apiValue: "2026-2-03"))
        XCTAssertNil(InvoiceDate(apiValue: "2026-+1-25"))
        XCTAssertNil(InvoiceDate(apiValue: "+026-10-25"))
        let legacy = InvoiceIncomeStatement(id: 1, businessDate: nil, date: "2026-10-25T00:00:00Z", timezone: nil,
            automated: false, branch: .init(id: 1, name: nil, code: nil), currency: nil, status: "OPEN")
        XCTAssertTrue(legacy.matches(branchID: 1, day: day))
        XCTAssertTrue(legacy.isOpen)
        let incompleteAutomated = InvoiceIncomeStatement(id: 1, businessDate: nil, date: "2026-10-25T00:00:00Z", timezone: nil,
            automated: true, branch: .init(id: 1, name: nil, code: nil), currency: nil, status: "open")
        XCTAssertFalse(incompleteAutomated.matches(branchID: 1, day: day))
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        PaymentReviewProtocol.requests = []
        let model = InvoicePaymentReviewModel(day: day, client: try makeClient(), store: store,
            isAuthorized: { true }, currentBranchID: { nil })
        await model.load(online: true)
        XCTAssertEqual(model.issue, "paymentReview.missingBranch")
        XCTAssertTrue(PaymentReviewProtocol.requests.isEmpty)
        XCTAssertFalse(model.canSelect)
    }

    private func statement(branchID: UInt16 = 1, status: String = "open") -> InvoiceIncomeStatement {
        InvoiceIncomeStatement(id: 100, businessDate: "2026-10-25", date: "2026-10-25T04:00:00Z", timezone: "America/New_York",
            automated: true, branch: .init(id: branchID, name: "Test Branch", code: "NY"), currency: "USD", status: status)
    }

    private func envelope(_ statements: [InvoiceIncomeStatement]) throws -> Data {
        struct Envelope: Encodable { let success = true; let data: [InvoiceIncomeStatement] }
        return try JSONEncoder().encode(Envelope(data: statements))
    }

    private func makeClient() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PaymentReviewProtocol.self]
        let contextID = UUID()
        return try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.test/v1")), session: URLSession(configuration: configuration)) { _ in
            APICredentials(sessionID: contextID, userID: "user", companyID: "company", idToken: "test-token")
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "payment-review-tests-\(UUID())", directoryHint: .isDirectory)
    }
}

private final class PaymentReviewProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            var payload = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                payload.append(buffer, count: count)
            }
            captured.httpBody = payload
        }
        Self.requests.append(captured)
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
