import SwiftUI
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import EMSYS

@MainActor
final class InvoiceDirectoryTests: XCTestCase {
    func testSearchPayloadUsesNumericBalanceAndCombinesPartySearchWithFilters() throws {
        var query = InvoiceListQuery()
        query.text = "  TEST CLIENT  "
        query.scope = .due
        query.container = "TEST-ROUTE"
        query.startDate = "2026-10-01"
        let data = try JSONEncoder().encode(query.request(page: 3))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["page"] as? Int, 3)
        XCTAssertEqual(object["limit"] as? Int, 50)
        XCTAssertEqual(object["operator"] as? String, "and")
        let filters = try XCTUnwrap(object["filters"] as? [[String: Any]])
        let balance = try XCTUnwrap(filters.first { $0["field"] as? String == "balance" })
        XCTAssertEqual(balance["value"] as? Int, 0)
        XCTAssertNil(balance["value"] as? String)
        let parties = try XCTUnwrap(filters.first?["filters"] as? [[String: Any]])
        XCTAssertEqual(Set(parties.compactMap { $0["field"] as? String }),
            Set(["number", "sender.name", "receiver.name", "container.name", "container.containerNumber"]))
        XCTAssertTrue(parties.allSatisfy { $0["value"] as? String == "TEST CLIENT" })
    }

    func testDownloadedSearchFiltersAndPaginationSurviveReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "directory-user", companyID: "directory-company")
        let invoices = try (1...120).map { try fixture($0) }
        try await store.saveDownloaded(invoices)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "directory-user", companyID: "directory-company")
        let first = try await reopened.matchingInvoices(.init())
        let second = try await reopened.matchingInvoices(.init(), offset: 50)
        let third = try await reopened.matchingInvoices(.init(), offset: 100)
        XCTAssertEqual([first.count, second.count, third.count], [50, 50, 20])
        XCTAssertEqual(Set((first + second + third).map(\.id)).count, 120)
        XCTAssertEqual(first.first?.number, "TEST-120")
        var query = InvoiceListQuery()
        query.text = "Test Sender"
        query.scope = .due
        query.startDate = "2026-10-01"
        query.endDate = "2026-10-31"
        let due = try await reopened.matchingInvoices(query, limit: 200)
        XCTAssertEqual(due.count, 60)
        query.scope = .paid
        let paid = try await reopened.matchingInvoices(query, limit: 200)
        XCTAssertEqual(paid.count, 60, "Paid status must work when the API omits zero balance")
        query.scope = .incomplete
        let pending = try await reopened.matchingInvoices(query, limit: 200)
        XCTAssertEqual(pending.count, 12)
        query.text = "%_"
        let literal = try await reopened.matchingInvoices(query)
        XCTAssertTrue(literal.isEmpty, "SQL wildcards in user input must be literal search text")
        query.text = "No such customer"
        let empty = try await reopened.matchingInvoices(query)
        XCTAssertTrue(empty.isEmpty)
        let balance = try await reopened.downloadedBalance()
        XCTAssertEqual(balance, Decimal(600))
    }

    func testNativeListRefreshDoesNotReplaceSavedInvoiceDetails() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let detail = try JSONDecoder().decode(Invoice.self, from: Data(
            #"{"id":"000000000000000000000001","invoiceDetails":[{"id":"detail","name":"Saved item"}]}"#.utf8))
        try await store.saveDownloaded([detail])
        try await store.saveDownloaded([fixture(1)], asList: true)
        let saved = try await store.invoice(id: detail.id)
        XCTAssertEqual(saved?.invoiceDetails?.first?.name, "Saved item")
    }

    func testContinuousLoadingFailureRetryAndOfflineSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InvoiceDirectoryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let identity = UUID()
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://api.example.test/v1")), session: session) { _ in
            APICredentials(sessionID: identity, userID: "user", companyID: "company", idToken: "fixture")
        }
        let batch = try (1...50).map { try fixture($0) }
        InvoiceDirectoryProtocol.responses = [(200, try envelope(batch)), (503, Data("{}".utf8)),
            (200, try envelope([batch[49], fixture(51)]))]
        InvoiceDirectoryProtocol.requests = []
        let model = InvoiceListModel(client: client, store: store)
        let loader = InvoiceListLoader()
        await loader.prepare { throw URLError(.cannotOpenFile) }
        XCTAssertTrue(loader.failed)
        await loader.prepare { model }
        XCTAssertTrue(loader.model === model)
        XCTAssertFalse(loader.failed)
        await model.load()
        XCTAssertEqual(model.invoices.count, 50)
        XCTAssertTrue(model.hasMore)
        await model.loadMore()
        XCTAssertEqual(model.invoices.count, 50)
        XCTAssertNotNil(model.issue)
        await model.retry(online: true)
        XCTAssertEqual(model.invoices.count, 51)
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.issue)
        let requests = InvoiceDirectoryProtocol.requests
        XCTAssertEqual(requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value }, ["1", "2", "2"])
        var query = InvoiceListQuery()
        query.text = "TEST-051"
        await model.load(query: query, online: false)
        XCTAssertEqual(model.invoices.map(\.number), ["TEST-051"])
        XCTAssertEqual(InvoiceDirectoryProtocol.requests.count, 3, "Offline search must not need API access")
        XCTAssertTrue(model.isShowingDownloaded)
    }

    func testLiveResultsOfflineCacheReconnectAndAuthorizationFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        try await store.saveDownloaded([fixture(1)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InvoiceDirectoryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let identity = UUID()
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://api.example.test/v1")), session: session) { _ in
            APICredentials(sessionID: identity, userID: "user", companyID: "company", idToken: "fixture")
        }
        let model = InvoiceListModel(client: client, store: store)
        InvoiceDirectoryProtocol.responses = []
        InvoiceDirectoryProtocol.requests = []
        InvoiceDirectoryProtocol.nextError = .notConnectedToInternet
        await model.load(online: true)
        XCTAssertTrue(model.isShowingDownloaded)
        XCTAssertEqual(model.invoices.map(\.number), ["TEST-001"])
        XCTAssertNil(model.issue)

        InvoiceDirectoryProtocol.responses = [(200, try envelope([fixture(2)]))]
        await model.load(online: true)
        XCTAssertFalse(model.isShowingDownloaded)
        XCTAssertEqual(model.invoices.map(\.number), ["TEST-002"], "Online results must come from the current API page, not the saved directory")
        await model.load(online: false)
        XCTAssertTrue(model.isShowingDownloaded)
        XCTAssertEqual(model.invoices.map(\.number), ["TEST-002", "TEST-001"])
        XCTAssertEqual(InvoiceDirectoryProtocol.requests.count, 2, "Offline mode must not call the API")

        InvoiceDirectoryProtocol.responses = [(403, Data(#"{"success":false,"message":"Forbidden"}"#.utf8))]
        await model.load(online: true)
        XCTAssertFalse(model.isShowingDownloaded)
        XCTAssertTrue(model.invoices.isEmpty, "An authorization failure must never be hidden by cached invoices")
        XCTAssertNotNil(model.issue)
        InvoiceDirectoryProtocol.responses = [(200, try envelope([fixture(3)]))]
        await model.retry(online: true)
        XCTAssertEqual(model.invoices.map(\.number), ["TEST-003"])
        XCTAssertNil(model.issue)
    }

    func testInitialDateDescendingListLoadsEvenWhenNavigationTaskIsCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InvoiceDirectoryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let identity = UUID()
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://api.example.test/v1")), session: session) { _ in
            APICredentials(sessionID: identity, userID: "user", companyID: "company", idToken: "fixture")
        }
        InvoiceDirectoryProtocol.responses = [(200, try envelope([fixture(3), fixture(2), fixture(1)]))]
        InvoiceDirectoryProtocol.requests = []
        let model = InvoiceListModel(client: client, store: store)
        let loader = InvoiceListLoader()
        let presentation = Task {
            await loader.prepare {
                try await Task.sleep(for: .milliseconds(50))
                return model
            }
            if let prepared = loader.model { await prepared.request(query: .init(), online: true).value }
        }
        try await Task.sleep(for: .milliseconds(10))
        presentation.cancel()
        await presentation.value
        XCTAssertTrue(loader.model === model)
        XCTAssertFalse(loader.failed)
        XCTAssertEqual(model.invoices.map(\.number), ["TEST-003", "TEST-002", "TEST-001"])
        let request = try XCTUnwrap(InvoiceDirectoryProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/invoices")
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "page" }?.value, "1")
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "50")
        XCTAssertEqual(query.first { $0.name == "sort" }?.value, "date:desc,id:desc")
        var superseded = InvoiceListQuery()
        superseded.text = "Superseded search"
        model.request(query: superseded, online: true, debounce: true)
        await model.request(query: .init(), online: false, debounce: true).value
        XCTAssertEqual(InvoiceDirectoryProtocol.requests.count, 1, "A replaced search must not send a stale request")
        XCTAssertEqual(model.invoices.count, 3)
    }

    func testLocalPreparationTimeoutAndCancellationExposeRetryState() async throws {
        let loader = InvoiceListLoader()
        await loader.prepare(timeout: .milliseconds(20)) {
            try await Task.sleep(for: .seconds(60))
            throw URLError(.timedOut)
        }
        XCTAssertTrue(loader.failed)
        XCTAssertNil(loader.model)
        await loader.prepare { throw CancellationError() }
        XCTAssertTrue(loader.failed, "Cancelled initial navigation must not leave an endless spinner")
        await loader.prepare { throw URLError(.cannotOpenFile) }
        XCTAssertTrue(loader.failed)
    }

    #if os(macOS)
    func testNativeDirectoryRendersCompactDarkAndLightAndLargeText() async throws {
        let invoices = try [fixture(120), fixture(119), fixture(118)]
        for (width, scheme, size, name) in [(390, ColorScheme.dark, DynamicTypeSize.large, "dark"),
            (320, .light, .large, "compact"), (390, .dark, .accessibility2, "large-text")] {
            let content = InvoiceDirectoryView(query: .constant(.init()), invoices: invoices,
                outstandingBalance: 600, isLoading: false, isDownloaded: true, hasMore: true, issue: nil,
                showFilters: {}, open: { _ in }, printInvoice: { _ in }, more: {}, retry: {}, refresh: {})
                .environment(\.locale, Locale(identifier: "en"))
                .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size)
                .frame(width: CGFloat(width), height: 844)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 844),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame = window.contentLayoutRect
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: FileManager.default.temporaryDirectory.appending(path: "emsys-swiftui-invoices-\(name).png"))
            XCTAssertEqual(host.bounds.width, CGFloat(width))
            window.close()
        }
    }
    #endif

    private func fixture(_ index: Int) throws -> Invoice {
        let paid = index % 2 == 0
        let data = Data("""
        {"id":"\(String(format: "%024x", index))","number":"TEST-\(String(format: "%03d", index))",
         "date":"2026-10-24T00:00:00Z","sender":{"name":"Test Sender \(index)",
         "address":{"address1":"100 Sample Street","city":"Test City","state":"NY","zipcode":"10000"}},
         "receiver":{"name":"Test Receiver"},"paidStatus":"\(paid ? "CLOSED" : "OPEN")",
         "registration":"\(index % 10 == 0 ? "PENDING" : "COMPLETE")",\(paid ? "" : "\"balance\":10,")
         "container":{"name":"TEST-ROUTE"},"itemCount":2}
        """.utf8)
        return try JSONDecoder().decode(Invoice.self, from: data)
    }

    private func envelope(_ invoices: [Invoice]) throws -> Data {
        struct Envelope: Encodable { let success = true; let data: [Invoice] }
        return try JSONEncoder().encode(Envelope(data: invoices))
    }
}

private final class InvoiceDirectoryProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var nextError: URLError.Code?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let code = Self.nextError {
            Self.nextError = nil
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        guard !Self.responses.isEmpty, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (status, data) = Self.responses.removeFirst()
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
