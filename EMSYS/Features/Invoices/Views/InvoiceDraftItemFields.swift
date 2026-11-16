import SwiftUI

struct InvoiceDraftItemFields: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isPriceFocused: Bool
    @State private var priceSelection: TextSelection?
    @Binding var item: InvoiceDraft.Item
    @Binding var priceFocusRequest: UUID?
    let canChooseCatalogItems: Bool
    let choose: () -> Void
    let remove: () -> Void
    var usesMobileLayout = false
    var canRemove = true

    /// Returns the line total calculated by the draft’s existing rules.
    private var lineTotal: Double? { try? InvoiceDraftAmounts(items: [item]).lineTotals[item.id] }

    /// Shows the editable quantity with its numeric keyboard.
    private var quantityField: some View {
        InvoiceDraftField(title: "invoices.quantity", text: $item.quantity, input: .decimal, usesProminentNumber: usesMobileLayout)
    }
    /// Shows the unit price and responds to catalog-driven focus requests.
    private var priceField: some View {
        InvoiceDraftField(title: "drafts.unitPrice", text: $item.unitPrice, input: .decimal, selection: $priceSelection, usesProminentNumber: usesMobileLayout)
            .focused($isPriceFocused)
            .onChange(of: priceFocusRequest, initial: true) {
                // Apply the request only to the item whose price was populated.
                guard priceFocusRequest == item.id else {
                    return
                }
                if isPriceFocused {
                    selectPrice()
                } else {
                    isPriceFocused = true
                }
            }
            .onChange(of: isPriceFocused) {
                // Wait for the native field to accept focus before selecting its text.
                if isPriceFocused, priceFocusRequest == item.id {
                    selectPrice()
                }
            }
    }
    /// Selects the unit price for quick replacement after a catalog choice.
    private func selectPrice() {
        let price = item.unitPrice
        priceSelection = TextSelection(range: price.startIndex..<price.endIndex)
        priceFocusRequest = nil
    }

    /// Shows the item description, quantity, unit price, and total.
    var body: some View {
        Section {
            descriptionField
            numericFields
            totalRow
        }

        // Give the destructive action a separate native row below the editable fields.
        if canRemove {
            Section {
                removeButton
            }
        }
    }

    /// Arranges the numeric inputs in two columns, with room to stack large text.
    @ViewBuilder
    private var numericFields: some View {
        // Switch to separate rows when the labels and values need the full width.
        if dynamicTypeSize.isAccessibilitySize {
            quantityField
            priceField
        } else {
            HStack(alignment: .center, spacing: AppStyle.Spacing.medium) {
                quantityField
                Divider().frame(height: 36)
                priceField
            }
        }
    }

    /// Keeps the line total in a consistent position while the fields are edited.
    private var totalRow: some View {
        LabeledContent {
            // Show a placeholder until the existing invoice rules can calculate the total.
            if let lineTotal {
                Text(lineTotal, format: .number.precision(.fractionLength(2)))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text("invoices.total")
                .font(.subheadline.weight(.semibold))
        }
    }

    /// Places the catalog picker beside the editable description.
    private var descriptionField: some View {
        HStack(alignment: .center, spacing: AppStyle.Spacing.small) {
            InvoiceDraftField(title: "invoiceEdits.description", text: $item.name)
            // Preserve manual entry when the user lacks catalog access.
            if canChooseCatalogItems {
                Button(action: choose) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.12), in: .circle)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel(Text("itemCatalog.choose"))
            }
        }
    }

    /// Presents the destructive action with a full-width touch target.
    private var removeButton: some View {
        Button(role: .destructive, action: remove) {
            Label("drafts.removeItem", systemImage: "trash")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
    }
}
