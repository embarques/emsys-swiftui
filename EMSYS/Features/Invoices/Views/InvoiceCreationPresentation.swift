import SwiftUI

struct InvoiceCreationPresentation: ViewModifier {
    @Binding var editor: InvoiceDraftEditorViewModel?
    var onDismiss: () -> Void = { }

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(item: $editor, onDismiss: onDismiss) {
            InvoiceDraftEditorView(model: $0)
        }
        #else
        content.sheet(item: $editor, onDismiss: onDismiss) {
            InvoiceDraftEditorView(model: $0)
                .frame(minWidth: 600, minHeight: 700)
        }
        #endif
    }
}

extension InvoiceCreationStep {
    /// Returns the localized wizard heading key.
    var title: String { "invoiceCreation.step.\(self)" }
    /// Returns the symbol used for this step in the wizard.
    var symbol: String {
        switch self {
        case .details: "doc.text"
        case .customers: "person.2"
        case .items: "shippingbox"
        case .payment: "banknote"
        case .review: "checkmark.seal"
        }
    }
}
