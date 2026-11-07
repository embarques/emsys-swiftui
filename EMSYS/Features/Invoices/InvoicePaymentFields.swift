import SwiftUI

struct InvoicePaymentFields: View {
    @Environment(\.locale) private var locale
    @Environment(NetworkConnection.self) private var connection
    @Bindable var model: InvoiceDraftEditorModel

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.content.payment?.mode == .record },
                set: { model.setPaymentMode($0 ? .record : .skip) }
            )) {
                VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    Text("invoicePayment.recordShort")
                    Text(model.content.payment?.mode == .record ? "invoicePayment.yes" : "invoicePayment.no")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .toggleStyle(.switch)
            .disabled(model.isSaving || (!model.canRecordPayment && model.content.payment?.mode != .record))

            if model.content.payment?.mode == .record {
                amountEntry
                    .disabled(!model.canRecordPayment || model.isSaving)
                Picker("invoicePayment.method", selection: Binding(
                    get: { model.content.payment?.method },
                    set: { model.setPaymentMethod($0) }
                )) {
                    if model.content.payment?.method == nil {
                        Text("invoicePayment.methodRequired").tag(nil as InvoiceDraftPayment.Method?)
                    }
                    ForEach(InvoiceDraftPayment.Method.allCases) { method in
                        Label(LocalizedStringKey(method.title), systemImage: method.symbol).tag(Optional(method))
                    }
                }
                .pickerStyle(.menu)
                .disabled(!model.canRecordPayment || model.isSaving)
            }
        }
        if model.content.payment?.mode == .record {
            if model.content.payment?.method != nil {
                Section("invoicePayment.details") {
                    paymentDetails
                }
                .disabled(!model.canRecordPayment || model.isSaving)
            }
            if !model.canRecordPayment {
                Section {
                    Text("invoicePayment.permissionRequired").foregroundStyle(.secondary)
                }
            }
        }
        Section {
            if model.canApplyDiscount {
                LabeledContent("invoicePayment.discount") {
                    moneyField("invoicePayment.discount", value: paymentBinding(\.discount, fallback: "0"))
                }
            } else if let discount = model.content.payment?.discount, discount != "0" {
                LabeledContent("invoicePayment.discount", value: discount)
            }
            if let totals = model.paymentTotals {
                LabeledContent("invoicePayment.plannedPayment") {
                    Text(totals.payment, format: .number.precision(.fractionLength(2))).monospacedDigit()
                }
                LabeledContent("invoicePayment.plannedBalance") {
                    Text(totals.balance, format: .number.precision(.fractionLength(2))).bold().monospacedDigit()
                }
            }
        } footer: {
            Text("invoicePayment.localHint")
        }
    }

    private var amountEntry: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            Text("invoicePayment.amount").font(.subheadline).foregroundStyle(.secondary)
            TextField("invoicePayment.amount", text: paymentBinding(\.amount, fallback: ""),
                      prompt: Text(verbatim: 0.formatted(.number.precision(.fractionLength(2)).locale(locale))))
                .textFieldStyle(.plain)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, AppStyle.Spacing.medium)
                .frame(minHeight: 44)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
                .accessibilityLabel(Text("invoicePayment.amount"))
        }
        .padding(.vertical, AppStyle.Spacing.small)
    }

    @ViewBuilder
    private var paymentDetails: some View {
        if model.content.payment?.method?.requiresBankAccount == true {
            if model.canChooseBankAccount {
                Picker("invoicePayment.bank", selection: Binding(
                    get: { model.content.payment?.bankAccount?.id }, set: { model.selectBankAccount(id: $0) }
                )) {
                    Text("invoicePayment.bankRequired").tag(nil as UInt32?)
                    if let saved = model.content.payment?.bankAccount,
                       !model.bankAccounts.contains(where: { $0.id == saved.id }) {
                        Text(saved.title).tag(Optional(saved.id))
                    }
                    ForEach(model.bankAccounts) { account in Text(account.title).tag(Optional(account.id)) }
                }
                Button {
                    Task { await model.loadBankAccounts(online: connection.status != .unavailable) }
                } label: {
                    Label("invoices.refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoadingBankAccounts)
            } else if let account = model.content.payment?.bankAccount {
                LabeledContent("invoicePayment.bank", value: account.title)
            }
            if model.isLoadingBankAccounts { ProgressView() }
            if let issue = model.bankAccountIssue { Text(LocalizedStringKey(issue)).foregroundStyle(.secondary) }
        }
        if model.content.payment?.method == .check {
            referenceField("invoicePayment.checkNumber", value: paymentBinding(\.checkNumber, fallback: ""))
        } else {
            referenceField("invoicePayment.externalReference", value: paymentBinding(\.externalReference, fallback: ""))
        }
        referenceField("invoicePayment.description", value: paymentBinding(\.description, fallback: ""))
    }

    private func referenceField(_ title: LocalizedStringKey, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(title, text: value, axis: .vertical)
                .accessibilityLabel(Text(title))
        }
        .padding(.vertical, 4)
    }

    private func paymentBinding(_ path: WritableKeyPath<InvoiceDraftPayment, String>, fallback: String) -> Binding<String> {
        Binding(get: { model.content.payment?[keyPath: path] ?? fallback }, set: { value in
            guard model.isAvailable, !model.isSaving else { return }
            var payment = model.content.payment ?? InvoiceDraftPayment(mode: .skip)
            payment[keyPath: path] = value
            model.content.payment = payment
        })
    }

    private func moneyField(_ title: LocalizedStringKey, value: Binding<String>) -> some View {
        TextField(title, text: value)
            .multilineTextAlignment(.trailing)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
    }
}
