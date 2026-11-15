import Foundation

/// Capability downloads have no API credentials, cookies or persistent cache.
/// Streaming bounds memory even when a response omits Content-Length.
actor ReportDownloader {
    private let protocolClasses: [AnyClass]?

    init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
    }

    func download(_ url: URL) async throws -> Data {
        guard url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw DocumentError.invalidURL
        }
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(
            configuration: configuration, delegate: ReportRedirectPolicy(), delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200, response.url == url,
              response.mimeType?.lowercased() == "application/pdf" else {
            throw DocumentError.invalidResponse
        }
        guard response.expectedContentLength <= InvoiceDocument.maximumBytes else {
            throw DocumentError.tooLarge
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            if data.count == InvoiceDocument.maximumBytes { throw DocumentError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        try InvoiceDocument.validate(data)
        return data
    }
}

private final class ReportRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
