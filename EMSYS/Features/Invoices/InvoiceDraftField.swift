import SwiftUI

/// Keeps the field's purpose visible while the user edits a value.
struct InvoiceDraftField: View {
    enum Input { case text, integer, decimal }

    let title: LocalizedStringKey
    @Binding var text: String
    var input: Input = .text

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(title, text: $text, axis: input == .text ? .vertical : .horizontal)
                .font(.body.weight(.medium))
                .textFieldStyle(.plain)
                .accessibilityLabel(Text(title))
                #if os(iOS)
                .keyboardType(input == .text ? .default : input == .decimal ? .decimalPad : .numberPad)
                #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}
