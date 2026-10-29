import Foundation

/// Authenticated EMSYS requests. Business records belong in local persistence,
/// not the URL loading cache.
@MainActor
final class APIClient {
    typealias CredentialsProvider = (_ forceRefresh: Bool) async throws -> APICredentials

    private let baseURL: URL
    private let session: URLSession
    private let uploadSession: URLSession
    private let credentials: CredentialsProvider

    init(
        baseURL: URL,
        session: URLSession? = nil,
        credentials: @escaping CredentialsProvider
    ) throws {
        guard baseURL.scheme == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw APIClientError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.session = session ?? Self.makeSession()
        self.uploadSession = session ?? Self.makeSession(resourceTimeout: 180)
        self.credentials = credentials
    }

    func get<Value: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        as type: Value.Type
    ) async throws -> Value {
        try await request(path, queryItems: queryItems, method: "GET", body: nil, as: type)
    }

    func post<Body: Encodable, Value: Decodable>(
        _ path: String,
        body: Body,
        queryItems: [URLQueryItem] = [],
        as type: Value.Type
    ) async throws -> Value {
        let payload = try JSONEncoder().encode(body)
        return try await request(path, queryItems: queryItems, method: "POST", body: payload, as: type)
    }

    /// A durable outbox owns these already-encoded bytes. Retries must preserve
    /// them rather than rebuilding a request from changing screen state.
    func post<Value: Decodable>(
        _ path: String,
        encodedBody: Data,
        as type: Value.Type
    ) async throws -> Value {
        try await request(path, queryItems: [], method: "POST", body: encodedBody, as: type)
    }

    /// Preserve the immutable payload of an existing-record outbox operation.
    func put<Value: Decodable>(
        _ path: String,
        encodedBody: Data,
        as type: Value.Type
    ) async throws -> Value {
        try await request(path, queryItems: [], method: "PUT", body: encodedBody, as: type)
    }

    func upload<Value: Decodable>(
        _ path: String, encodedBody: Data, boundary: String, as type: Value.Type
    ) async throws -> Value {
        guard boundary.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }),
              !boundary.isEmpty, boundary.count <= 70 else { throw APIClientError.invalidPath }
        return try await request(path, queryItems: [], method: "POST", body: encodedBody,
            contentType: "multipart/form-data; boundary=\(boundary)", isUpload: true, as: type)
    }

    private func request<Value: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem],
        method: String,
        body: Data?,
        contentType: String = "application/json",
        isUpload: Bool = false,
        as type: Value.Type
    ) async throws -> Value {
        // Only relative, unescaped resource paths are accepted. An arbitrary URL
        // must never receive a Firebase token or tenant header.
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, segments.allSatisfy({ segment in
            !segment.isEmpty && segment != "." && segment != ".."
                && segment.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
                }
        }) else {
            throw APIClientError.invalidPath
        }

        let initialCredentials = try await credentials(false)
        try validate(initialCredentials)
        guard var components = URLComponents(
            url: baseURL.appending(path: path), resolvingAgainstBaseURL: false
        ) else { throw APIClientError.invalidPath }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw APIClientError.invalidPath }
        var result = try await load(url, method: method, body: body, contentType: contentType, isUpload: isUpload, credentials: initialCredentials)

        if result.response.statusCode == 401 {
            let refreshedCredentials = try await credentials(true)
            try validate(refreshedCredentials)
            guard refreshedCredentials.sessionID == initialCredentials.sessionID,
                  refreshedCredentials.userID == initialCredentials.userID,
                  refreshedCredentials.companyID == initialCredentials.companyID else {
                throw APIClientError.sessionChanged
            }
            result = try await load(url, method: method, body: body, contentType: contentType, isUpload: isUpload, credentials: refreshedCredentials)
        }

        // A logout or tenant change during a request must not expose the previous
        // session's response to its replacement.
        let currentCredentials = try await credentials(false)
        guard currentCredentials.sessionID == initialCredentials.sessionID,
              currentCredentials.userID == initialCredentials.userID,
              currentCredentials.companyID == initialCredentials.companyID else {
            throw APIClientError.sessionChanged
        }
        guard (200..<300).contains(result.response.statusCode) else {
            throw APIClientError.httpStatus(result.response.statusCode)
        }
        let envelope = try JSONDecoder().decode(APIResponse<Value>.self, from: result.data)
        guard envelope.success else { throw APIClientError.unsuccessfulResponse }
        return envelope.data
    }

    private func validate(_ credentials: APICredentials) throws {
        guard !credentials.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.companyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.idToken.isEmpty,
              !credentials.companyID.contains(where: { $0.isNewline }),
              !credentials.idToken.contains(where: { $0.isNewline }) else {
            throw APIClientError.missingCredentials
        }
    }

    private func load(
        _ url: URL,
        method: String,
        body: Data?,
        contentType: String,
        isUpload: Bool,
        credentials: APICredentials
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.idToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.companyID, forHTTPHeaderField: "X-Company-ID")
        let (data, response) = try await (isUpload ? uploadSession : session).data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.url == url else {
            throw APIClientError.invalidResponse
        }
        return (data, response)
    }

    private static func makeSession(resourceTimeout: TimeInterval = 60) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration, delegate: APIRedirectPolicy(), delegateQueue: nil)
    }
}

private final class APIRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // The API root is configured explicitly; redirects are not part of its
        // contract and could forward tenant context to another origin.
        completionHandler(nil)
    }
}
