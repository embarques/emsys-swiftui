import SwiftUI

struct InvoiceListRow: View {
    @Environment(\.locale) private var locale
    let invoice: Invoice
    let open: () -> Void
    let printInvoice: (() -> Void)?
    @State private var expanded = false

    private var status: String {
        if invoice.registration == "PENDING" { return "invoiceList.incomplete" }
        if invoice.paidStatus == "CLOSED" { return "invoiceList.paid" }
        return "invoiceList.due"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation { expanded.toggle() } } label: {
                VStack(spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(invoice.number ?? invoice.id).font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                        Spacer(minLength: 8)
                        if let date = invoice.calendarDate {
                            Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: .gmt)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Text(invoice.initials).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                            .frame(width: 38, height: 38)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(invoice.sender?.name ?? invoice.receiver?.name ?? "—")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                            if let address = invoice.sender?.displayAddress, !address.isEmpty {
                                Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 3) {
                            if let balance = invoice.balance ?? (invoice.paidStatus == "CLOSED" ? Decimal.zero : nil) {
                                Text(balance, format: .currency(code: "USD"))
                                    .font(.headline).monospacedDigit().foregroundStyle(.primary)
                            } else { Text("—").foregroundStyle(.secondary) }
                            Text("invoices.balance").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .center, spacing: 8) {
                        Label(invoice.container?.name ?? "—", systemImage: "shippingbox")
                            .lineLimit(1)
                        Text(invoice.quantity, format: .number)
                        Text("invoiceList.items")
                        Spacer(minLength: 0)
                        Text(LocalizedStringKey(status))
                            .foregroundStyle(status == "invoiceList.paid" ? Color.green : Color.orange)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(AppStyle.Colors.surface, in: RoundedRectangle(cornerRadius: 6))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").accessibilityHidden(true)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(invoice.number ?? invoice.id))
            .accessibilityValue(Text(expanded ? "invoiceList.expanded" : "invoiceList.collapsed"))
            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("invoices.receiver").font(.caption).foregroundStyle(.secondary)
                    Text(invoice.receiver?.name ?? "—").font(.subheadline.weight(.medium))
                    if let address = invoice.receiver?.displayAddress, !address.isEmpty {
                        Text(address).font(.caption).foregroundStyle(.secondary)
                    }
                    if let phone = invoice.sender?.displayPhone {
                        Text(phone).font(.subheadline).textSelection(.enabled)
                    }
                    HStack {
                        Button(action: open) { Label("invoiceList.open", systemImage: "doc.text") }
                        if let printInvoice {
                            Button(action: printInvoice) { Label("documents.print", systemImage: "printer") }
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.regular).padding(.top, 4)
                }
            }
        }
        .padding(16)
        .background(.background)
    }
}
