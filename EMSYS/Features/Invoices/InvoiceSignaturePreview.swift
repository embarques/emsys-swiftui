import SwiftUI

struct InvoiceSignaturePreview: View {
    let png: Data

    var body: some View {
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
        .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 160)
        .background(.white, in: .rect(cornerRadius: 12))
        .accessibilityLabel(Text("invoiceCreation.signatureCaptured"))
    }
}
