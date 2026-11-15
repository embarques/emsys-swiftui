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

    /// Creates API sessions restricted to the configured HTTPS origin.
    init(
        baseURL: URL,
        session: URLSession? = nil,
        credentials: @escaping CredentialsProvider
    ) throws {
        // A configured API root cannot contain credentials or a request-specific query.
        guard baseURL.scheme == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw APIClientError.invalidBaseURL
        }
        // Uploads get a longer resource timeout because their bodies can contain files.
        self.baseURL = baseURL
        self.session = session ?? Self.makeSession()
        self.uploadSession = session ?? Self.makeSession(resourceTimeout: 180)
        self.credentials = credentials
    }

    /// Reads an API response with the tenant and session attached.
    func get<Value: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        as type: Value.Type
    ) async throws -> Value {
        try await request(path, queryItems: queryItems, method: "GET", body: nil, as: type)
    }

    /// Encodes a new request body once and returns the decoded response data.
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
        capturesServerFailure: Bool = false,
        as type: Value.Type
    ) async throws -> Value {
        try await request(path, queryItems: [], method: "POST", body: encodedBody, capturesServerFailure: capturesServerFailure, as: type)
    }

    /// Preserve the immutable payload of an existing-record outbox operation.
    func put<Value: Decodable>(
        _ path: String,
        encodedBody: Data,
        as type: Value.Type
    ) async throws -> Value {
        try await request(path, queryItems: [], method: "PUT", body: encodedBody, as: type)
    }

    /// Updates a resource using a JSON body and the current tenant credentials.
    func patch<Body: Encodable, Value: Decodable>(
        _ path: String, body: Body, as type: Value.Type
    ) async throws -> Value {
        let payload = try JSONEncoder().encode(body)
        return try await request(path, queryItems: [], method: "PATCH", body: payload, as: type)
    }

    /// Sends the multipart body prepared from an immutable attachment.
    func upload<Value: Decodable>(
        _ path: String, encodedBody: Data, boundary: String, as type: Value.Type
    ) async throws -> Value {
        // Validate the boundary before placing it in an HTTP header.
        let isSafeBoundary = boundary.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
        }
        guard isSafeBoundary, !boundary.isEmpty, boundary.count <= 70 else {
            throw APIClientError.invalidPath
        }
        let contentType = "multipart/form-data; boundary=\(boundary)"
        return try await request(path, queryItems: [], method: "POST", body: encodedBody,
            contentType: contentType, isUpload: true, as: type)
    }

    /// Sends a request, refreshes credentials once when required, and decodes the result.
    private func request<Value: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem],
        method: String,
        body: Data?,
        contentType: String = "application/json",
        isUpload: Bool = false,
        capturesServerFailure: Bool = false,
        as type: Value.Type
    ) async throws -> Value {
        // Reject unsafe paths before creating a request with authorization headers.
        try validateResourcePath(path)

        // Capture the scope that must remain stable until the response is returned.
        let initialCredentials = try await credentials(false)
        try validate(initialCredentials)
        guard var components = URLComponents(
            url: baseURL.appending(path: path), resolvingAgainstBaseURL: false
        ) else {
            throw APIClientError.invalidPath
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw APIClientError.invalidPath
        }
        var result = try await load(url, method: method, body: body, contentType: contentType, isUpload: isUpload, credentials: initialCredentials)

        // Retry a rejected token once using fresh credentials from the original scope.
        if result.response.statusCode == 401 {
            let refreshedCredentials = try await credentials(true)
            try validate(refreshedCredentials)
            try requireSameScope(refreshedCredentials, as: initialCredentials)
            result = try await load(url, method: method, body: body, contentType: contentType, isUpload: isUpload, credentials: refreshedCredentials)
        }

        // A logout or tenant change during a request must not expose the previous
        // session's response to its replacement.
        let currentCredentials = try await credentials(false)
        try requireSameScope(currentCredentials, as: initialCredentials)

        // Surface structured business errors only when the caller requested them.
        guard (200..<300).contains(result.response.statusCode) else {
            if capturesServerFailure {
                let response = try? JSONDecoder().decode(APIServerFailure.Envelope.self, from: result.data)
                throw APIServerFailure(status: result.response.statusCode, code: response?.data?.code,
                                       message: response?.message)
            }
            throw APIClientError.httpStatus(result.response.statusCode)
        }
        let envelope = try JSONDecoder().decode(APIResponse<Value>.self, from: result.data)
        guard envelope.success else {
            throw APIClientError.unsuccessfulResponse
        }
        return envelope.data
    }

    /// Rejects paths that fall outside the API's unescaped relative resource syntax.
    private func validateResourcePath(_ path: String) throws {
        // Require each segment to name a resource and forbid traversal markers.
        guard !path.isEmpty else {
            throw APIClientError.invalidPath
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        for segment in segments {
            guard !segment.isEmpty, segment != ".", segment != ".." else {
                throw APIClientError.invalidPath
            }
            let safeCharacters = segment.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || "-_".unicodeScalars.contains(scalar)
            }
            if !safeCharacters {
                throw APIClientError.invalidPath
            }
        }
    }

    /// Ensures that new credentials still belong to the original request's scope.
    private func requireSameScope(_ credentials: APICredentials, as original: APICredentials) throws {
        // A successful token refresh does not permit a change of tenant or account.
        guard credentials.sessionID == original.sessionID,
              credentials.userID == original.userID,
              credentials.companyID == original.companyID else {
            throw APIClientError.sessionChanged
        }
    }

    /// Validates the identities and values used in credential headers.
    private func validate(_ credentials: APICredentials) throws {
        // Reject missing values and embedded line breaks before sending headers.
        guard !credentials.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.companyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.idToken.isEmpty,
              !credentials.companyID.contains(where: { $0.isNewline }),
              !credentials.idToken.contains(where: { $0.isNewline }) else {
            throw APIClientError.missingCredentials
        }
    }

    /// Executes the scoped request and rejects responses from a different URL.
    private func load(
        _ url: URL,
        method: String,
        body: Data?,
        contentType: String,
        isUpload: Bool,
        credentials: APICredentials
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        // Build headers only after confirming that the operation is still active.
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.idToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.companyID, forHTTPHeaderField: "X-Company-ID")
        // Large document uploads use the session configured with a longer timeout.
        let selectedSession = isUpload ? uploadSession : session
        let (data, response) = try await selectedSession.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.url == url else {
            throw APIClientError.invalidResponse
        }
        return (data, response)
    }

    /// Configures a private, non-caching transport session for the API.
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
    /// Declines redirection so credential headers never follow a different URL.
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

/// The authenticated account and tenant bound to an API request.
struct APICredentials: Equatable {
    let sessionID: UUID
    let userID: String
    let companyID: String
    let idToken: String
}
