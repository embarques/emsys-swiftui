import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Keeps the field's purpose visible while the user edits a value.
struct InvoiceDraftField: View {
    enum Input { case text, integer, decimal }

    let title: LocalizedStringKey
    @Binding var text: String
    var input: Input = .text
    var selection: Binding<TextSelection?>?
    var usesProminentNumber = false

    /// Builds the native editor, applying text selection when requested.
    @ViewBuilder
    private var editor: some View {
        let axis: Axis = input == .text ? .vertical : .horizontal
        if let selection {
            TextField(title, text: $text, selection: selection, axis: axis)
        } else {
            TextField(title, text: $text, axis: axis)
        }
    }

    #if os(iOS)
    /// Matches the system keyboard to the kind of value the field accepts.
    private var keyboardType: UIKeyboardType {
        switch input {
        case .text:
            return .default
        case .decimal:
            return .decimalPad
        case .integer:
            return .numberPad
        }
    }
    #endif

    /// Shows the field label and editor with the correct input controls.
    var body: some View {
        // Keep the numeric label near its value while preserving the standard text field spacing.
        let spacing = usesProminentNumber ? 2 : AppStyle.Spacing.small
        let editorFont: Font = usesProminentNumber
            ? .title3.weight(.semibold).monospacedDigit()
            : .body.weight(.medium)
        VStack(alignment: .leading, spacing: spacing) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            editor
                .font(editorFont)
                .frame(minHeight: usesProminentNumber ? 36 : nil)
                .textFieldStyle(.plain)
                .accessibilityLabel(Text(title))
                #if os(iOS)
                .keyboardType(keyboardType)
                #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}
