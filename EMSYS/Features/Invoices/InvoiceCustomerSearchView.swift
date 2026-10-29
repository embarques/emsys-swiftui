import SwiftUI

struct InvoiceCustomerSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NetworkConnection.self) private var connection
    @State var model: InvoiceCustomerSearchModel
    let select: (InvoiceCustomer) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.isAvailable {
                    results
                } else {
                    ContentUnavailableView("auth.unavailable", systemImage: "lock")
                }
            }
            .navigationTitle(model.role == .sender ? "customers.chooseSender" : "customers.chooseReceiver")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("invoiceEdits.cancel") { dismiss() } }
            }
            .task { await model.search(online: false) }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private var results: some View {
        @Bindable var model = model
        return VStack(spacing: AppStyle.Spacing.small) {
            HStack {
                TextField("customers.searchPrompt", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("customers.search") { search() }
                    .disabled(model.isLoading)
            }
            .padding(.horizontal)
            if model.isLoading { ProgressView() }
            if let issue = model.issue { Text(LocalizedStringKey(issue)).font(.callout).padding(.horizontal) }
            if model.isShowingDownloaded {
                Text("customers.downloadedHint").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            List {
                if model.customers.isEmpty && !model.isLoading {
                    Text("customers.noResults").foregroundStyle(.secondary)
                }
                ForEach(model.customers) { customer in
                    Button {
                        guard model.isAvailable else { return }
                        select(customer)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                            Text(customer.name).font(.headline).foregroundStyle(.primary)
                            if let phone = customer.displayPhone { Text(phone).foregroundStyle(.secondary) }
                            if let address = customer.addresses?.first {
                                Text(address.displayText).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func search() {
        Task { await model.search(online: connection.status != .unavailable) }
    }
}
