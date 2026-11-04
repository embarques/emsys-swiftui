import XCTest
@testable import EMSYS

@MainActor
final class InvoicePoolSynchronizationTests: XCTestCase {
    func testLostClaimResponseRetriesFrozenBytesAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let deviceID = try await store.invoicePoolDeviceID()
        let action = InvoicePoolAction(action: .claim, deviceID: deviceID)
        try await store.stageInvoicePoolAction(action)
        let frozen = try await store.invoicePoolActionPayload(id: action.id)
        let (client, session) = try makeClient([.failure(.networkConnectionLost)])
        defer { session.invalidateAndCancel() }
        do { try await InvoicePoolSynchronizer(client: client, store: store).synchronizeActions(); XCTFail("Lost response must remain pending") } catch { }
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        PoolProtocol.responses = [.success(Data(#"{"success":true,"data":[]}"#.utf8))]
        try await InvoicePoolSynchronizer(client: client, store: reopened).synchronizeActions()
        XCTAssertEqual(PoolProtocol.bodies, [frozen, frozen])
        XCTAssertEqual(PoolProtocol.paths, ["/v1/invoices/reserved/actions", "/v1/invoices/reserved/actions"])
        let pending = try await reopened.pendingInvoicePoolActions(); XCTAssertTrue(pending.isEmpty)
        let count = try await reopened.availableInvoiceReservationCount(); XCTAssertEqual(count, 0, "Only current assignment downloads can make numbers locally available")
    }

    func testFailedReturnRemainsQuarantinedAndPermissionLossCannotGenerateMore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        try await seedInvoicePoolFixture(store)
        let available = try await store.availableInvoiceReservations()
        let item = try XCTUnwrap(available.first)
        let deviceID = try await store.invoicePoolDeviceID()
        let action = InvoicePoolAction(action: .return, deviceID: deviceID, items: [item])
        try await store.stageInvoicePoolAction(action)
        let (client, session) = try makeClient([.status(403)])
        defer { session.invalidateAndCancel() }
        do { try await InvoicePoolSynchronizer(client: client, store: store).synchronizeActions(); XCTFail("Permission denial accepted") }
        catch APIClientError.httpStatus(403) { }
        let count = try await store.availableInvoiceReservationCount(); XCTAssertEqual(count, 99)
        let pending = try await store.pendingInvoicePoolActions(); XCTAssertEqual(pending.count, 1)
        let model = InvoicePoolModel(store: store, client: client, canGenerate: { false }, isAuthorized: { true })
        await model.generateNumbers()
        XCTAssertEqual(PoolProtocol.paths.count, 1)
    }

    func testUserThresholdPatchPreservesZeroAndOnlySendsTheThreshold() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let (client, session) = try makeClient([
            .success(Data(#"{"success":true,"data":{"invoicePoolThreshold":25,"language":"es","theme":"dark"}}"#.utf8)),
            .success(Data(#"{"success":true,"data":{"invoicePoolThreshold":0}}"#.utf8))
        ])
        defer { session.invalidateAndCancel() }
        let model = InvoicePoolPreferenceModel(store: store, client: client, isAuthorized: { true })
        await model.load()
        XCTAssertEqual(model.threshold, 25)
        XCTAssertFalse(model.canSave)
        model.threshold = 0
        await model.save()
        XCTAssertTrue(model.saved)
        let cached = try await store.invoicePoolThreshold()
        XCTAssertEqual(cached, 0)
        XCTAssertEqual(PoolProtocol.paths, ["/v1/users/me/preferences", "/v1/users/me/preferences"])
        XCTAssertEqual(PoolProtocol.methods, ["GET", "PATCH"])
        let body = try XCTUnwrap(PoolProtocol.bodies.last)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Int])
        XCTAssertEqual(sent, ["invoicePoolThreshold":0])
        model.threshold = 12
        XCTAssertFalse(model.saved)
    }

    func testFailedThresholdSaveRetainsCachedValueAndCanRetryWithoutChangingThePool() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        try await store.saveInvoicePoolThreshold(5)
        let (client, session) = try makeClient([.failure(.notConnectedToInternet), .failure(.networkConnectionLost)])
        defer { session.invalidateAndCancel() }
        var authorized = true
        let model = InvoicePoolPreferenceModel(store: store, client: client, isAuthorized: { authorized })
        await model.load()
        XCTAssertEqual(model.threshold, 5)
        XCTAssertNotNil(model.issue)
        model.threshold = -1
        XCTAssertFalse(model.canSave)
        model.threshold = 30
        await model.save()
        XCTAssertNotNil(model.issue)
        XCTAssertTrue(model.canSave)
        let cached = try await store.invoicePoolThreshold()
        XCTAssertEqual(cached, 5)
        authorized = false
        await model.save()
        XCTAssertEqual(PoolProtocol.paths.count, 2)
    }

    private func makeClient(_ responses: [PoolProtocol.Response]) throws -> (APIClient, URLSession) {
        PoolProtocol.responses = responses; PoolProtocol.bodies = []; PoolProtocol.paths = []; PoolProtocol.methods = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PoolProtocol.self]
        let session = URLSession(configuration: configuration)
        let context = UUID()
        return (try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.test/v1")), session: session) { _ in
            APICredentials(sessionID: context, userID: "user", companyID: "company", idToken: "fixture")
        }, session)
    }
}

private final class PoolProtocol: URLProtocol {
    enum Response { case success(Data), status(Int), failure(URLError.Code) }
    nonisolated(unsafe) static var responses: [Response] = []
    nonisolated(unsafe) static var paths: [String] = []
    nonisolated(unsafe) static var methods: [String] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.paths.append(request.url?.path ?? "")
        Self.methods.append(request.httpMethod ?? "")
        if let body = request.httpBody { Self.bodies.append(body) }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var body = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            Self.bodies.append(body)
        }
        guard !Self.responses.isEmpty else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let response = Self.responses.removeFirst()
        if case .failure(let code) = response { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        let status: Int
        let payload: Data
        switch response {
        case .success(let body): status = 201; payload = body
        case .status(let code): status = code; payload = Data()
        case .failure: return
        }
        guard let url = request.url, let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
