import SwiftUI

/// Read-only business content, shared by the native detail screen's layouts.
struct InvoiceDetailContent: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var textSize
    let invoice: Invoice

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            parties
            VStack(alignment: .leading, spacing: 0) {
                Text("invoices.items").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 12)
                Divider()
                if let items = invoice.invoiceDetails, !items.isEmpty {
                    ForEach(items) { item in
                        InvoiceDetailItemRow(item: item).padding(.vertical, 20)
                        Divider()
                    }
                } else {
                    Text("invoiceDetail.noItems").foregroundStyle(.secondary).padding(.vertical, 20)
                    Divider()
                }
            }
            if [invoice.cost, invoice.discount, invoice.surcharge, invoice.payment, invoice.balance].contains(where: { $0 != nil }) {
                totals
            }
        }
        .textSelection(.enabled)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: invoice.number ?? invoice.id)
                .font(.title2.bold()).accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            let layout = textSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
            layout {
                if let date = invoice.calendarDate {
                    Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted,
                        locale: locale, timeZone: .gmt)))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if !textSize.isAccessibilitySize { Spacer(minLength: 0) }
                if invoice.registration == "PENDING" {
                    badge("invoiceList.incomplete", symbol: "doc.badge.clock", color: .orange)
                } else if invoice.paidStatus == "CLOSED" {
                    badge("invoiceList.paid", symbol: "checkmark.circle", color: .green)
                } else if invoice.paidStatus == "OPEN" {
                    badge("invoiceList.due", symbol: "clock", color: .orange)
                }
            }
        }
    }

    private func badge(_ title: LocalizedStringKey, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.10), in: Capsule())
    }

    private var parties: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                party("invoices.sender", invoice.sender).frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                party("invoices.receiver", invoice.receiver).frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 20) {
                party("invoices.sender", invoice.sender)
                party("invoices.receiver", invoice.receiver)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppStyle.Colors.surface, in: RoundedRectangle(cornerRadius: AppStyle.Layout.cornerRadius))
    }

    private func party(_ title: LocalizedStringKey, _ party: Invoice.Party?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: party?.name ?? "—").font(.subheadline.weight(.semibold))
            if let address = party?.displayAddress, !address.isEmpty {
                Text(verbatim: address).font(.subheadline).foregroundStyle(.secondary)
            }
            if let phone = party?.displayPhone, !phone.isEmpty {
                Text(verbatim: phone).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var totals: some View {
        VStack(spacing: 14) {
            Text("invoices.totals").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            // Keep the server's amounts and signs. Do not infer currency,
            // settlement, or a new total from a partial invoice projection.
            amount("invoices.cost", value: invoice.cost)
            amount("invoicePayment.discount", value: invoice.discount)
            amount("invoiceDetail.surcharge", value: invoice.surcharge)
            amount("invoices.payment", value: invoice.payment)
            if invoice.balance != nil {
                Divider().padding(.vertical, 4)
                amount("invoices.balance", value: invoice.balance)
                    .font(.title3.bold())
            }
        }
    }

    @ViewBuilder
    private func amount(_ title: LocalizedStringKey, value: Decimal?) -> some View {
        if let value {
            LabeledContent(title) {
                Text(value, format: .number.precision(.fractionLength(2)))
                    .foregroundStyle(.primary)
                    .monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct InvoiceDetailItemRow: View {
    @Environment(\.dynamicTypeSize) private var textSize
    let item: Invoice.Item

    var body: some View {
        let layout = textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
        layout {
            VStack(alignment: .leading, spacing: 7) {
                Group {
                    if let name = item.displayName { Text(verbatim: name) }
                    else { Text("invoiceDetail.unnamedItem") }
                }
                .font(.body.weight(.medium))
                if let description = item.supportingDescription {
                    Text(verbatim: description).font(.subheadline).foregroundStyle(.secondary)
                }
                if let quantity = item.quantity {
                    HStack(spacing: 5) {
                        Text("invoices.quantity")
                        Text(quantity, format: .number).monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if let total = item.total {
                Text(total, format: .number.precision(.fractionLength(2)))
                    .font(.body.weight(.medium)).monospacedDigit()
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: textSize.isAccessibilitySize ? .infinity : nil, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
