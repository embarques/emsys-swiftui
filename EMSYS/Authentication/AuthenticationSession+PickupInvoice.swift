import Foundation

extension AuthenticationSession {
    /// Uses the existing invoice authority. Assigned-only creation requires a
    /// separate server contract; a pickup-view grant never grants invoice writes.
    func pickupInvoiceEditor(_ pickup: Pickup, receiverID: String?) async throws -> InvoiceDraftEditorModel {
        guard canCreateInvoices, canViewPickups else { throw AuthenticationIssue.authorization }
        let context = contextID
        let access = try await invoiceAccess()
        guard contextID == context, canCreateInvoices, canViewPickups else { throw APIClientError.sessionChanged }
        let pickupAccess = try await pickupAccess()
        let initial: InvoiceDraft.Content
        do {
            let query = receiverID.map { [URLQueryItem(name: "receiverId", value: $0)] } ?? []
            let prepared = try await pickupAccess.client.get("pickups/\(pickup.id)/invoice-context",
                queryItems: query, as: PickupInvoiceContext.self)
            guard contextID == context, canCreateInvoices, canViewPickups else { throw APIClientError.sessionChanged }
            try await pickupAccess.store.saveInvoiceContext(prepared, pickup: pickup, receiverID: receiverID)
            initial = try prepared.content(from: pickup, receiverID: receiverID)
        } catch {
            guard contextID == context, canCreateInvoices, canViewPickups else { throw APIClientError.sessionChanged }
            if AuthenticationSession.permitsOfflineRestoration(error),
               let cached = try await pickupAccess.store.invoiceContext(pickup: pickup, receiverID: receiverID) {
                initial = try cached.content(from: pickup, receiverID: receiverID)
            } else if case APIClientError.httpStatus(let status) = error, status == 404 || status == 405 {
                // Older APIs retain the existing full-authority workflow.
                initial = try PickupInvoicePrefill.content(from: pickup, receiverID: receiverID)
            } else { throw error }
        }
        return InvoiceDraftEditorModel(initialContent: initial, store: access.store, client: access.client,
            canViewItemCatalog: { self.contextID == context && self.permissions?.contains("canViewSettings", resourceType: "settings") == true },
            canViewCustomers: { self.contextID == context && self.canViewCustomers },
            canReviewPolicies: { self.contextID == context && self.canReviewInvoicePolicies },
            canViewContainers: { self.contextID == context && self.canViewContainers },
            canViewAssignments: { permission in
                self.contextID == context && self.permissions?.contains(permission.name, resourceType: permission.resourceType) == true
            },
            canReviewPayments: { self.contextID == context && self.permissions?.contains("canViewIncomeStatement", resourceType: "income_statement") == true },
            currentBranchID: { self.contextID == context ? self.user?.branch?.id : nil },
            financialPermission: { self.contextID == context && $0.isGranted(by: self.permissions) },
            isAuthorized: { self.contextID == context && self.canCreateInvoices && self.canViewPickups })
    }
}
