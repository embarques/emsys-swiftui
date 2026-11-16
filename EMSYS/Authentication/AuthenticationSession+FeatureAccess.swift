import Foundation

/// Centralizes the permission checks and scoped feature entry points.
extension AuthenticationSession {
    /// Checks invoice directory access in the authenticated company.
    var canViewInvoices: Bool {
        phase == .signedIn && permissions?.contains("canViewInvoice", resourceType: "invoice") == true
    }

    /// Checks access to the pickup workflow.
    var canViewPickups: Bool {
        phase == .signedIn && AppDestination.pickups.isAccessible(with: permissions)
    }

    /// Allows pickup updates under the general or assigned-pickup grant.
    var canUpdatePickups: Bool {
        canViewPickups && ["canUpdatePickup", "canUpdateAssignedAppointments"].contains {
            permissions?.contains($0, resourceType: "pickup") == true
        }
    }

    /// Checks access to the statements and journals used by Ingresos.
    var canViewIncome: Bool {
        phase == .signedIn && AppDestination.dailyIncome.isAccessible(with: permissions)
    }

    /// Checks the server grant for opening today's closeout in the signed-in branch.
    var canOpenIncomeCloseout: Bool {
        phase == .signedIn && (user?.branch?.id ?? 0) > 0
            && permissions?.contains("canCreateIncomeStatement", resourceType: "income_statement") == true
    }

    /// Checks whether the user can post an income or expense entry.
    var canPostIncomeJournal: Bool {
        canViewIncome && permissions?.contains("canCreateJournal", resourceType: "journal") == true
    }

    /// Requires account lookup in addition to journal posting.
    var canPrepareIncomeJournal: Bool {
        canPostIncomeJournal && permissions?.contains("canViewChartAccount", resourceType: "chart_account") == true
    }

    /// Allows full invoice creation when the directory is available.
    var canCreateInvoices: Bool {
        canViewInvoices && permissions?.contains("canCreateInvoice", resourceType: "invoice") == true
    }

    /// Allows invoice creation only from authorized assigned pickups.
    var canCreateAssignedPickupInvoices: Bool {
        phase == .signedIn && canViewPickups && permissions?.contains("canCreateAssignedInvoice", resourceType: "invoice") == true
    }

    /// Checks either supported permission for pickup invoice creation.
    var canCreatePickupInvoices: Bool { canCreateInvoices || canCreateAssignedPickupInvoices }

    /// Checks the print grant for invoices the user may view.
    var canPrintInvoices: Bool {
        canViewInvoices && permissions?.contains("canPrintInvoice", resourceType: "invoice") == true
    }

    /// Checks customer directory access.
    var canViewCustomers: Bool {
        phase == .signedIn && permissions?.contains("canViewCustomer", resourceType: "customer") == true
    }

    /// Checks access to the container catalog.
    var canViewContainers: Bool {
        phase == .signedIn && permissions?.contains("canViewContainer", resourceType: "container") == true
    }

    /// Allows policy review through invoice creation or explicit policy access.
    var canReviewInvoicePolicies: Bool {
        phase == .signedIn && (permissions?.contains("canCreateInvoice", resourceType: "invoice") == true
            || permissions?.contains("canViewInvoicePolicy", resourceType: "invoice_policy") == true)
    }

    /// Checks the update grant for invoices the user may view.
    var canUpdateInvoices: Bool {
        canViewInvoices && permissions?.contains("canUpdateInvoice", resourceType: "invoice") == true
    }

    /// Opens the pickup store and client for this authenticated company.
    func pickupAccess() async throws -> (client: APIClient, store: PickupStore) {
        try await openFeatureStorage("EMSYS/Pickups", permits: { $0.canViewPickups }) { directory, userID, companyID, environment in
            try await PickupStore.open(directory: directory, userID: userID,
                companyID: companyID, apiEnvironment: environment)
        }
    }

    /// Opens Ingresos storage and its API client for the active session.
    func incomeAccess() async throws -> (client: APIClient, store: IncomeStore) {
        try await openFeatureStorage("EMSYS/Income", permits: { $0.canViewIncome }) { directory, userID, companyID, environment in
            try await IncomeStore.open(directory: directory, userID: userID,
                companyID: companyID, apiEnvironment: environment)
        }
    }

    /// Opens invoices under full authority or an explicitly requested assigned-pickup grant.
    func invoiceAccess(allowAssignedCreation: Bool = false) async throws -> (client: APIClient, store: InvoiceStore) {
        try await openFeatureStorage("EMSYS/Invoices", permits: { session in
            // Assigned creation may open the store for this workflow without directory access.
            session.canViewInvoices || (allowAssignedCreation && session.canCreateAssignedPickupInvoices)
        }) { directory, userID, companyID, environment in
            try await InvoiceStore.open(directory: directory, userID: userID,
                companyID: companyID, apiEnvironment: environment)
        }
    }
}
