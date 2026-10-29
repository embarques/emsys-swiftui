import Foundation

/// Download only the read resources needed by the assigned invoice wizard.
@MainActor
struct AssignedInvoicePreparation {
    let client: APIClient
    let store: InvoiceStore
    let isAuthorized: () -> Bool

    func download() async throws {
        var catalog: [InvoiceCatalogItem] = []
        var identities = Set<UInt16>()
        for page in 1...26 {
            guard isAuthorized() else { throw APIClientError.sessionChanged }
            let batch = try await client.get("invoice-descriptions", queryItems: [
                URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: "40"),
                URLQueryItem(name: "sort", value: "createdAt:desc,id:desc")
            ], as: [InvoiceCatalogItem]?.self) ?? []
            guard isAuthorized() else { throw APIClientError.sessionChanged }
            guard batch.count <= 40, catalog.count + batch.count <= 1_000,
                  batch.allSatisfy({ $0.isValid && identities.insert($0.id).inserted }) else { throw APIClientError.invalidResponse }
            catalog += batch
            if batch.count < 40 {
                try await store.saveItemCatalog(catalog)
                let policies = try await InvoicePolicyDownloader(client: client).download(isAuthorized: isAuthorized)
                guard isAuthorized() else { throw APIClientError.sessionChanged }
                try await store.savePolicies(policies)
                return
            }
        }
        throw APIClientError.invalidResponse
    }
}
