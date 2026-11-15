import SwiftUI

struct MessagePanel: View {
    let message: LocalizedStringKey
    var icon = "bell"
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(AppStyle.Colors.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("messages.title").font(.headline).accessibilityAddTraits(.isHeader)
                Text(message).font(.callout).foregroundStyle(.secondary)
                if let actionTitle, let action {
                    Button(actionTitle, action: action).buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(AppStyle.Colors.accent.opacity(0.07), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(AppStyle.Colors.accent.opacity(0.22))
        }
    }
}
