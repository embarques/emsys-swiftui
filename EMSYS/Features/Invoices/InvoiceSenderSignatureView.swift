import SwiftUI

struct InvoiceSenderSignatureView: View {
    @Environment(\.dismiss) private var dismiss
    let model: InvoiceDraftEditorModel
    @State private var drawing = SignatureDrawing()
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(model.content.senderName).font(.title2.bold())
                    SignatureCaptureView(drawing: $drawing)
                    if failed { Text("invoiceCreation.signatureError").foregroundStyle(.red) }
                    if model.isPreparingSignature { ProgressView() }
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("invoiceCreation.senderSignature")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("invoiceEdits.cancel") { dismiss() }
                        .disabled(model.isPreparingSignature)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("invoiceCreation.useSignature") {
                        Task {
                            if await model.captureSignature(drawing) { dismiss() } else { failed = true }
                        }
                    }
                    .disabled(drawing.isEmpty || model.isPreparingSignature || !model.isAvailable)
                }
            }
        }
        .interactiveDismissDisabled(model.isPreparingSignature)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 500)
        #endif
    }
}
