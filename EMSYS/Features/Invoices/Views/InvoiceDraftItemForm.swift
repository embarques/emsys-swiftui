import SwiftUI

/// Edits a local copy so dismissing the form discards pending changes.
struct InvoiceDraftItemForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: InvoiceDraft.Item
    @State private var showsCatalog = false
    @State private var priceFocusRequest: UUID?
    @State private var catalogPriceSelected = false
    @State private var saveFailed = false

    private let model: InvoiceDraftEditorViewModel
    private let original: InvoiceDraft.Item?
    private let usesMobileLayout: Bool

    /// Captures the selected line and identifies whether it already belongs to the draft.
    init(model: InvoiceDraftEditorViewModel, item: InvoiceDraft.Item, usesMobileLayout: Bool) {
        self.model = model
        // Keep the original to detect stale edits and to control the removal action.
        original = model.listedItems.first { $0.id == item.id }
        self.usesMobileLayout = usesMobileLayout
        _item = State(initialValue: item)
    }

    /// Presents the existing item fields, catalog picker, and commit controls.
    var body: some View {
        NavigationStack {
            Form {
                // Retain the entered values so a failed commit can be corrected.
                if saveFailed {
                    Text("invoiceCreation.itemsRequired").foregroundStyle(.red)
                }
                InvoiceDraftItemFields(
                    item: $item,
                    priceFocusRequest: $priceFocusRequest,
                    canChooseCatalogItems: model.canChooseCatalogItems,
                    choose: { showsCatalog = true },
                    remove: removeItem,
                    usesMobileLayout: usesMobileLayout,
                    canRemove: original != nil
                )
            }
            .formStyle(.grouped)
            .navigationTitle("invoiceWizard.item")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("invoiceEdits.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("drafts.finishItem", action: saveItem)
                }
            }
            .sheet(isPresented: $showsCatalog, onDismiss: focusSelectedPrice) {
                InvoiceItemCatalogView(model: model, onSelect: selectCatalogItem)
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    /// Copies the selected description and price into the pending edit.
    private func selectCatalogItem(_ selected: InvoiceCatalogItem) {
        // Only move focus after an authorized catalog selection has been applied.
        if let updated = model.applyingCatalogItem(selected, to: item) {
            item = updated
            catalogPriceSelected = true
        }
        showsCatalog = false
    }

    /// Selects the populated unit price once the picker has closed.
    private func focusSelectedPrice() {
        // Dismissing the catalog without a selection leaves focus alone.
        if catalogPriceSelected {
            priceFocusRequest = item.id
            catalogPriceSelected = false
        }
    }

    /// Applies the pending line and closes the form on success.
    private func saveItem() {
        // Keep the form open if the draft rejects the change.
        if model.saveItem(item, replacing: original) {
            dismiss()
        } else {
            saveFailed = true
        }
    }

    /// Removes an existing line and returns to the list.
    private func removeItem() {
        // New lines exist only in the form and do not have a removal action.
        if let original {
            model.removeItem(id: original.id)
        }
        dismiss()
    }
}
