import Foundation
import Observation

/// Displays public API availability independently of sign-in and synchronization.
@MainActor
@Observable
final class APIHealthCheckViewModel {
    enum Status: String {
        case idle, checking, healthy, unhealthy, serverError, unexpectedResponse, unreachable, timedOut, invalidConfiguration

        /// Returns the localized label key for this connection result.
        var title: String { "apiHealth.status." + rawValue }
    }

    let baseURL: URL?
    private(set) var status: Status = .idle
    private(set) var checkedAt: Date?
    private(set) var httpStatus: Int?
    @ObservationIgnored private let probe: APIHealthProbe

    /// Sets up a health check for a valid public endpoint and optional test session.
    init(baseURL: URL? = APIConfiguration.baseURL, session: URLSession? = nil) {
        // The health check uses only an HTTPS origin without embedded credentials.
        if let baseURL, baseURL.scheme == "https", baseURL.host != nil,
           baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil {
            self.baseURL = baseURL
        } else {
            self.baseURL = nil
        }
        probe = APIHealthProbe(session: session)
    }

    /// Checks the server once and publishes the result unless the request was cancelled.
    func check() async {
        guard status != .checking, !Task.isCancelled else {
            return
        }
        httpStatus = nil
        checkedAt = nil
        guard let baseURL else {
            status = .invalidConfiguration
            checkedAt = .now
            return
        }

        status = .checking
        do {
            // Present the result and response code captured by the availability probe.
            let result = try await probe.check(baseURL: baseURL)
            httpStatus = result.httpStatus
            status = result.status
        } catch is CancellationError {
            status = .idle
            return
        } catch let error as URLError where error.code == .cancelled {
            status = .idle
            return
        } catch let error as URLError where error.code == .timedOut {
            status = .timedOut
        } catch is DecodingError {
            status = .unexpectedResponse
        } catch {
            status = .unreachable
        }
        checkedAt = .now
    }
}

/// Sends the connection check without app credentials, cookies, or cached responses.
@MainActor
private final class APIHealthProbe {
    private let session: URLSession

    /// Configures an isolated URL session unless the caller supplies a test session.
    init(session: URLSession?) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: configuration, delegate: HealthRedirectPolicy(), delegateQueue: nil)
        }
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Returns the response code and interpreted health result from the configured endpoint.
    func check(baseURL: URL) async throws -> (status: APIHealthCheckViewModel.Status, httpStatus: Int?) {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()

        // Only an HTTP response from the requested endpoint counts as a health result.
        guard let response = response as? HTTPURLResponse, response.url == request.url else {
            return (.unexpectedResponse, nil)
        }
        let responseCode = response.statusCode
        guard (200..<300).contains(responseCode) else {
            return (.serverError, responseCode)
        }

        // Keep the HTTP code even when a successful response has an unexpected body.
        do {
            let health = try JSONDecoder().decode(APIResponse<Health>.self, from: bytes)
            let status: APIHealthCheckViewModel.Status = health.success && health.data.status == "ok"
                ? .healthy : .unhealthy
            return (status, responseCode)
        } catch is DecodingError {
            return (.unexpectedResponse, responseCode)
        }
    }

    private struct Health: Decodable {
        let status: String
    }
}

private final class HealthRedirectPolicy: NSObject, URLSessionTaskDelegate {
    /// Refuses redirects so the result always pertains to the configured health endpoint.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
