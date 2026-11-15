import Foundation

nonisolated enum InvoiceAssignmentPermission: Sendable {
    case routes, employees, branches
    /// Returns the backend grant required to open this assignment catalog.
    var name: String {
        switch self {
        case .routes: "canViewRoute"
        case .employees: "canViewEmployee"
        case .branches: "canViewBranch"
        }
    }
    /// Returns the resource type associated with the grant.
    var resourceType: String {
        switch self {
        case .routes: "route"
        case .employees: "employee"
        case .branches: "branch"
        }
    }
}

nonisolated enum InvoiceFinancialPermission: Sendable {
    case uploadDocument, createInvoice, recordPayment, applyDiscount, viewBankAccounts

    /// Checks the server grants required by the invoice workflow.
    func isGranted(by permissions: UserPermissions?) -> Bool {
        switch self {
        case .uploadDocument:
            permissions?.contains("canUpdateInvoice", resourceType: "invoice") == true
        case .createInvoice:
            permissions?.contains("canCreateInvoice", resourceType: "invoice") == true
        case .recordPayment:
            permissions?.contains("canCreateJournal", resourceType: "journal") == true
        case .applyDiscount:
            permissions?.contains("canApplyInvoiceDiscount", resourceType: "invoice_discount") == true
        case .viewBankAccounts:
            permissions?.contains("canViewChartAccount", resourceType: "chart_account") == true
                || permissions?.contains("canViewAccount", resourceType: "account") == true
        }
    }
}
