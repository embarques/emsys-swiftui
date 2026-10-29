import SwiftUI

/// Shared colors, fonts, spacing, and layout dimensions for application views.
enum AppStyle {
    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let extraLarge: CGFloat = 32
    }
    enum Layout {
        static let readableContentWidth: CGFloat = 640
        static let minimumSidebarWidth: CGFloat = 200
        static let idealSidebarWidth: CGFloat = 240
        static let cornerRadius: CGFloat = 12
    }
    enum Colors {
        static let text = Color.primary
        static let secondaryText = Color.secondary
        static let accent = Color.accentColor
        static let surface = Color.secondary.opacity(0.08)
    }
    enum Fonts {
        static let title = Font.largeTitle.bold()
        static let body = Font.body
        static let supporting = Font.callout
    }
}
