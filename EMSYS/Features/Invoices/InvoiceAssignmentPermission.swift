import Foundation

nonisolated enum InvoiceAssignmentPermission: Sendable {
    case routes, employees, branches
    var name: String {
        switch self {
        case .routes: "canViewRoute"
        case .employees: "canViewEmployee"
        case .branches: "canViewBranch"
        }
    }
    var resourceType: String {
        switch self {
        case .routes: "route"
        case .employees: "employee"
        case .branches: "branch"
        }
    }
}
