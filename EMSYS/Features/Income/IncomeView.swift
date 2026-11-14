import SwiftUI

struct IncomeView: View {
    @Environment(AuthenticationSession.self) private var session
    @Environment(NetworkConnection.self) private var connection
    @Environment(SynchronizationState.self) private var synchronization
    @State private var model: IncomeModel?
    @State private var selectedDay: InvoiceDate?
    @State private var entry: Entry?
    @State private var couldNotOpen = false

    private struct Entry: Identifiable {
        let kind: IncomeJournalKind
        let statementID: UInt32
        var id: IncomeJournalKind { kind }
    }

    private struct Refresh: Equatable {
        let day: InvoiceDate?
        let status: NetworkConnection.Status
        let lastSync: Date?
        let mayCreate: Bool
    }

    private var refresh: Refresh {
        .init(day: selectedDay, status: connection.status, lastSync: synchronization.lastFinishedAt,
              mayCreate: session.canPrepareIncomeJournal)
    }

    var body: some View {
        Group {
            if let model {
                IncomeOverviewView(model: model, mayCreate: session.canPrepareIncomeJournal,
                                   selectedDay: $selectedDay, retry: { await reload(model) })
                    .task(id: refresh) { await reload(model) }
                    .refreshable { await reload(model) }
                    .toolbar {
                        if session.canPrepareIncomeJournal {
                            Menu {
                                ForEach(IncomeJournalKind.allCases) { kind in
                                    Button {
                                        if let statement = model.period?.statement {
                                            entry = Entry(kind: kind, statementID: statement.id)
                                        }
                                    } label: {
                                        Label(LocalizedStringKey(kind.entryTitle), systemImage: kind.icon)
                                    }
                                }
                            } label: {
                                Label("income.add", systemImage: "plus.circle.fill")
                            }
                            .disabled(!model.canCreate)
                        }
                    }
                    .sheet(item: $entry) { entry in
                        IncomeEntryView(model: model, kind: entry.kind, statementID: entry.statementID) {
                            synchronization.requestUpload()
                        }
                    }
            } else if couldNotOpen {
                ContentUnavailableView {
                    Label("income.loadError", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("auth.retry") { Task { await prepare() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("navigation.dailyIncome")
        .task(id: session.contextID) { await prepare() }
    }

    private func reload(_ model: IncomeModel) async {
        await model.load(selectedDay: selectedDay, online: connection.status != .unavailable)
    }

    private func prepare() async {
        model = nil
        couldNotOpen = false
        let context = session.contextID
        do {
            guard let branchID = session.user?.branch?.id, branchID > 0 else {
                throw AuthenticationIssue.authorization
            }
            let access = try await session.incomeAccess()
            guard !Task.isCancelled, context == session.contextID else { return }
            model = IncomeModel(service: .init(client: access.client, store: access.store), branchID: branchID,
                isAuthorized: { session.contextID == context && session.canViewIncome },
                mayCreate: { session.contextID == context && session.canPrepareIncomeJournal })
        } catch {
            if !Task.isCancelled, context == session.contextID { couldNotOpen = true }
        }
    }
}


struct IncomeOverviewView: View {
    let model: IncomeModel
    let mayCreate: Bool
    @Binding var selectedDay: InvoiceDate?
    let retry: () async -> Void
    @State private var showsDatePicker = false

    var body: some View {
        List {
            Section {
                summary(model)
                    .listRowBackground(AppStyle.Colors.accent.opacity(0.09))
            }
            if model.isShowingDownloaded {
                Label("income.downloaded", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = model.issue {
                Button { Task { await retry() } } label: {
                    Label(LocalizedStringKey(issue), systemImage: "arrow.clockwise")
                }
            }
            if mayCreate, !model.isLoading, !model.canCreate {
                Label("income.openPeriodRequired", systemImage: "calendar.badge.exclamationmark")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if model.isLoading && model.period == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if !model.pending.isEmpty {
                Section("income.savedEntries") {
                    ForEach(model.pending) { operation in
                        let item = operation.request.entry
                        activityRow(kind: item.transactionType, title: item.description ?? item.account.name,
                            amount: item.amount, currency: operation.currency,
                            status: operation.reviewReason ?? "income.pending", day: operation.day)
                    }
                }
            }
            if let currency = model.currency, !model.journals.isEmpty {
                Section {
                    ForEach(model.journals) { item in
                        activityRow(kind: item.transactionType, title: item.description ?? item.accountName,
                                    amount: item.amount, currency: currency)
                    }
                } header: {
                    if let date = model.day.pickerDate {
                        Text(date, format: .dateTime.day().month(.wide).year())
                            .environment(\.timeZone, .gmt)
                    }
                }
            } else if !model.isLoading && model.issue == nil {
                ContentUnavailableView("income.empty", systemImage: "tray")
            }
        }
        .sheet(isPresented: $showsDatePicker) {
            NavigationStack {
                DatePicker("drafts.date", selection: Binding(
                    get: { (selectedDay ?? model.day).pickerDate ?? .now },
                    set: { selectedDay = InvoiceDate(date: $0, calendar: InvoiceDate.calendar) }),
                    displayedComponents: .date)
                .datePickerStyle(.graphical)
                .environment(\.timeZone, .gmt)
                .padding()
                .navigationTitle("drafts.date")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("income.today") {
                            selectedDay = nil
                            showsDatePicker = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("documents.close") { showsDatePicker = false }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 380, minHeight: 400)
            #endif
        }
    }

    private func summary(_ model: IncomeModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { showsDatePicker = true } label: {
                if let selectedDay, let date = selectedDay.pickerDate {
                    Label {
                        Text(date, format: .dateTime.day().month(.abbreviated).year())
                            .environment(\.timeZone, .gmt)
                    } icon: { Image(systemName: "calendar") }
                } else {
                    Label("income.today", systemImage: "calendar")
                }
            }
            .buttonStyle(.bordered)
            Text("income.net").font(.subheadline).foregroundStyle(.secondary)
            if let currency = model.currency {
                Text(model.total(.sale) - model.total(.expense), format: .currency(code: currency))
                    .font(.largeTitle.bold()).monospacedDigit()
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) {
                        total(model, kind: .sale, currency: currency)
                        Spacer(minLength: 0)
                        total(model, kind: .expense, currency: currency)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        total(model, kind: .sale, currency: currency)
                        total(model, kind: .expense, currency: currency)
                    }
                }
            } else {
                Text("—").font(.largeTitle.bold()).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 10)
    }

    private func total(_ model: IncomeModel, kind: IncomeJournalKind, currency: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(kind.title)).font(.caption).foregroundStyle(.secondary)
            Text(model.total(kind), format: .currency(code: currency))
                .font(.headline).monospacedDigit()
        }
    }

    private func activityRow(kind: IncomeJournalKind, title: String?, amount: Decimal,
                             currency: String, status: String? = nil, day: InvoiceDate? = nil) -> some View {
        let signedAmount = kind == .sale ? amount : -amount
        return LabeledContent {
            Text(signedAmount, format: .currency(code: currency).sign(strategy: .always()))
                .font(.body.weight(.semibold)).monospacedDigit()
                .foregroundStyle(kind == .sale ? .green : .primary)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    if let title, !title.isEmpty { Text(verbatim: title) }
                    else { Text(LocalizedStringKey(kind.title)) }
                    if let status {
                        Text(LocalizedStringKey(status)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let date = day?.pickerDate {
                        Text(date, format: .dateTime.day().month(.abbreviated).year())
                            .font(.caption).foregroundStyle(.secondary).environment(\.timeZone, .gmt)
                    }
                }
            } icon: {
                Image(systemName: kind.icon).foregroundStyle(AppStyle.Colors.accent)
            }
        }
    }
}
