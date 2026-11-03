import XCTest
#if os(iOS)
import SwiftUI
import UIKit
#endif
@testable import EMSYS

@MainActor
final class APIHealthCheckTests: XCTestCase {
    func testHealthyProbeUsesOnlyPublicHealthEndpointWithoutCredentials() async throws {
        let model = makeModel()
        await model.check()
        XCTAssertEqual(model.status, .healthy)
        XCTAssertEqual(model.httpStatus, 200)
        XCTAssertNotNil(model.checkedAt)
        let request = try XCTUnwrap(HealthStubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/custom/v2/health")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Company-ID"))
        XCTAssertEqual(request.cachePolicy, .useProtocolCachePolicy)
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(HealthStubProtocol.requests.count, 1)
    }

    func testFailedProbeCanRecoverWithoutClearingFailedSynchronization() async {
        let sync = SynchronizationState()
        await sync.synchronize { throw URLError(.notConnectedToInternet) }
        let model = makeModel(statuses: [503, 200])
        await model.check()
        XCTAssertEqual(model.status, .serverError)
        XCTAssertEqual(model.httpStatus, 503)
        await model.check()
        XCTAssertEqual(model.status, .healthy)
        XCTAssertEqual(model.httpStatus, 200)
        XCTAssertTrue(sync.failed)
        XCTAssertNil(sync.lastSucceededAt)
    }

    func testUnexpectedUnhealthyAndTimedOutResponsesDoNotReportSuccess() async {
        let malformed = makeModel(body: "<html>Unavailable</html>")
        await malformed.check()
        XCTAssertEqual(malformed.status, .unexpectedResponse)
        let unhealthy = makeModel(body: #"{"success":true,"data":{"status":"down"}}"#)
        await unhealthy.check()
        XCTAssertEqual(unhealthy.status, .unhealthy)
        let failure = makeModel(body: #"{"success":false,"data":{"status":"ok"}}"#)
        await failure.check()
        XCTAssertEqual(failure.status, .unhealthy)
        let timeout = makeModel(error: URLError(.timedOut))
        await timeout.check()
        XCTAssertEqual(timeout.status, .timedOut)
        XCTAssertNil(timeout.httpStatus)
        XCTAssertNotNil(timeout.checkedAt)
        let offline = makeModel(error: URLError(.notConnectedToInternet))
        await offline.check()
        XCTAssertEqual(offline.status, .unreachable)
    }

    func testInvalidConfigurationAndCancellationNeverClaimACompletedCheck() async {
        let session = makeSession()
        for value in [nil, "http://api.example.test/v1", "https://user:secret@api.example.test/v1", "https://api.example.test/v1?token=secret"] as [String?] {
            let model = APIHealthCheckModel(baseURL: value.flatMap(URL.init(string:)), session: session)
            await model.check()
            XCTAssertEqual(model.status, .invalidConfiguration)
            XCTAssertNil(model.baseURL)
        }
        XCTAssertTrue(HealthStubProtocol.requests.isEmpty)
        let cancelled = makeModel(error: URLError(.cancelled))
        await cancelled.check()
        XCTAssertEqual(cancelled.status, .idle)
        XCTAssertNil(cancelled.checkedAt)
    }

    #if os(iOS)
    func testNativeConnectionSectionShowsSpanishHealthResult() async throws {
        let model = makeModel()
        let host = UIHostingController(rootView: NavigationStack {
            List { APIConnectionSection(model: model) }.navigationTitle("navigation.more")
        }.environment(\.locale, Locale(identifier: "es-DO")))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        await model.check()
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        XCTAssertEqual(model.status, .healthy)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory.appending(path: "emsys-api-health-\(device).png"))
    }
    #endif

    private func makeModel(statuses: [Int] = [200], body: String = #"{"success":true,"data":{"status":"ok"}}"#,
                           error: URLError? = nil) -> APIHealthCheckModel {
        let session = makeSession(statuses: statuses, body: body, error: error)
        return APIHealthCheckModel(baseURL: URL(string: "https://api.example.test/custom/v2"), session: session)
    }

    private func makeSession(statuses: [Int] = [200], body: String = #"{"success":true,"data":{"status":"ok"}}"#,
                             error: URLError? = nil) -> URLSession {
        HealthStubProtocol.statuses = statuses
        HealthStubProtocol.body = Data(body.utf8)
        HealthStubProtocol.failure = error
        HealthStubProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthStubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class HealthStubProtocol: URLProtocol {
    nonisolated(unsafe) static var statuses: [Int] = []
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var failure: URLError?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let failure = Self.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        guard !Self.statuses.isEmpty, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: Self.statuses.removeFirst(), httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
