import Foundation

extension AuthenticationSession {
    var pickupInvoiceAccess: PickupInvoiceAccess? {
        guard canViewPickups else { return nil }
        return PickupInvoiceAccess(canCreateInvoices: canCreateInvoices,
            canCreateAssignedInvoices: canCreateAssignedPickupInvoices)
    }

    private func canUsePickupInvoiceAccess(_ required: PickupInvoiceAccess, context: UUID) -> Bool {
        contextID == context && pickupInvoiceAccess?.permits(required) == true
    }

    /// Assigned creation retains narrow authority; ordinary invoice views stay protected.
    func pickupInvoiceEditor(_ pickup: Pickup, receiverID: String?) async throws -> InvoiceDraftEditorModel {
        guard let requiredAccess = pickupInvoiceAccess else { throw AuthenticationIssue.authorization }
        let context = contextID
        let access = try await invoiceAccess(allowAssignedCreation: true)
        guard canUsePickupInvoiceAccess(requiredAccess, context: context) else { throw APIClientError.sessionChanged }
        let pickupAccess = try await pickupAccess()
        var initial: InvoiceDraft.Content
        do {
            let query = receiverID.map { [URLQueryItem(name: "receiverId", value: $0)] } ?? []
            let prepared = try await pickupAccess.client.get("pickups/\(pickup.id)/invoice-context",
                queryItems: query, as: PickupInvoiceContext.self)
            guard canUsePickupInvoiceAccess(requiredAccess, context: context) else { throw APIClientError.sessionChanged }
            try await pickupAccess.store.saveInvoiceContext(prepared, pickup: pickup, receiverID: receiverID)
            initial = try prepared.content(from: pickup, receiverID: receiverID)
        } catch {
            guard canUsePickupInvoiceAccess(requiredAccess, context: context) else { throw APIClientError.sessionChanged }
            if AuthenticationSession.permitsOfflineRestoration(error),
               let cached = try await pickupAccess.store.invoiceContext(pickup: pickup, receiverID: receiverID) {
                initial = try cached.content(from: pickup, receiverID: receiverID)
            } else if case APIClientError.httpStatus(let status) = error, (status == 404 || status == 405), canCreateInvoices {
                // Older APIs retain the existing full-authority workflow.
                initial = try PickupInvoicePrefill.content(from: pickup, receiverID: receiverID)
            } else { throw error }
        }
        guard canUsePickupInvoiceAccess(requiredAccess, context: context) else { throw APIClientError.sessionChanged }
        let assignedOnly = requiredAccess.assignedOnly
        if assignedOnly {
            guard let sender = initial.senderCustomer else { throw APIClientError.invalidResponse }
            initial.assignedPickup = InvoiceAssignedPickup(pickupID: pickup.id, senderID: sender.id, receiverID: initial.receiverCustomer?.id)
            initial.paymentRegion = user?.branch?.code
        }
        return InvoiceDraftEditorModel(assignedOnlyAccess: assignedOnly, initialContent: initial, store: access.store, client: access.client,
            canViewItemCatalog: { self.contextID == context && (self.permissions?.contains("canViewSettings", resourceType: "settings") == true || self.canCreateAssignedPickupInvoices) },
            canViewCustomers: { self.contextID == context && self.canViewCustomers },
            canReviewPolicies: { self.contextID == context && (self.canReviewInvoicePolicies || self.canCreateAssignedPickupInvoices) },
            canViewContainers: { self.contextID == context && self.canViewContainers },
            canViewAssignments: { permission in
                self.contextID == context && self.permissions?.contains(permission.name, resourceType: permission.resourceType) == true
            },
            canReviewPayments: { self.contextID == context && self.permissions?.contains("canViewIncomeStatement", resourceType: "income_statement") == true },
            currentBranchID: { self.contextID == context ? self.user?.branch?.id : nil },
            financialPermission: { self.canUsePickupInvoiceAccess(requiredAccess, context: context) && ($0 == .createInvoice || $0.isGranted(by: self.permissions)) },
            isAuthorized: { self.canUsePickupInvoiceAccess(requiredAccess, context: context) })
    }
    func pickupInvoiceDrafts() async throws -> InvoiceDraftListModel {
        guard let requiredAccess = pickupInvoiceAccess else { throw AuthenticationIssue.authorization }
        let context = contextID
        let assignedOnly = requiredAccess.assignedOnly
        let access = try await invoiceAccess(allowAssignedCreation: true)
        guard canUsePickupInvoiceAccess(requiredAccess, context: context) else { throw APIClientError.sessionChanged }
        return InvoiceDraftListModel(assignedOnly: assignedOnly, store: access.store, client: access.client,
            canViewItemCatalog: { self.contextID == context && (self.canCreateAssignedPickupInvoices || self.permissions?.contains("canViewSettings", resourceType: "settings") == true) },
            canViewCustomers: { self.contextID == context && !assignedOnly && self.canViewCustomers },
            canReviewPolicies: { self.contextID == context && (self.canCreateAssignedPickupInvoices || self.canReviewInvoicePolicies) },
            currentBranchID: { self.contextID == context ? self.user?.branch?.id : nil },
            financialPermission: { self.canUsePickupInvoiceAccess(requiredAccess, context: context) && ($0 == .createInvoice || $0.isGranted(by: self.permissions)) },
            isAuthorized: { self.canUsePickupInvoiceAccess(requiredAccess, context: context) })
    }

}
