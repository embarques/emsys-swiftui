import SwiftUI

struct InvoiceContainerSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NetworkConnection.self) private var connection
    @State var model: InvoiceContainerSearchModel
    let select: (InvoiceContainer) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.isAvailable { results }
                else { ContentUnavailableView("auth.unavailable", systemImage: "lock") }
            }
            .navigationTitle("containers.choose")
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
                TextField("containers.searchPrompt", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("customers.search") { search() }.disabled(model.isLoading)
            }
            .padding(.horizontal)
            if let issue = model.issue { Text(LocalizedStringKey(issue)).padding(.horizontal) }
            if model.isShowingDownloaded {
                Text("containers.downloadedHint").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            if model.isLoading { ProgressView() }
            List {
                if model.containers.isEmpty && !model.isLoading {
                    Text("containers.noResults").foregroundStyle(.secondary)
                }
                ForEach(model.containers) { container in
                    Button {
                        guard model.isAvailable else { return }
                        select(container)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                            Text(container.displayName).font(.headline).foregroundStyle(.primary)
                            if let number = container.containerNumber, !number.isEmpty {
                                Text(number).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if model.hasMore {
                    Button("containers.more") {
                        Task { await model.loadMore(online: connection.status != .unavailable) }
                    }
                    .disabled(model.isLoading || connection.status == .unavailable)
                }
            }
        }
    }

    private func search() {
        Task { await model.search(online: connection.status != .unavailable) }
    }
}
