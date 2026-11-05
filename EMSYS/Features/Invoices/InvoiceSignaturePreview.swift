import SwiftUI

struct InvoiceSignaturePreview: View {
    let png: Data
    let signerName: String
    var capturedAt: Date? = nil
    var canEdit = true
    var edit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("signature.previewTitle").font(.headline)
                Spacer(minLength: 12)
                if let edit {
                    Button("signature.edit", action: edit)
                        .buttonStyle(.borderless)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!canEdit)
                        .accessibilityIdentifier("signature-edit")
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                signatureImage
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .background(.white)
                    .accessibilityLabel(Text("invoiceCreation.signatureCaptured"))
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("signature.signedBy").font(.caption).foregroundStyle(.secondary)
                    Text(signerName).font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if let capturedAt {
                        Text("signature.capturedAt").font(.caption).foregroundStyle(.secondary)
                        Text(capturedAt, format: .dateTime.year().month(.abbreviated).day()
                            .hour().minute(.twoDigits).second(.twoDigits).timeZone(.specificName(.short)))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("signature-captured-at")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppStyle.Colors.surface)
            .clipShape(.rect(cornerRadius: AppStyle.Layout.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Layout.cornerRadius)
                    .stroke(.secondary.opacity(0.25), lineWidth: 1)
            }
        }
    }

    private var signatureImage: some View {
        Group {
            #if os(macOS)
            if let image = NSImage(data: png) {
                Image(nsImage: image).resizable().scaledToFit()
            }
            #else
            if let image = UIImage(data: png) {
                Image(uiImage: image).resizable().scaledToFit()
            }
            #endif
        }
    }
}
