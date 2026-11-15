import SwiftUI

struct InvoiceListFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query: InvoiceListQuery
    @State private var hasStart: Bool
    @State private var hasEnd: Bool
    @State private var start: Date
    @State private var end: Date
    let apply: (InvoiceListQuery) -> Void

    init(query: InvoiceListQuery, apply: @escaping (InvoiceListQuery) -> Void) {
        _query = State(initialValue: query)
        _hasStart = State(initialValue: !query.startDate.isEmpty)
        _hasEnd = State(initialValue: !query.endDate.isEmpty)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .gmt
        _start = State(initialValue: formatter.date(from: query.startDate) ?? .now)
        _end = State(initialValue: formatter.date(from: query.endDate) ?? .now)
        self.apply = apply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("invoiceList.filters") {
                    TextField("invoiceList.container", text: $query.container)
                    Toggle("invoiceList.from", isOn: $hasStart)
                    if hasStart { DatePicker("invoiceList.from", selection: $start, displayedComponents: .date) }
                    Toggle("invoiceList.until", isOn: $hasEnd)
                    if hasEnd { DatePicker("invoiceList.until", selection: $end, displayedComponents: .date) }
                    if hasStart, hasEnd, day(start) > day(end) {
                        Text("invoiceList.dateError").foregroundStyle(.red)
                    }
                }
                Button("invoiceList.reset") {
                    query.container = ""
                    hasStart = false
                    hasEnd = false
                }
            }
            .navigationTitle("invoiceList.filters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("documents.close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("invoiceList.apply") {
                        query.startDate = hasStart ? day(start) : ""
                        query.endDate = hasEnd ? day(end) : ""
                        query.container = query.container.trimmingCharacters(in: .whitespacesAndNewlines)
                        apply(query)
                        dismiss()
                    }
                    .disabled(hasStart && hasEnd && day(start) > day(end))
                }
            }
        }
        .frame(minWidth: 300, minHeight: 350)
    }

    private func day(_ date: Date) -> String { InvoiceDate(date: date).apiValue }
}
