import Foundation

@MainActor
struct InvoiceAssignmentDownloader {
    let client: APIClient

    func routes(isAuthorized: () -> Bool) async throws -> [InvoicePickupRoute] {
        let routes = try await pages("vehicle-routes", query: [
            URLQueryItem(name: "field", value: "routeType"), URLQueryItem(name: "operator", value: "eq"),
            URLQueryItem(name: "value", value: "pickup"), URLQueryItem(name: "sort", value: "date:desc,id:desc")
        ], as: InvoicePickupRoute.self, isAuthorized: isAuthorized)
        guard routes.allSatisfy(\.isValid) else { throw APIClientError.invalidResponse }
        return routes.filter(\.isPickup)
    }

    func employees(isAuthorized: () -> Bool) async throws -> [InvoicePickupEmployee] {
        let employees = try await pages("employees", query: [
            URLQueryItem(name: "field", value: "active"), URLQueryItem(name: "operator", value: "eq"),
            URLQueryItem(name: "value", value: "true"), URLQueryItem(name: "sort", value: "id:desc")
        ], as: InvoicePickupEmployee.self, isAuthorized: isAuthorized)
        guard employees.allSatisfy(\.isValid) else { throw APIClientError.invalidResponse }
        return employees.filter(\.isEligible)
    }

    func branches(isAuthorized: () -> Bool) async throws -> [InvoicePickupBranch] {
        let branches = try await pages("branches", query: [URLQueryItem(name: "sort", value: "id:desc")],
            as: InvoicePickupBranch.self, isAuthorized: isAuthorized)
        guard branches.allSatisfy({ $0.id > 0 }) else { throw APIClientError.invalidResponse }
        return branches
    }

    private func pages<Item: Decodable & Identifiable>(_ path: String, query: [URLQueryItem], as type: Item.Type,
                                                       isAuthorized: () -> Bool) async throws -> [Item] {
        var items: [Item] = []
        var identities: Set<Item.ID> = []
        for page in 1...26 {
            guard isAuthorized() else { throw APIClientError.sessionChanged }
            try Task.checkCancellation()
            let batch = try await client.get(path, queryItems: query + [
                URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: "40")
            ], as: [Item]?.self) ?? []
            guard isAuthorized() else { throw APIClientError.sessionChanged }
            guard batch.count <= 40, items.count + batch.count <= 1_000,
                  batch.allSatisfy({ identities.insert($0.id).inserted }) else { throw APIClientError.invalidResponse }
            items += batch
            if batch.count < 40 { return items }
        }
        throw APIClientError.invalidResponse
    }
}
