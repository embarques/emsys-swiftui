import SwiftUI

/// Edits a local copy so dismissing the form discards pending changes.
struct InvoiceDraftItemForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: InvoiceDraft.Item
    @State private var showsDescriptionPicker = false
    @State private var priceFocusRequest: UUID?
    @State private var didConfirmDescription = false
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

    /// Presents the item fields, description picker, and commit controls.
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
                    chooseDescription: { showsDescriptionPicker = true },
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
            .sheet(isPresented: $showsDescriptionPicker, onDismiss: focusPriceAfterDescriptionDismissal) {
                InvoiceItemDescriptionPicker(model: model, description: item.name, onConfirm: applyDescription)
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    /// Updates the pending description and prepares the empty price field for entry.
    private func applyDescription(_ description: String) {
        // Only request price focus after the draft accepts the new description.
        if let updated = model.applyingDescription(description, to: item) {
            item = updated
            didConfirmDescription = true
        }
    }

    /// Focuses the price when a confirmed description picker closes.
    private func focusPriceAfterDescriptionDismissal() {
        // Cancel and swipe dismissal leave the original description and price in place.
        if didConfirmDescription {
            priceFocusRequest = item.id
            didConfirmDescription = false
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
