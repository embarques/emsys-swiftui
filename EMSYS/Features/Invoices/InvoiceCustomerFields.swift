import SwiftUI

struct InvoiceCustomerFields: View {
    @Bindable var model: InvoiceDraftEditorModel
    let role: InvoiceCustomer.Role
    let choose: () -> Void

    private var title: LocalizedStringKey { role == .sender ? "invoices.sender" : "invoices.receiver" }
    private var customer: InvoiceCustomer? {
        role == .sender ? model.content.senderCustomer : model.content.receiverCustomer
    }
    private var name: String { role == .sender ? model.content.senderName : model.content.receiverName }
    private var addressID: Binding<String?> {
        Binding(get: { role == .sender ? model.content.senderAddressID : model.content.receiverAddressID }, set: {
            if role == .sender { model.content.senderAddressID = $0 } else { model.content.receiverAddressID = $0 }
        })
    }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: AppStyle.Spacing.medium) {
                Image(systemName: role == .sender ? "person.crop.circle" : "person.crop.circle.badge.checkmark")
                    .font(.title2).foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(AppStyle.Colors.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                    if model.partiesAreLocked {
                        Text(name).font(.headline)
                    } else {
                        TextField(title, text: Binding(get: { name }, set: { model.setPartyName($0, role: role) }), axis: .vertical)
                            .font(.headline).textFieldStyle(.plain)
                            .accessibilityLabel(Text(title))
                    }
                    if let phone = customer?.displayPhone {
                        Text(phone).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            if model.canChooseCustomers {
                Button(action: choose) {
                    Label(LocalizedStringKey(customer == nil
                        ? (role == .sender ? "customers.chooseSender" : "customers.chooseReceiver")
                        : "invoiceWizard.changeCustomer"), systemImage: "person.crop.circle.badge.magnifyingglass")
                        .frame(minHeight: 36)
                }
                .accessibilityLabel(Text(role == .sender ? "customers.chooseSender" : "customers.chooseReceiver"))
            }
            if let customer {
                VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    Label("customers.address", systemImage: "mappin.and.ellipse")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let selected = customer.addresses?.first(where: { $0.id == addressID.wrappedValue }) {
                        Text(selected.displayText).font(.subheadline)
                    } else {
                        Text("customers.chooseAddress").foregroundStyle(.secondary)
                    }
                    Menu {
                        Picker("customers.address", selection: addressID) {
                            Text("customers.chooseAddress").tag(nil as String?)
                            ForEach((customer.addresses ?? []).filter { $0.id != nil }) { address in
                                Text(address.displayText).tag(address.id)
                            }
                        }
                    } label: {
                        Label("invoiceWizard.changeAddress", systemImage: "chevron.up.chevron.down")
                            .font(.subheadline).frame(minHeight: 36)
                    }
                }
                .padding(.vertical, 6)
            }
        } footer: {
            if customer != nil {
                Text(model.partiesAreLocked ? "invoiceCreation.assignedCustomerHint" : "customers.selectedHint")
            }
        }
    }
}
