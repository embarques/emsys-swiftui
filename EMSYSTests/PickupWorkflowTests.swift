import XCTest
#if os(iOS)
import SwiftUI
import UIKit
#endif
@testable import EMSYS

@MainActor
final class PickupWorkflowTests: XCTestCase {
    #if os(iOS)
    func testNativePickupDetailRendersQueuedCompletionAndDownloadedContact() async throws {
        try await withModel(responses: [(200, fixture())]) { model, _ in
            await model.complete(online: false)
            let host = UIHostingController(rootView: NavigationStack {
                PickupDetailView(model: model, createInvoice: { _, _ in throw APIClientError.sessionChanged })
            }.environment(NetworkConnection()).environment(SynchronizationState()).environment(\.locale, Locale(identifier: "es-DO")))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.effectiveGeometry.coordinateSpace.bounds
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKey() }
            try await Task.sleep(for: .milliseconds(600))
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            XCTAssertEqual(model.pickup.pendingCompletion, true)
            XCTAssertEqual(model.pickup.sender?.name, "María García")
            XCTAssertEqual(model.pickup.comments?.first?.quantity, 2)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory.appending(path: "emsys-pickup-\(device).png"))
        }
    }
    #endif
    func testSnapshotsSurviveReopenAndRemainScopedToUserTenantAndServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await PickupStore.open(directory: directory, userID: "a", companyID: "a")
        try await store.save([fixture()])
        let reopened = try await PickupStore.open(directory: directory, userID: "a", companyID: "a")
        let saved = try await reopened.pickups(matching: .init(text: "garcia"))
        XCTAssertEqual(saved.map(\.id), [42])
        for (user, tenant, server) in [("b", "a", APIConfiguration.defaultRoot),
                                        ("a", "b", APIConfiguration.defaultRoot),
                                        ("a", "a", "https://other.example/v1")] {
            let other = try await PickupStore.open(directory: directory, userID: user, companyID: tenant, apiEnvironment: server)
            let records = try await other.pickups(matching: .init())
            XCTAssertTrue(records.isEmpty)
        }
        do {
            try await store.save([fixture(id: 43), fixture(id: 0)])
            XCTFail("Invalid page must roll back")
        } catch { XCTAssertTrue(error is PickupStore.StoreError) }
        let invalid = try await store.pickup(id: 43)
        XCTAssertNil(invalid)
    }

    func testCompletionPostsFrozenIdentityAndPersistsServerConfirmation() async throws {
        try await withModel(responses: [(200, fixture(completed: true))]) { model, store in
            await model.complete(online: true)
            XCTAssertTrue(model.pickup.completed)
            XCTAssertNil(model.completion)
            XCTAssertFalse(model.canComplete)
            XCTAssertNil(model.issue)
            XCTAssertEqual(PickupStub.requests.map(\.httpMethod), ["POST"])
            XCTAssertEqual(PickupStub.requests.first?.url?.path, "/v1/pickups/sync/42/complete")
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(PickupStub.bodies.first)) as? [String: String])
            XCTAssertNotNil(payload["requestId"].flatMap(UUID.init(uuidString:)))
            XCTAssertEqual(payload["revision"], "v1:" + String(repeating: "a", count: 64))
            let saved = try await store.pickup(id: 42)
            XCTAssertEqual(saved?.completed, true)
        }
    }

    func testLostResponseRetriesTheSameCompletionInsteadOfCreatingAnother() async throws {
        try await withModel(responses: [(503, fixture()), (200, fixture(completed: true))]) { model, store in
            await model.complete(online: true)
            XCTAssertTrue(model.pickup.completed)
            XCTAssertEqual(model.completion?.state, .pending)
            XCTAssertEqual(model.issue, "pickupSync.retryHint")
            await model.complete(online: true)
            XCTAssertEqual(PickupStub.requests.count, 1)
            await model.retryCompletion()
            XCTAssertNil(model.completion)
            XCTAssertNil(model.issue)
            XCTAssertEqual(PickupStub.bodies.count, 2)
            XCTAssertEqual(PickupStub.bodies[0], PickupStub.bodies[1])
            let count = try await store.activeCompletionCount()
            XCTAssertEqual(count, 0)
        }
    }

    func testOfflineCompletionIsDurableAndDeniedReadHidesButProtectsPendingWork() async throws {
        try await withModel(responses: [(403, fixture())]) { model, store in
            await model.complete(online: false)
            XCTAssertTrue(PickupStub.requests.isEmpty)
            let saved = try await store.pickup(id: 42)
            XCTAssertEqual(saved?.pendingCompletion, true)
            await model.refresh(online: true)
            XCTAssertTrue(model.isUnavailable)
            let hidden = try await store.pickup(id: 42)
            XCTAssertNil(hidden)
            let operations = try await store.pendingCompletions()
            XCTAssertEqual(operations.count, 1)
            let visible = try await store.pickups(matching: .init(status: .completed))
            XCTAssertTrue(visible.isEmpty)
        }
    }

    func testServerAlreadyCompletedIsNotOverwrittenAndReadOnlyRoleCannotMutate() async throws {
        try await withModel(responses: [(200, fixture(completed: true))]) { model, _ in
            await model.refresh(online: true)
            await model.complete(online: true)
            XCTAssertTrue(model.pickup.completed)
            XCTAssertEqual(PickupStub.requests.map(\.httpMethod), ["GET"])
        }
        try await withModel(responses: [], canUpdate: false) { model, store in
            await model.complete(online: false)
            XCTAssertTrue(PickupStub.requests.isEmpty)
            let operations = try await store.pendingCompletions()
            XCTAssertTrue(operations.isEmpty)
        }
    }

    func testConflictRequiresReviewAndDoesNotFallBackToUnsafePut() async throws {
        try await withModel(responses: [(409, fixture()), (200, fixture())]) { model, store in
            await model.complete(online: true)
            XCTAssertEqual(model.completion?.state, .needsReview)
            XCTAssertTrue(model.requiresRefresh)
            XCTAssertFalse(model.canRetry)
            await model.discardRejectedCompletion()
            XCTAssertNil(model.completion)
            XCTAssertFalse(model.requiresRefresh)
            XCTAssertEqual(PickupStub.requests.map(\.httpMethod), ["POST", "GET"])
            let count = try await store.activeCompletionCount()
            XCTAssertEqual(count, 0)
        }
    }

    func testListOfflineSearchAndNetworkDownloadUseDurableRecords() async throws {
        let numberQuery = PickupListQuery(text: "42")
        let encodedQuery = try JSONEncoder().encode(numberQuery.request(page: 1))
        let queryObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedQuery) as? [String: Any])
        let filters = try XCTUnwrap(queryObject["filters"] as? [[String: Any]])
        XCTAssertEqual(filters.first?["value"] as? UInt32, 42, "The API requires numeric JSON for pickup IDs")
        XCTAssertTrue(numberQuery.matches(try fixture()))
        XCTAssertFalse(numberQuery.matches(try fixture(id: 142)))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await PickupStore.open(directory: directory, userID: "a", companyID: "a")
        try await store.save([fixture()])
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let model = PickupListModel(client: try client(session), store: store, isAuthorized: { true })
        await model.load(query: .init(text: "garcia"), online: false)
        XCTAssertEqual(model.pickups.map(\.id), [42])
        XCTAssertTrue(model.isShowingDownloaded)
        XCTAssertTrue(PickupStub.requests.isEmpty)
        PickupStub.responses = [(200, try JSONEncoder().encode([snapshot(try fixture(id: 43))]))]
        await model.load(query: .init(), online: true)
        XCTAssertEqual(model.pickups.map(\.id), [43])
        XCTAssertFalse(model.isShowingDownloaded)
        let persisted = try await store.pickup(id: 43)
        XCTAssertNotNil(persisted)
        let request = try XCTUnwrap(PickupStub.requests.last)
        XCTAssertEqual(request.url?.path, "/v1/pickups/sync/search")
        XCTAssertTrue(request.url?.query?.contains("completed=false") == true)
        PickupStub.responses = [(403, Data("[]".utf8))]
        await model.load(query: .init(), online: true)
        XCTAssertTrue(model.pickups.isEmpty)
        let deniedCache = try await store.pickups(matching: .init())
        XCTAssertTrue(deniedCache.isEmpty, "Server denial must not masquerade as offline access")
    }

    private func withModel(responses: [(Int, Pickup)], canUpdate: Bool = true,
                           perform: (PickupDetailModel, PickupStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await PickupStore.open(directory: directory, userID: "a", companyID: "a")
        let pickup = try fixture()
        try await store.save(snapshot(pickup))
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        PickupStub.responses = try responses.map { ($0.0, try JSONEncoder().encode(snapshot($0.1))) }
        let model = PickupDetailModel(pickup: pickup, client: try client(session), store: store,
            isAuthorized: { true }, canUpdate: { canUpdate })
        await model.refresh(online: false)
        try await perform(model, store)
    }

    private func snapshot(_ pickup: Pickup) -> PickupSyncSnapshot {
        PickupSyncSnapshot(pickup: pickup, revision: "v1:" + String(repeating: pickup.completed ? "b" : "a", count: 64))
    }

    private func fixture(id: UInt32 = 42, completed: Bool = false) throws -> Pickup {
        try JSONDecoder().decode(Pickup.self, from: Data("""
        {"id":\(id),"date":"2026-10-26T00:00:00Z","completed":\(completed),
        "sender":{"name":"María García","phones":[{"number":"+1 (809) 555-0100"}],
        "address":{"address1":"123 Calle Principal","city":"Santiago"}},
        "route":{"id":"68f800000000000000000007","name":"Ruta Norte"},"branch":{"id":7,"name":"Sucursal Norte"},
        "comments":[{"purpose":"PICKUP","quantity":2,"unit":"box","description":"Recoger dos cajas"}]}
        """.utf8))
    }

    private func makeSession() -> URLSession {
        PickupStub.requests = []
        PickupStub.bodies = []
        PickupStub.responses = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PickupStub.self]
        return URLSession(configuration: configuration)
    }

    private func client(_ session: URLSession) throws -> APIClient {
        try APIClient(baseURL: URL(string: "https://example.test/v1")!, session: session) { _ in
            APICredentials(sessionID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                userID: "a", companyID: "a", idToken: "fixture")
        }
    }

    private func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 1024)
        var result = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            result.append(bytes, count: count)
        }
        return result
    }
}

private final class PickupStub: URLProtocol {
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        Self.bodies.append(body)
        guard !Self.responses.isEmpty, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, rawData) = Self.responses.removeFirst()
        var data = rawData
        if request.url?.path.hasSuffix("/complete") == true,
           let sent = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           var reply = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] {
            reply["requestId"] = sent["requestId"]
            if let encoded = try? JSONSerialization.data(withJSONObject: reply) { data = encoded }
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"success":true,"data":"#.utf8) + data + Data("}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
