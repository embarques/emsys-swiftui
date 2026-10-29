import XCTest
@testable import EMSYS

@MainActor
final class InvoiceItemCatalogTests: XCTestCase {
    func testSelectionPreservesQuantityLabelsAndManualTotalAndDraftSurvivesReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        var allowed = true
        let editor = InvoiceDraftEditorModel(store: store, canViewItemCatalog: { allowed }, isAuthorized: { true })
        let row = InvoiceDraft.Item(name: "Typed", quantity: "3", unitPrice: "2", labelCount: "2", total: "25")
        editor.content.items = [row]
        let selected = InvoiceCatalogItem(id: 7, name: "CAJA GRANDE", price: 12.5, createdAt: nil)
        editor.selectCatalogItem(selected, for: row.id)
        XCTAssertEqual(editor.content.items[0].name, "CAJA GRANDE")
        XCTAssertEqual(editor.content.items[0].unitPrice, "12.50")
        XCTAssertEqual(editor.content.items[0].quantity, "3")
        XCTAssertEqual(editor.content.items[0].labelCount, "2")
        XCTAssertEqual(editor.content.items[0].total, "25")
        editor.content.items[0].total = ""
        editor.selectCatalogItem(selected, for: row.id)
        XCTAssertEqual(editor.amounts?.subtotal, 37.5)
        editor.content.items[0].name = "Custom merchandise"
        let saved = try await store.saveDraft(id: UUID(), content: editor.content, expectedRevision: nil)
        let reopened = try await store.draft(id: saved.id)
        XCTAssertEqual(reopened?.content.items[0].name, "Custom merchandise")
        allowed = false
        editor.selectCatalogItem(selected, for: row.id)
        XCTAssertEqual(editor.content.items[0].name, "Custom merchandise")
        allowed = true
        editor.removeItem(id: row.id)
        editor.selectCatalogItem(selected, for: row.id)
        XCTAssertTrue(editor.content.items.isEmpty)
    }

    func testCatalogIsDurableScopedAndSearchMatchesDescriptionsNewestFirst() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let older = InvoiceCatalogItem(id: 1, name: "CAJA PEQUEÑA", price: 10, createdAt: "2026-10-01T00:00:00Z")
        let newer = InvoiceCatalogItem(id: 2, name: "Caja grande", price: 20, createdAt: "2026-10-26T00:00:00Z")
        try await store.saveItemCatalog([older, newer])
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let editor = InvoiceDraftEditorModel(store: reopened, canViewItemCatalog: { true }, isAuthorized: { true })
        await editor.loadItemCatalog(online: false)
        XCTAssertEqual(InvoiceCatalogItem.matching(editor.catalogItems, query: " caja ").map(\.id), [2, 1])
        XCTAssertEqual(InvoiceCatalogItem.matching(editor.catalogItems, query: "pequena").map(\.id), [1])
        XCTAssertTrue(editor.catalogIsDownloaded)
        let other = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "other")
        let otherCatalog = try await other.itemCatalog()
        XCTAssertTrue(otherCatalog.isEmpty)
        do {
            try await store.saveItemCatalog([older, older])
            XCTFail("Duplicate identities cannot replace the downloaded catalog")
        } catch InvoiceStore.StoreError.invalidPageContents { }
        let preserved = try await store.itemCatalog()
        XCTAssertEqual(preserved, [older, newer])
    }

    func testDownloadUsesActualEndpointAndFailedRefreshPreservesOfflineCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        CatalogProtocol.status = 200
        CatalogProtocol.body = Data(#"{"success":true,"data":[{"id":8,"name":"BARRIL","price":45.5,"createdAt":"2026-10-26T00:00:00Z"}]}"#.utf8)
        CatalogProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let contextID = UUID()
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.test/v1")), session: session) { _ in
            APICredentials(sessionID: contextID, userID: "user", companyID: "company", idToken: "test-token")
        }
        let editor = InvoiceDraftEditorModel(store: store, client: client, canViewItemCatalog: { true }, isAuthorized: { true })
        await editor.loadItemCatalog(online: true)
        XCTAssertEqual(editor.catalogItems.first?.name, "BARRIL")
        XCTAssertFalse(editor.catalogIsDownloaded)
        XCTAssertEqual(CatalogProtocol.requests.first?.url?.path, "/v1/invoice-descriptions")
        XCTAssertEqual(CatalogProtocol.requests.first?.httpMethod, "GET")
        CatalogProtocol.status = 500
        await editor.loadItemCatalog(online: true)
        XCTAssertEqual(editor.catalogItems.first?.id, 8)
        XCTAssertEqual(editor.catalogIssue, "itemCatalog.loadError")
        XCTAssertTrue(editor.catalogIsDownloaded)
        let saved = try await store.itemCatalog()
        XCTAssertEqual(saved.first?.id, 8)
        CatalogProtocol.status = 403
        await editor.loadItemCatalog(online: true)
        XCTAssertTrue(editor.catalogItems.isEmpty)
        XCTAssertEqual(editor.catalogIssue, "auth.unavailable")
    }
}

private final class CatalogProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
