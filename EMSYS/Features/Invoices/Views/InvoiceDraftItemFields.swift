import SwiftUI

struct InvoiceDraftItemFields: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isPriceFocused: Bool
    @Binding var item: InvoiceDraft.Item
    @Binding var priceFocusRequest: UUID?
    let chooseDescription: () -> Void
    let remove: () -> Void
    var usesMobileLayout = false
    var canRemove = true

    /// Returns the line total calculated by the draft’s existing rules.
    private var lineTotal: Double? { try? InvoiceDraftAmounts(items: [item]).lineTotals[item.id] }

    /// Shows the editable quantity with its numeric keyboard.
    private var quantityField: some View {
        InvoiceDraftField(title: "invoices.quantity", text: $item.quantity, input: .decimal, usesProminentNumber: usesMobileLayout)
    }
    /// Shows the price and focuses it when the description picker confirms.
    private var priceField: some View {
        InvoiceDraftField(
            title: "drafts.price",
            text: $item.unitPrice,
            input: .decimal,
            usesProminentNumber: usesMobileLayout
        )
        .focused($isPriceFocused)
        .onChange(of: priceFocusRequest, initial: true) {
            // A request belongs only to the item whose description was selected.
            if priceFocusRequest == item.id {
                isPriceFocused = true
                priceFocusRequest = nil
            }
        }
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

    /// Opens the description picker from a full-width row with the current value.
    private var descriptionField: some View {
        // Stack the title and value when larger text needs more horizontal room.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppStyle.Spacing.small))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.medium))
        let value = item.name.isEmpty ? Text("itemCatalog.choose") : Text(item.name)
        return Button {
            // Release the keyboard before presenting the picker.
            isPriceFocused = false
            chooseDescription()
        } label: {
            HStack(spacing: AppStyle.Spacing.medium) {
                layout {
                    Text("invoiceEdits.description").foregroundStyle(.primary)
                    value.foregroundStyle(.tint)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("invoiceEdits.description"))
        .accessibilityValue(value)
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
