import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable {
    case home, pickups, invoices, deliveries, dailyIncome, more, settings

    static let primaryTabs: [Self] = [.pickups, .invoices, .deliveries, .dailyIncome, .more]
    var id: String { rawValue }

    var title: LocalizedStringKey { LocalizedStringKey("navigation." + rawValue) }
    var subtitle: LocalizedStringKey { LocalizedStringKey("navigation." + rawValue + "Hint") }

    var systemImageName: String {
        switch self {
        case .home: "house"
        case .pickups: "shippingbox"
        case .invoices: "doc.text"
        case .deliveries: "truck.box"
        case .dailyIncome: "chart.bar.xaxis"
        case .more: "ellipsis"
        case .settings: "gearshape"
        }
    }

    func isAccessible(with permissions: UserPermissions?) -> Bool {
        switch self {
        case .home, .more, .settings: true
        case .pickups:
            ["canViewPickup", "canViewAssignedAppointments"].contains {
                permissions?.contains($0, resourceType: "pickup") == true
            }
        case .invoices: permissions?.contains("canViewInvoice", resourceType: "invoice") == true
        case .deliveries:
            ["canViewDelivery", "canViewAssignedDeliveries"].contains {
                permissions?.contains($0, resourceType: "delivery") == true
            }
        case .dailyIncome: permissions?.contains("canViewIncomeStatement", resourceType: "income_statement") == true
        }
    }
}
