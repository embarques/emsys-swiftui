import Foundation

extension AuthenticationSession {
    /// Uses the existing invoice authority. Assigned-only creation requires a
    /// separate server contract; a pickup-view grant never grants invoice writes.
    func pickupInvoiceEditor(_ pickup: Pickup, receiverID: String?) async throws -> InvoiceDraftEditorModel {
        guard canCreateInvoices, canViewPickups else { throw AuthenticationIssue.authorization }
        let context = contextID
        let access = try await invoiceAccess()
        guard contextID == context, canCreateInvoices, canViewPickups else { throw APIClientError.sessionChanged }
        let initial = try PickupInvoicePrefill.content(from: pickup, receiverID: receiverID)
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
