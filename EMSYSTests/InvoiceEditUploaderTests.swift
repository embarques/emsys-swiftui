import XCTest
@testable import EMSYS

@MainActor
final class InvoiceEditUploaderTests: XCTestCase {
    private let invoiceID = "68f800000000000000000001"
    private let itemID = "68f800000000000000000002"

    func testLostResponseRetriesIdenticalBodyAfterReopeningDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let original = try snapshot(name: "Box", revision: "a")
        try await store.saveEditSnapshot(original)
        let edit = try await store.queueItemNames(invoiceID: invoiceID, names: [itemID: "Offline box"])
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = try makeClient(session: session)
        EditStubProtocol.requests = []
        EditStubProtocol.failure = URLError(.networkConnectionLost)
        do {
            try await InvoiceEditUploader(client: client, store: store).synchronize()
            XCTFail("Lost response must leave durable pending work")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let pending = try await reopened.pendingEdits()
        XCTAssertEqual(pending.first?.id, edit.id)
        XCTAssertEqual(pending.first?.attempts, 1)
        EditStubProtocol.failure = nil
        EditStubProtocol.status = 200
        EditStubProtocol.response = try response(snapshot(name: "Offline box", revision: "b"))
        try await InvoiceEditUploader(client: client, store: reopened).synchronize()
        XCTAssertEqual(EditStubProtocol.requests.map(\.body), [edit.requestBody, edit.requestBody])
        XCTAssertTrue(EditStubProtocol.requests.allSatisfy {
            $0.method == "PUT" && $0.path == "/v1/invoices/sync/\(invoiceID)"
        })
        let completed = try await reopened.pendingEdits()
        let local = try await reopened.invoice(id: invoiceID)
        XCTAssertTrue(completed.isEmpty)
        XCTAssertEqual(local?.invoiceDetails?.first?.name, "Offline box")
    }

    func testConflictsAndUnavailableRoutesNeverUseUnconditionalWrites() async throws {
        for (status, state) in [(409, PendingInvoiceEdit.State.needsReview),
                                (403, .authorizationRequired), (404, .serverUnavailable)] {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
            try await store.saveEditSnapshot(snapshot(name: "Box", revision: "a"))
            let edit = try await store.queueItemNames(invoiceID: invoiceID, names: [itemID: "Keep my work"])
            let session = makeSession()
            defer { session.invalidateAndCancel() }
            let client = try makeClient(session: session)
            EditStubProtocol.requests = []
            EditStubProtocol.failure = nil
            EditStubProtocol.status = status
            EditStubProtocol.response = Data("{}".utf8)
            do {
                try await InvoiceEditUploader(client: client, store: store).synchronize()
                XCTFail("A blocked operation cannot be reported as synchronized")
            } catch InvoiceEditUploader.UploadError.attentionRequired { }
            let saved = try await store.activeEdit(invoiceID: invoiceID)
            XCTAssertEqual(saved?.id, edit.id)
            XCTAssertEqual(saved?.requestBody, edit.requestBody)
            XCTAssertEqual(saved?.state, state)
            let local = try await store.invoice(id: invoiceID)
            XCTAssertEqual(local?.invoiceDetails?.first?.name, "Keep my work")
            XCTAssertEqual(EditStubProtocol.requests.count, 1)
            XCTAssertEqual(EditStubProtocol.requests.first?.path, "/v1/invoices/sync/\(invoiceID)")
        }
    }

    private func snapshot(name: String, revision: String) throws -> InvoiceEditSnapshot {
        let data = Data("""
            {"revision":"v1:\(String(repeating: revision, count: 64))","invoice":{
              "id":"\(invoiceID)","number":"TEST-001","cost":20,"balance":20,
              "invoiceDetails":[{"id":"\(itemID)","name":"\(name)","quantity":2,"labels":2,"price":10,"total":20}]
            }}
            """.utf8)
        return try JSONDecoder().decode(InvoiceEditSnapshot.self, from: data)
    }

    private func response(_ snapshot: InvoiceEditSnapshot) throws -> Data {
        struct Envelope: Encodable { let success = true; let data: InvoiceEditSnapshot }
        return try JSONEncoder().encode(Envelope(data: snapshot))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EditStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeClient(session: URLSession) throws -> APIClient {
        let sessionID = UUID()
        return try APIClient(baseURL: URL(string: "https://api.example.test/v1")!, session: session) { _ in
            APICredentials(sessionID: sessionID, userID: "user", companyID: "company", idToken: "fixture-token")
        }
    }
}

private final class EditStubProtocol: URLProtocol {
    struct RecordedRequest {
        let method: String?
        let path: String?
        let body: Data
    }
    nonisolated(unsafe) static var requests: [RecordedRequest] = []
    nonisolated(unsafe) static var failure: URLError?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var response = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        Self.requests.append(RecordedRequest(method: request.httpMethod, path: request.url?.path, body: body))
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
