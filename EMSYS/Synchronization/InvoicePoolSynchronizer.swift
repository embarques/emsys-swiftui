import Foundation

@MainActor
struct InvoicePoolSynchronizer {
    let client: APIClient
    let store: InvoiceStore

    func synchronizeActions() async throws {
        while true {
            let actions = try await store.pendingInvoicePoolActions()
            guard !actions.isEmpty else { return }
            for action in actions {
                try Task.checkCancellation()
                let payload = try await store.invoicePoolActionPayload(id: action.requestId)
                let result = try await client.post("invoices/reserved/actions", encodedBody: payload, as: [InvoiceReservation].self)
                try validate(result, for: action)
                try Task.checkCancellation()
                try await store.acknowledgeInvoicePoolAction(action)
            }
        }
    }

    private func validate(_ result: [InvoiceReservation], for action: InvoicePoolAction) throws {
        guard result.count <= 100, Set(result.map(\.id)).count == result.count,
              result.allSatisfy({ InvoiceWriteDocument.isObjectID($0.id) && !$0.number.isEmpty && !$0.allocation.token.isEmpty }) else { throw APIClientError.invalidResponse }
        switch action.action {
        case .generate:
            guard result.count == action.count, result.allSatisfy({ $0.allocation.employeeId > 0 && ($0.allocation.deviceId ?? "").isEmpty }) else { throw APIClientError.invalidResponse }
        case .claim:
            guard let deviceID = UUID(uuidString: action.deviceId ?? ""), result.allSatisfy({ $0.isValid(deviceID: deviceID) }) else { throw APIClientError.invalidResponse }
        case .return:
            let proofs = action.items ?? []
            guard Set(result.map(\.id)) == Set(proofs.map(\.id)), result.allSatisfy({ row in
                row.allocation.employeeId == 0 && (row.allocation.deviceId ?? "").isEmpty
                    && row.allocation.token != proofs.first(where: { $0.id == row.id })?.token
            }) else { throw APIClientError.invalidResponse }
        }
    }

    func downloadCurrentPool() async throws {
        let deviceID = try await store.invoicePoolDeviceID()
        let revision = try await store.invoicePoolRevision()
        var cursor: String?
        var seen = Set<String>()
        var items: [InvoiceReservation] = []
        var threshold = 10
        repeat {
            try Task.checkCancellation()
            var query = [URLQueryItem(name: "deviceId", value: deviceID.uuidString.lowercased()), URLQueryItem(name: "limit", value: "100")]
            if let cursor { query.append(URLQueryItem(name: "after", value: cursor)) }
            let page = try await client.get("invoices/reserved/mine", queryItems: query, as: InvoicePoolPage.self)
            guard page.items.count <= 100, items.count + page.items.count <= 10_000 else { throw APIClientError.invalidResponse }
            items.append(contentsOf: page.items)
            threshold = page.lowThreshold
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw APIClientError.invalidResponse }
        } while cursor != nil
        try Task.checkCancellation()
        try await store.reconcileInvoiceReservations(items, lowThreshold: threshold, expectedRevision: revision)
    }
}
