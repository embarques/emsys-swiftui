import SwiftUI

/// Keeps the field's purpose visible while the user edits a value.
struct InvoiceDraftField: View {
    enum Input { case text, integer, decimal }

    let title: LocalizedStringKey
    @Binding var text: String
    var input: Input = .text
    var selection: Binding<TextSelection?>?

    @ViewBuilder
    private var editor: some View {
        let axis: Axis = input == .text ? .vertical : .horizontal
        if let selection {
            TextField(title, text: $text, selection: selection, axis: axis)
        } else {
            TextField(title, text: $text, axis: axis)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            editor
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
