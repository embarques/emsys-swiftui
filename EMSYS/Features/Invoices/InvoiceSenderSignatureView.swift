import SwiftUI

struct InvoiceSenderSignatureView: View {
    @Environment(\.dismiss) private var dismiss
    let model: InvoiceDraftEditorModel
    @State private var drawing = SignatureDrawing()
    @State private var failed = false

    init(model: InvoiceDraftEditorModel, drawing: SignatureDrawing = SignatureDrawing()) {
        self.model = model
        _drawing = State(initialValue: drawing)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("signature.createTitle")
                .font(.title2.bold())
                .frame(maxWidth: 800, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("signature.signingAs").font(.subheadline).foregroundStyle(.secondary)
                        Text(model.content.senderName).font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer(minLength: 0)
                        Button("signature.clear") { drawing = SignatureDrawing(); failed = false }
                            .buttonStyle(.borderless)
                            .frame(minWidth: 44, minHeight: 44)
                            .disabled(drawing.isEmpty || model.isPreparingSignature)
                            .accessibilityIdentifier("signature-clear")
                    }
                    VStack(spacing: 10) {
                        SignatureCaptureView(drawing: $drawing)
                            .aspectRatio(SignatureDrawing.aspectRatio, contentMode: .fit)
                            .disabled(model.isPreparingSignature)
                        Text("signature.signAbove").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("signature.applyNotice")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                    if failed {
                        Text("invoiceCreation.signatureError").foregroundStyle(.red)
                            .accessibilityIdentifier("signature-error")
                    }
                }
                .frame(maxWidth: 800)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            captureActions
        }
        .background(.background)
        .interactiveDismissDisabled(model.isPreparingSignature)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }

    private var captureActions: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    if await model.captureSignature(drawing) { dismiss() } else { failed = true }
                }
            } label: {
                HStack {
                    if model.isPreparingSignature { ProgressView().controlSize(.small) }
                    Text("signature.apply")
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .disabled(drawing.isEmpty || model.isPreparingSignature || !model.isAvailable)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("signature-confirm")

            Button { dismiss() } label: {
                Text("invoiceEdits.cancel").frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .disabled(model.isPreparingSignature)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("signature-cancel")
        }
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: AppStyle.Layout.cornerRadius))
        .font(.headline)
        .frame(maxWidth: 800)
        .padding(16)
        .frame(maxWidth: .infinity)
    }
}
