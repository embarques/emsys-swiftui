import SwiftUI

struct InvoiceDraftItemFields: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var item: InvoiceDraft.Item
    let canChooseCatalogItems: Bool
    let choose: () -> Void
    let remove: () -> Void

    private var lineTotal: Double? { try? InvoiceDraftAmounts(items: [item]).lineTotals[item.id] }

    private var quantityField: some View {
        InvoiceDraftField(title: "invoices.quantity", text: $item.quantity, input: .decimal)
    }
    private var priceField: some View {
        InvoiceDraftField(title: "drafts.unitPrice", text: $item.unitPrice, input: .decimal)
    }
    private var labelsField: some View {
        InvoiceDraftField(title: "drafts.labelCount", text: $item.labelCount, input: .integer)
    }
    private var totalField: some View {
        InvoiceDraftField(title: "drafts.totalOverride", text: $item.total, input: .decimal)
    }

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Label("invoiceWizard.item", systemImage: "shippingbox")
                    .font(.headline).foregroundStyle(.tint)
                Spacer(minLength: AppStyle.Spacing.small)
                if let lineTotal {
                    Text(lineTotal, format: .number.precision(.fractionLength(2)))
                        .font(.title3.bold()).monospacedDigit()
                        .accessibilityLabel(Text("invoices.total"))
                        .accessibilityValue(Text(lineTotal, format: .number.precision(.fractionLength(2))))
                }
            }
            .padding(.vertical, 6)
            InvoiceDraftField(title: "invoiceEdits.description", text: $item.name)
            if canChooseCatalogItems {
                Button(action: choose) {
                    Label("itemCatalog.choose", systemImage: "tag")
                        .frame(minHeight: 36)
                }
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    quantityField
                    priceField
                    labelsField
                    totalField
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    GridRow(alignment: .top) { quantityField; priceField }
                    GridRow(alignment: .top) { labelsField; totalField }
                }
            }
            Button(role: .destructive, action: remove) {
                Label("drafts.removeItem", systemImage: "trash").frame(minHeight: 36)
            }
        }
    }
}
