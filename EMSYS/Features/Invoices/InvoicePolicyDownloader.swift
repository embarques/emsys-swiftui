import Foundation

@MainActor
struct InvoicePolicyDownloader {
    let client: APIClient

    func download(isAuthorized: () -> Bool) async throws -> [InvoicePolicy] {
        var policies: [InvoicePolicy] = []
        // The active endpoint uses normal pagination. Never treat a partial
        // policy list, repeated page, or failed later page as a complete review.
        for page in 1...26 {
            guard isAuthorized() else { throw APIClientError.sessionChanged }
            try Task.checkCancellation()
            let downloaded = try await client.get("invoice-policies/active", queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: "40")
            ], as: [InvoicePolicy]?.self) ?? []
            guard isAuthorized() else { throw APIClientError.sessionChanged }
            guard downloaded.count <= 40 else { throw APIClientError.invalidResponse }
            policies.append(contentsOf: downloaded)
            guard InvoicePolicy.validate(policies) else { throw APIClientError.invalidResponse }
            if downloaded.count < 40 { return policies }
        }
        throw APIClientError.invalidResponse
    }
}
