import SwiftUI

struct PickupInvoiceLinksView: View {
    let model: PickupInvoicesModel
    var edit: (InvoiceItemEditorModel) -> Void

    var body: some View {
        ForEach(model.links) { link in
            HStack(spacing: 12) {
                Label {
                    if let number = link.number { Text(verbatim: number) }
                    else { Text("pickups.invoiceAwaitingNumber") }
                } icon: { Image(systemName: "doc.text") }
                .font(.headline)
                Spacer()
                if link.invoiceID != nil, model.mayEdit {
                    Button {
                        if let editor = model.editor(for: link) { edit(editor) }
                    } label: { Label("invoiceEdits.editorTitle", systemImage: "pencil") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            if let state = link.state, state != .completed {
                Label(LocalizedStringKey(state.title), systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let issue = model.issue {
            Text(LocalizedStringKey(issue)).foregroundStyle(.secondary)
            Button("auth.retry") { Task { await model.load() } }
        }
    }
}
