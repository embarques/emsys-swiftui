import Foundation

nonisolated enum InvoiceFinancialPermission: Sendable {
    case uploadDocument, createInvoice, recordPayment, applyDiscount, viewBankAccounts

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
