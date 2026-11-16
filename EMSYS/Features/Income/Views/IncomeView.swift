import SwiftUI

struct IncomeView: View {
    @Environment(AuthenticationSession.self) private var session
    @Environment(NetworkConnection.self) private var connection
    @Environment(SynchronizationState.self) private var synchronization
    @State private var model: IncomeViewModel?
    @State private var selectedDay: InvoiceDate?
    @State private var entry: Entry?
    @State private var couldNotOpen = false
    @State private var showsCloseoutSetup = false

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

    /// Presents branch activity and authorized closeout and journal actions.
    var body: some View {
        Group {
            if let model {
                IncomeOverviewView(model: model, mayCreate: session.canPrepareIncomeJournal,
                                   selectedDay: $selectedDay, retry: { await reload(model) },
                                   openCloseout: closeoutAction(model)) { kind, statement in
                    entry = Entry(kind: kind, statementID: statement.id)
                }
                    .task(id: refresh) { await reload(model) }
                    .refreshable { await reload(model) }
                    .sheet(isPresented: $showsCloseoutSetup) {
                        // Keep the sheet tied to the branch and account that presented it.
                        if let branch = session.user?.branch {
                            let contextID = session.contextID
                            IncomeCloseoutSetupView(branch: branch) { currency, rate in
                                try await model.openToday(currency: currency, rate: rate) {
                                    session.contextID == contextID && session.user?.branch?.id == branch.id
                                        && session.canOpenIncomeCloseout && connection.status != .unavailable
                                }
                            }
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

    /// Provides the open action for today's online Income view when the branch has permission.
    private func closeoutAction(_ model: IncomeViewModel) -> (() -> Void)? {
        // Looking at a historical day cannot open a statement for that day.
        guard selectedDay == nil, session.canOpenIncomeCloseout, connection.status != .unavailable,
              model.canOpenToday else {
            return nil
        }
        return { showsCloseoutSetup = true }
    }

    private func reload(_ model: IncomeViewModel) async {
        await model.load(selectedDay: selectedDay, online: connection.status != .unavailable)
    }

    /// Opens the journal repository for the signed-in branch.
    private func prepare() async {
        model = nil
        couldNotOpen = false
        let context = session.contextID
        do {
            guard let branchID = session.user?.branch?.id, branchID > 0 else {
                throw AuthenticationIssue.authorization
            }
            let access = try await session.incomeAccess()
            // A different account may have opened the tab while storage was loading.
            guard !Task.isCancelled, context == session.contextID else {
                return
            }
            model = IncomeViewModel(repository: .init(client: access.client, store: access.store), branchID: branchID,
                isAuthorized: { session.contextID == context && session.canViewIncome },
                mayCreate: { session.contextID == context && session.canPrepareIncomeJournal })
        } catch {
            if !Task.isCancelled, context == session.contextID {
                couldNotOpen = true
            }
        }
    }
}


struct IncomeOverviewView: View {
    let model: IncomeViewModel
    let mayCreate: Bool
    @Binding var selectedDay: InvoiceDate?
    let retry: () async -> Void
    var openCloseout: (() -> Void)? = nil
    let openEntry: (IncomeJournalKind, InvoiceIncomeStatement) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var attemptedEntry = false
    @State private var showsDatePicker = false

    /// Renders the daily balance, available actions, and posted or queued transactions.
    var body: some View {
        List {
            Section {
                summary(model)
                    .listRowBackground(AppStyle.Colors.accent.opacity(0.09))
            }
            if let issue = model.issue {
                MessagePanel(message: LocalizedStringKey(issue), icon: "exclamationmark.triangle",
                             actionTitle: "auth.retry", action: { Task { await retry() } })
                    .listRowBackground(Color.clear)
            } else if attemptedEntry && mayCreate && !model.canCreate {
                MessagePanel(message: "income.openPeriodRequired", icon: "calendar.badge.exclamationmark")
                    .listRowBackground(Color.clear)
            }
            // Opening a closeout requires its own grant, independent of journal entry permissions.
            if let openCloseout {
                Button("invoiceCreation.closeout.open", systemImage: "calendar.badge.plus", action: openCloseout)
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
            }
            if mayCreate {
                entryTiles.listRowBackground(Color.clear)
            }
            if model.isShowingDownloaded && !model.isLoading {
                Label("income.downloaded", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(.secondary)
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
        .onChange(of: model.canCreate) {
            if model.canCreate { attemptedEntry = false }
        }
        .onChange(of: selectedDay) { attemptedEntry = false }
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

    private var entryTiles: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            ForEach(IncomeJournalKind.allCases) { kind in
                Button {
                    if model.canCreate, let statement = model.period?.statement {
                        openEntry(kind, statement)
                    } else {
                        attemptedEntry = true
                    }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: kind == .sale ? "arrow.down.left.circle" : "arrow.up.right.circle")
                            .font(.title2)
                            .foregroundStyle(AppStyle.Colors.accent)
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(kind == .sale ? "income.otherIncomeAction" : "income.expenseAction"))
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .background(AppStyle.Colors.accent.opacity(0.07), in: .rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(AppStyle.Colors.accent.opacity(0.22))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isLoading && model.period == nil)
            }
        }
    }

    private func summary(_ model: IncomeViewModel) -> some View {
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

    private func total(_ model: IncomeViewModel, kind: IncomeJournalKind, currency: String) -> some View {
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
