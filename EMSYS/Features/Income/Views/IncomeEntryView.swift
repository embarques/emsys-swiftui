import SwiftUI

struct IncomeEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var amountFocused: Bool
    @State private var draft: IncomeJournalDraft
    @State private var isSaving = false
    @State private var saveFailed = false
    @State private var showsCategories = false
    let model: IncomeViewModel
    let statementID: UInt32
    let didSave: () -> Void

    init(model: IncomeViewModel, kind: IncomeJournalKind, statementID: UInt32, didSave: @escaping () -> Void) {
        self.model = model
        self.statementID = statementID
        self.didSave = didSave
        _draft = State(initialValue: .init(kind: kind))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("invoicePayment.amount").font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            if let currency = model.currency {
                                Text(verbatim: currency).font(.headline)
                            }
                            TextField("invoicePayment.amount", text: $draft.amount, prompt: Text("0.00"))
                                .focused($amountFocused)
                                .multilineTextAlignment(.trailing)
                                .font(.largeTitle.weight(.semibold)).monospacedDigit()
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                        }
                    }
                    .padding(12)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(amountFocused ? AppStyle.Colors.accent : Color.secondary.opacity(0.25),
                                          lineWidth: amountFocused ? 2 : 1)
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    Button {
                        amountFocused = false
                        showsCategories = true
                    } label: {
                        LabeledContent("income.category") {
                            let selected = categoryAccounts.first { $0.id == draft.accountID }
                            HStack {
                                if let selected { Text(verbatim: selected.title) }
                                else { Text("income.selectCategory") }
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    Picker("invoicePayment.method", selection: $draft.method) {
                        ForEach(IncomePaymentMethod.allCases) { method in
                            Label(LocalizedStringKey(method.title), systemImage: method.symbol).tag(method)
                        }
                    }
                    if draft.kind.allowsFunding(draft.method) {
                        Picker(draft.kind == .expense ? "income.sourceAccount" : "income.destinationAccount",
                               selection: $draft.fundingID) {
                            Text(LocalizedStringKey(defaultFundingTitle)).tag(nil as UInt32?)
                            ForEach(fundingAccounts) { account in
                                Text(verbatim: account.title).tag(Optional(account.id))
                            }
                        }
                    }
                    if draft.method == .check {
                        TextField("invoicePayment.checkNumber", text: $draft.paymentReference)
                    }
                    TextField("income.description", text: $draft.description, axis: .vertical)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(LocalizedStringKey(draft.kind.entryTitle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("invoiceEdits.cancel") { dismiss() }.disabled(isSaving)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    Task { await save() }
                } label: {
                    Text(LocalizedStringKey(draft.kind.saveTitle)).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || model.period?.statement?.id != statementID || !model.canSave(draft))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
            }
            .sheet(isPresented: $showsCategories) {
                IncomeCategoryPicker(accounts: categoryAccounts, kind: draft.kind, selectedID: draft.accountID) { id in
                    draft.accountID = id
                    showsCategories = false
                }
            }
            .alert("income.saveError", isPresented: $saveFailed) {
                Button("documents.close", role: .cancel) { }
            }
            .interactiveDismissDisabled(isSaving || !draft.amount.isEmpty || !draft.description.isEmpty)
            .onChange(of: draft.method) { draft.fundingID = nil; draft.paymentReference = "" }
            .task {
                #if os(iOS)
                amountFocused = UIDevice.current.userInterfaceIdiom == .phone
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 500)
        #endif
    }

    private var categoryAccounts: [IncomeAccount] {
        model.accounts.filter(draft.categoryAllows)
    }

    private var fundingAccounts: [IncomeAccount] {
        model.accounts.filter { $0.isFunding(for: draft.method, in: model.accounts) }
    }

    private var defaultFundingTitle: String {
        if draft.method == .cash { return "income.cashOnHand" }
        return draft.kind.requiresFunding(draft.method) ? "income.selectAccount" : "income.checksToDeposit"
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.save(draft, for: statementID)
            didSave()
            dismiss()
        } catch { saveFailed = true }
    }
}
