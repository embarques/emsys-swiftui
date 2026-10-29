import SwiftUI

struct InvoiceCreationPresentation: ViewModifier {
    @Binding var editor: InvoiceDraftEditorModel?
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
