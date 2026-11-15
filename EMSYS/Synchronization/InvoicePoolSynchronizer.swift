import Foundation

@MainActor
struct InvoicePoolSynchronizer {
    let client: APIClient
    let store: InvoiceStore

    /// Sends and acknowledges queued reservation actions in their saved order.
    func synchronizeActions() async throws {
        while true {
            let actions = try await store.pendingInvoicePoolActions()
            guard !actions.isEmpty else {
                return
            }

            // Retries send the saved action bytes until a matching response arrives.
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

    /// Checks the identities and ownership changes acknowledged by the server.
    private func validate(_ result: [InvoiceReservation], for action: InvoicePoolAction) throws {
        // Every result must have one valid identity and nonempty authorization proof.
        guard result.count <= 100 else {
            throw APIClientError.invalidResponse
        }
        let resultIDs = Set(result.map(\.id))
        guard resultIDs.count == result.count else {
            throw APIClientError.invalidResponse
        }
        for reservation in result {
            guard InvoiceWriteDocument.isObjectID(reservation.id), !reservation.number.isEmpty,
                  !reservation.allocation.token.isEmpty else {
                throw APIClientError.invalidResponse
            }
        }

        // Each action has a different expected owner and device state.
        switch action.action {
        case .generate:
            guard result.count == action.count,
                  result.allSatisfy({ $0.allocation.hasOwner && ($0.allocation.deviceId ?? "").isEmpty }) else {
                throw APIClientError.invalidResponse
            }
        case .claim:
            guard let deviceID = UUID(uuidString: action.deviceId ?? ""),
                  result.allSatisfy({ $0.isValid(deviceID: deviceID) }) else {
                throw APIClientError.invalidResponse
            }
        case .return:
            // Match returned identities to their original proof in a single lookup per row.
            var originalTokens: [String: String] = [:]
            for proof in action.items ?? [] {
                if originalTokens[proof.id] == nil {
                    originalTokens[proof.id] = proof.token
                }
            }
            guard resultIDs == Set(originalTokens.keys) else {
                throw APIClientError.invalidResponse
            }
            for reservation in result {
                let allocation = reservation.allocation
                guard allocation.isUnassigned, (allocation.deviceId ?? "").isEmpty,
                      allocation.token != originalTokens[reservation.id] else {
                    throw APIClientError.invalidResponse
                }
            }
        }
    }

    /// Reconciles all reservation pages against the revision captured before downloading.
    func downloadCurrentPool() async throws {
        let deviceID = try await store.invoicePoolDeviceID()
        let revision = try await store.invoicePoolRevision()
        var cursor: String?
        var seenCursors = Set<String>()
        var items: [InvoiceReservation] = []
        var threshold = 10
        repeat {
            try Task.checkCancellation()
            var query = [URLQueryItem(name: "deviceId", value: deviceID.uuidString.lowercased()), URLQueryItem(name: "limit", value: "100")]
            // Continue from the last page without repeating a cursor.
            if let cursor {
                query.append(URLQueryItem(name: "after", value: cursor))
            }
            let page = try await client.get("invoices/reserved/mine", queryItems: query, as: InvoicePoolPage.self)
            guard page.items.count <= 100, items.count + page.items.count <= 10_000 else {
                throw APIClientError.invalidResponse
            }
            items.append(contentsOf: page.items)
            threshold = page.lowThreshold
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw APIClientError.invalidResponse
            }
        } while cursor != nil
        try Task.checkCancellation()
        try await store.reconcileInvoiceReservations(items, lowThreshold: threshold, expectedRevision: revision)
    }
}
