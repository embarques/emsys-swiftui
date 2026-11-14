import SwiftUI

struct InvoiceDraftItemFields: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isPriceFocused: Bool
    @State private var priceSelection: TextSelection?
    @State private var expandedOptions = false
    @Binding var item: InvoiceDraft.Item
    @Binding var priceFocusRequest: UUID?
    let canChooseCatalogItems: Bool
    let choose: () -> Void
    let remove: () -> Void
    var usesMobileLayout = false

    private var lineTotal: Double? { try? InvoiceDraftAmounts(items: [item]).lineTotals[item.id] }

    private var quantityField: some View {
        InvoiceDraftField(title: "invoices.quantity", text: $item.quantity, input: .decimal, emphasizesValue: usesMobileLayout)
    }
    private var priceField: some View {
        InvoiceDraftField(title: "drafts.unitPrice", text: $item.unitPrice, input: .decimal, selection: $priceSelection, emphasizesValue: usesMobileLayout)
            .focused($isPriceFocused)
            .onChange(of: priceFocusRequest, initial: true) {
                guard priceFocusRequest == item.id else { return }
                if isPriceFocused {
                    selectPrice()
                } else {
                    isPriceFocused = true
                }
            }
            .onChange(of: isPriceFocused) {
                if isPriceFocused, priceFocusRequest == item.id { selectPrice() }
            }
    }
    private func selectPrice() {
        let price = item.unitPrice
        priceSelection = TextSelection(range: price.startIndex..<price.endIndex)
        priceFocusRequest = nil
    }

    private var labelsField: some View {
        InvoiceDraftField(title: "drafts.labelCount", text: $item.labelCount, input: .integer)
    }
    private var totalField: some View {
        InvoiceDraftField(title: "drafts.totalOverride", text: $item.total, input: .decimal)
    }

    var body: some View {
        Section {
            if usesMobileLayout {
                mobileFields
            } else {
                itemHeader
                InvoiceDraftField(title: "invoiceEdits.description", text: $item.name)
                if canChooseCatalogItems { catalogButton }
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
                removeButton
            }
        }
    }

    private var mobileFields: some View {
        Group {
            InvoiceDraftField(title: "invoiceEdits.description", text: $item.name)
            if canChooseCatalogItems { catalogButton }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .bottom, spacing: 8))
            layout {
                quantityField
                priceField
            }
            if let lineTotal {
                LabeledContent("invoices.total") {
                    Text(lineTotal, format: .number.precision(.fractionLength(2)))
                        .font(.title3.bold()).monospacedDigit()
                }
            }
            DisclosureGroup("drafts.itemOptions", isExpanded: $expandedOptions) {
                labelsField
                totalField
            }
            .onChange(of: item.labelCount, initial: true) { _, count in
                if !count.isEmpty { expandedOptions = true }
            }
            .onChange(of: item.total, initial: true) { _, total in
                if !total.isEmpty { expandedOptions = true }
            }
            removeButton
        }
    }

    private var itemHeader: some View {
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
    }

    private var catalogButton: some View {
        Button(action: choose) {
            Label("itemCatalog.choose", systemImage: "tag")
                .frame(minHeight: usesMobileLayout ? 44 : 36)
        }
    }

    private var removeButton: some View {
        Button(role: .destructive, action: remove) {
            Label("drafts.removeItem", systemImage: "trash").frame(minHeight: usesMobileLayout ? 44 : 36)
        }
    }
}
