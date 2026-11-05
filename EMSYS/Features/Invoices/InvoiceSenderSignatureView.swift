import SwiftUI

struct InvoiceSenderSignatureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let model: InvoiceDraftEditorModel
    @State private var drawing = SignatureDrawing()
    @State private var failed = false

    init(model: InvoiceDraftEditorModel, drawing: SignatureDrawing = SignatureDrawing()) {
        self.model = model
        _drawing = State(initialValue: drawing)
    }

    var body: some View {
        VStack(spacing: 0) {
            captureHeader
            Divider()
            GeometryReader { geometry in
                let compact = geometry.size.height < 360
                let padding: CGFloat = compact ? 12 : 24
                VStack(spacing: compact ? 8 : 20) {
                    Spacer(minLength: 0)
                    Text(model.content.senderName)
                        .font(compact ? .headline : .title2.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if !compact {
                        Text("signature.instructions").font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    SignatureCaptureView(drawing: $drawing)
                        .accessibilityIdentifier("signature-canvas")
                        .frame(height: Self.canvasHeight(in: geometry.size, compact: compact, padding: padding, accessibility: dynamicTypeSize.isAccessibilitySize))
                        .disabled(model.isPreparingSignature)
                    if failed { Text("invoiceCreation.signatureError").foregroundStyle(.red) }
                    if model.isPreparingSignature { ProgressView() }
                    Spacer(minLength: 0)
                }
                .padding(padding)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppStyle.Colors.surface)
            }
        }
        .interactiveDismissDisabled(model.isPreparingSignature)
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCompactAdaptation(.fullScreenCover)
        #elseif os(macOS)
        .frame(minWidth: 520, minHeight: 500)
        #endif
    }

    // An explicit header keeps these controls above the paper on every device,
    // including systems that relocate automatic toolbars to a floating side rail.
    private var captureHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                captureTitle
            }
            HStack(spacing: 12) {
                Button { dismiss() } label: { Label("invoiceEdits.cancel", systemImage: "xmark") }
                    .tint(.red)
                    .disabled(model.isPreparingSignature)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("signature-cancel")
                if dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                } else {
                    captureTitle.frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { drawing = SignatureDrawing(); failed = false } label: {
                    Label("signature.clear", systemImage: "trash")
                }
                .tint(.orange)
                .disabled(drawing.isEmpty || model.isPreparingSignature)
                .accessibilityIdentifier("signature-clear")
                Button {
                    Task {
                        if await model.captureSignature(drawing) { dismiss() } else { failed = true }
                    }
                } label: { Label("invoiceCreation.useSignature", systemImage: "checkmark") }
                    .tint(.green)
                    .disabled(drawing.isEmpty || model.isPreparingSignature || !model.isAvailable)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("signature-confirm")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(12)
        .background(.background)
    }

    private var captureTitle: some View {
        Text("signature.createTitle")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    static func canvasHeight(in size: CGSize, compact: Bool, padding: CGFloat, accessibility: Bool) -> CGFloat {
        let width = min(1000, size.width) - padding * 2
        let preferred = min(360, max(140, width * 0.625))
        let textSpace: CGFloat = compact ? 90 : (accessibility ? 300 : 200)
        return min(preferred, max(100, size.height - textSpace))
    }
}
