import SwiftUI

struct InvoiceAssignmentPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NetworkConnection.self) private var connection
    @State var model: InvoiceAssignmentPickerModel
    let selectRoute: (InvoicePickupRoute) -> Void
    let selectEmployee: (InvoicePickupEmployee) -> Void

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if model.isAvailable {
                    choices
                } else {
                    ContentUnavailableView("auth.unavailable", systemImage: "lock")
                }
            }
            .navigationTitle("pickupAssignment.choose")
            .searchable(text: $model.query, prompt: "pickupAssignment.search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("invoiceEdits.cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("pickupAssignment.download") {
                        Task { await model.load(online: connection.status != .unavailable) }
                    }
                    .disabled(model.isLoading)
                }
            }
            .task { await model.load(online: false) }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private var choices: some View {
        VStack(spacing: AppStyle.Spacing.small) {
            if model.isLoading { ProgressView() }
            if let issue = model.issue { Text(LocalizedStringKey(issue)).padding(.horizontal) }
            if model.isShowingDownloaded {
                Text("pickupAssignment.downloadedHint").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            List {
                if model.source == .route {
                    if model.matchingRoutes.isEmpty { Text("pickupAssignment.empty").foregroundStyle(.secondary) }
                    ForEach(model.matchingRoutes) { route in
                        Button {
                            guard model.isAvailable else { return }
                            selectRoute(route)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                                Text(route.displayName).font(.headline).foregroundStyle(.primary)
                                if let crew = route.route { Text(crew.name ?? crew.id).foregroundStyle(.secondary) }
                                if let date = route.date { Text(String(date.prefix(10))).font(.caption).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    if model.matchingEmployees.isEmpty { Text("pickupAssignment.empty").foregroundStyle(.secondary) }
                    ForEach(model.matchingEmployees) { employee in
                        Button {
                            guard model.isAvailable else { return }
                            selectEmployee(employee)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                                Text(employee.displayName).font(.headline).foregroundStyle(.primary)
                                if let branch = employee.branch {
                                    Text([branch.code, branch.name].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
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
    }
}
