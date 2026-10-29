import SwiftUI

struct InvoiceItemCatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NetworkConnection.self) private var connection
    let model: InvoiceDraftEditorModel
    let onSelect: (InvoiceCatalogItem) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if model.canChooseCatalogItems {
                    if model.isLoadingCatalog { ProgressView() }
                    if let issue = model.catalogIssue {
                        Text(LocalizedStringKey(issue)).foregroundStyle(.secondary)
                    }
                    if model.catalogIsDownloaded {
                        Text("itemCatalog.offlineHint").font(.caption).foregroundStyle(.secondary)
                    }
                    let matches = InvoiceCatalogItem.matching(model.catalogItems, query: query)
                    if matches.isEmpty && !model.isLoadingCatalog { Text("itemCatalog.empty").foregroundStyle(.secondary) }
                    ForEach(matches) { item in
                        Button { onSelect(item) } label: {
                            HStack(alignment: .top, spacing: 16) {
                                Text(item.name).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.price, format: .number.precision(.fractionLength(2)))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else { Text("auth.unavailable") }
            }
            .navigationTitle("itemCatalog.title")
            .searchable(text: $query, prompt: "itemCatalog.search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("invoiceEdits.cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.loadItemCatalog(online: connection.status != .unavailable) } } label: {
                        Label("itemCatalog.refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoadingCatalog || !model.canChooseCatalogItems)
                }
            }
            .task { await model.loadItemCatalog(online: connection.status != .unavailable) }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }
}
