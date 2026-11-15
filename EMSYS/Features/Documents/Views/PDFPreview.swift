import PDFKit
import SwiftUI

struct PDFPreview {
    let document: InvoiceDocument

    final class Coordinator {
        var documentID: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func update(_ view: PDFView, coordinator: Coordinator) {
        guard coordinator.documentID != document.id else { return }
        view.document = PDFDocument(data: document.pdf)
        view.autoScales = true
        coordinator.documentID = document.id
    }
}

#if os(macOS)
extension PDFPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        update(view, coordinator: context.coordinator)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        update(view, coordinator: context.coordinator)
    }
}
#else
extension PDFPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        update(view, coordinator: context.coordinator)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        update(view, coordinator: context.coordinator)
    }
}
#endif
