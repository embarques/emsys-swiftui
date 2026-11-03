import Foundation
import Observation

/// A public availability probe, independent of login, uploads and synchronization.
@MainActor
@Observable
final class APIHealthCheckModel {
    enum Status: String {
        case idle, checking, healthy, unhealthy, serverError, unexpectedResponse, unreachable, timedOut, invalidConfiguration
        var title: String { "apiHealth.status." + rawValue }
    }

    let baseURL: URL?
    private(set) var status: Status = .idle
    private(set) var checkedAt: Date?
    private(set) var httpStatus: Int?
    @ObservationIgnored private let session: URLSession

    init(baseURL: URL? = APIConfiguration.baseURL, session: URLSession? = nil) {
        if let baseURL, baseURL.scheme == "https", baseURL.host != nil,
           baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil {
            self.baseURL = baseURL
        } else { self.baseURL = nil }
        if let session { self.session = session }
        else {
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

    deinit { session.invalidateAndCancel() }

    func check() async {
        guard status != .checking, !Task.isCancelled else { return }
        httpStatus = nil
        checkedAt = nil
        guard let baseURL else {
            status = .invalidConfiguration
            checkedAt = .now
            return
        }
        status = .checking
        do {
            var request = URLRequest(url: baseURL.appending(path: "health"))
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.url == request.url else {
                status = .unexpectedResponse
                checkedAt = .now
                return
            }
            httpStatus = response.statusCode
            if !(200..<300).contains(response.statusCode) { status = .serverError }
            else {
                let health = try JSONDecoder().decode(APIResponse<Health>.self, from: bytes)
                status = health.success && health.data.status == "ok" ? .healthy : .unhealthy
            }
        } catch is CancellationError { status = .idle; return }
        catch let error as URLError where error.code == .cancelled { status = .idle; return }
        catch let error as URLError where error.code == .timedOut { status = .timedOut }
        catch is DecodingError { status = .unexpectedResponse }
        catch { status = .unreachable }
        checkedAt = .now
    }

    private struct Health: Decodable { let status: String }
}

private final class HealthRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
