import SwiftUI

/// Shared native composition for the live directory and deterministic visual checks.
struct InvoiceDirectoryView: View {
    @Environment(\.locale) private var locale
    @Binding var query: InvoiceListQuery
    let invoices: [Invoice]
    var localEntries: [LocalInvoiceListEntry] = []
    var openLocal: (LocalInvoiceListEntry) -> Void = { _ in }
    var deleteLocal: ((LocalInvoiceListEntry) -> Void)? = nil
    let outstandingBalance: Decimal
    let isLoading: Bool
    let isDownloaded: Bool
    let hasMore: Bool
    let issue: String?
    let showFilters: () -> Void
    let open: (Invoice) -> Void
    let printInvoice: ((Invoice) -> Void)?
    let more: () async -> Void
    let retry: () async -> Void
    let refresh: () async -> Void

    private var directoryInvoices: [Invoice] {
        let pinned = Set(localEntries.compactMap { $0.invoice?.id })
        return invoices.filter { !pinned.contains($0.id) }
    }

    private var months: [String] {
        var seen = Set<String>()
        return directoryInvoices.map(\.monthKey).filter { seen.insert($0).inserted }
    }

    var body: some View {
        List {
            Group {
                header.padding(.bottom, 20)
                if isDownloaded {
                    Label("invoiceList.downloaded", systemImage: "internaldrive")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
                }
                if let issue {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringKey(issue)).font(.callout)
                        Button("auth.retry") { Task { await retry() } }.buttonStyle(.bordered)
                    }
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppStyle.Colors.surface, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 12)
                }
                if !localEntries.isEmpty {
                    Text("invoiceList.localCreations").font(.headline).foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                    ForEach(localEntries) { entry in
                        if let invoice = entry.invoice {
                            InvoiceListRow(invoice: invoice, open: { open(invoice) },
                                printInvoice: printInvoice.map { action in { action(invoice) } })
                        } else {
                            Button { openLocal(entry) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.number ?? entry.senderName).font(.headline)
                                    if entry.number != nil { Text(entry.senderName) }
                                    Label(LocalizedStringKey(entry.state.title), systemImage: "clock.arrow.circlepath")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(12)
                                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            #if os(iOS)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if entry.canDelete, let deleteLocal {
                                    Button("drafts.delete", systemImage: "trash") {
                                        deleteLocal(entry)
                                    }
                                    .tint(.red)
                                }
                            }
                            #endif
                            .contextMenu {
                                if entry.canDelete, let deleteLocal {
                                    Button("drafts.delete", systemImage: "trash", role: .destructive) {
                                        deleteLocal(entry)
                                    }
                                }
                            }
                        }
                    }
                }
                ForEach(months, id: \.self) { month in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(monthTitle(month)).font(.headline).foregroundStyle(.secondary)
                            .padding(.top, 12).padding(.bottom, 10)
                        LazyVStack(spacing: 0) {
                            ForEach(directoryInvoices.filter { $0.monthKey == month }) { invoice in
                                InvoiceListRow(invoice: invoice, open: { open(invoice) },
                                    printInvoice: printInvoice.map { action in { action(invoice) } })
                                Divider().padding(.horizontal, 16)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary.opacity(0.15)))
                    }
                }
                if invoices.isEmpty && localEntries.isEmpty {
                    if isLoading { ProgressView().frame(maxWidth: .infinity).padding(40) }
                    else if issue == nil {
                        ContentUnavailableView(LocalizedStringKey(query.scope == .unsynced ? "invoiceList.unsyncedEmpty" : (isDownloaded ? "invoices.empty" : "invoiceList.liveEmpty")),
                            systemImage: "doc.text.magnifyingglass",
                            description: query.scope == .unsynced ? nil : Text(LocalizedStringKey(isDownloaded ? "invoiceList.emptyHint" : "invoiceList.liveEmptyHint")))
                    }
                }
                if hasMore, !invoices.isEmpty, issue == nil {
                    Button { Task { await more() } } label: {
                        HStack {
                            if isLoading { ProgressView().controlSize(.small) }
                            Text(isLoading ? "invoiceList.loading" : "invoiceList.more")
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(isLoading)
                    .task { await more() }
                    .id(invoices.count)
                    .padding(.vertical, 12)
                } else if !invoices.isEmpty, !isLoading, issue == nil {
                    Text("invoiceList.end").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(20)
                }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .contentMargins(.vertical, 16, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 852)
        .frame(maxWidth: .infinity)
        .background(AppStyle.Colors.surface)
        .background(.background)
        .refreshable { await refresh() }
    }

    private var header: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("invoiceList.search", text: $query.text)
                        .textFieldStyle(.plain).submitLabel(.search)
                        .accessibilityIdentifier("invoice-search")
                    if !query.text.isEmpty {
                        Button { query.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("invoiceList.clearSearch")
                    }
                }
                .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.secondary.opacity(0.2)))
                Button(action: showFilters) {
                    Image(systemName: query.hasAdditionalFilters ? "line.3.horizontal.decrease.circle.fill" : "slider.horizontal.3")
                        .font(.title3).frame(width: 48, height: 48)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("invoiceList.filters")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("invoiceList.outstanding").font(.subheadline.weight(.medium))
                HStack(alignment: .firstTextBaseline) {
                    Text("invoiceList.downloadedTotal").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(outstandingBalance, format: .currency(code: "USD"))
                        .font(.title2.weight(.bold)).monospacedDigit()
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(InvoiceListQuery.Scope.allCases) { scope in
                        Button { query.scope = scope } label: {
                            Text(LocalizedStringKey(scope.title)).font(.subheadline.weight(.medium))
                                .padding(.horizontal, 15).frame(minHeight: 44)
                                .background(query.scope == scope ? Color.accentColor.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(query.scope == scope ? Color.accentColor : .secondary)
                        .accessibilityAddTraits(query.scope == scope ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func monthTitle(_ value: String) -> String {
        guard let invoice = invoices.first(where: { $0.monthKey == value }), let date = invoice.calendarDate else { return "—" }
        return date.formatted(Date.FormatStyle(locale: locale, timeZone: .gmt).month(.wide).year())
    }
}
