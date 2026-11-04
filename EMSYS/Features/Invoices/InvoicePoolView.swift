import SwiftUI

struct InvoicePoolView: View {
    @Environment(\.dismiss) private var dismiss
    @State var model: InvoicePoolModel
    @State private var returning: InvoiceReservation?

    var body: some View {
        NavigationStack {
            List {
                if model.isAvailable {
                    Section {
                        LabeledContent("invoicePool.available", value: String(model.available))
                        if model.isLow {
                            Label(model.available == 0 ? "invoicePool.empty" : "invoicePool.low", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        if let issue = model.issue { Text(LocalizedStringKey(issue)).foregroundStyle(.secondary) }
                        if model.pendingCount > 0 { Text("invoicePool.pending").foregroundStyle(.secondary) }
                    }
                    Section {
                        Button("invoicePool.download") { Task { await model.downloadAssignments() } }
                            .disabled(model.isLoading || model.pendingCount > 0)
                        Button("invoicePool.generate") { Task { await model.generateNumbers() } }
                            .disabled(!model.canGenerateNumbers)
                        Text("invoicePool.administrator").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("invoicePool.unused") {
                        ForEach(model.reservations) { reservation in
                            HStack {
                                Text(reservation.number).monospaced()
                                Spacer()
                                Button("invoicePool.return", role: .destructive) { returning = reservation }
                                    .disabled(model.isLoading || model.pendingCount > 0)
                            }
                        }
                        Text("invoicePool.returnNotice").font(.caption).foregroundStyle(.secondary)
                    }
                } else { Text("auth.unavailable") }
            }
            .navigationTitle("invoicePool.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("documents.close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("invoicePool.refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }.disabled(model.isLoading) }
            }
            .task { await model.load() }
            .confirmationDialog("invoicePool.returnPrompt", isPresented: Binding(get: { returning != nil }, set: { if !$0 { returning = nil } })) {
                if let returning { Button("invoicePool.return", role: .destructive) { Task { await model.returnNumber(returning) } } }
                Button("invoiceEdits.cancel", role: .cancel) { returning = nil }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }
}
