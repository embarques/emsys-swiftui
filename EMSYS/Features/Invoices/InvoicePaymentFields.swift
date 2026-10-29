import SwiftUI

struct InvoicePaymentFields: View {
    @Environment(NetworkConnection.self) private var connection
    @Bindable var model: InvoiceDraftEditorModel

    var body: some View {
        Section("invoicePayment.title") {
            Picker("invoicePayment.mode", selection: Binding(
                get: { model.content.payment?.mode },
                set: { if let mode = $0 { model.setPaymentMode(mode) } }
            )) {
                Text("invoicePayment.chooseMode").tag(nil as InvoiceDraftPayment.Mode?)
                Text("invoicePayment.skip").tag(Optional(InvoiceDraftPayment.Mode.skip))
                if model.canRecordPayment || model.content.payment?.mode == .record {
                    Text("invoicePayment.record").tag(Optional(InvoiceDraftPayment.Mode.record))
                }
            }
            if model.canApplyDiscount {
                LabeledContent("invoicePayment.discount") {
                    moneyField("invoicePayment.discount", value: paymentBinding(\.discount, fallback: "0"))
                }
            } else if let discount = model.content.payment?.discount, discount != "0" {
                LabeledContent("invoicePayment.discount", value: discount)
            }
            if model.content.payment?.mode == .record {
                paymentDetails.disabled(!model.canRecordPayment)
                if !model.canRecordPayment { Text("invoicePayment.permissionRequired").foregroundStyle(.secondary) }
            }
            if let totals = model.paymentTotals {
                LabeledContent("invoicePayment.plannedPayment") {
                    Text(totals.payment, format: .number.precision(.fractionLength(2))).monospacedDigit()
                }
                LabeledContent("invoicePayment.plannedBalance") {
                    Text(totals.balance, format: .number.precision(.fractionLength(2))).bold().monospacedDigit()
                }
            }
            Text("invoicePayment.localHint").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var paymentDetails: some View {
        LabeledContent("invoicePayment.amount") {
            moneyField("invoicePayment.amount", value: paymentBinding(\.amount, fallback: ""))
        }
        Picker("invoicePayment.method", selection: Binding(
            get: { model.content.payment?.method }, set: { model.setPaymentMethod($0) }
        )) {
            Text("invoicePayment.methodRequired").tag(nil as InvoiceDraftPayment.Method?)
            ForEach(InvoiceDraftPayment.Method.allCases) { method in
                Text(LocalizedStringKey(method.title)).tag(Optional(method))
            }
        }
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
                Button("invoices.refresh") {
                    Task { await model.loadBankAccounts(online: connection.status != .unavailable) }
                }
                .disabled(model.isLoadingBankAccounts)
            } else if let account = model.content.payment?.bankAccount {
                LabeledContent("invoicePayment.bank", value: account.title)
            }
            if model.isLoadingBankAccounts { ProgressView() }
            if let issue = model.bankAccountIssue { Text(LocalizedStringKey(issue)).foregroundStyle(.secondary) }
        }
        if model.content.payment?.method == .check {
            TextField("invoicePayment.checkNumber", text: paymentBinding(\.checkNumber, fallback: ""))
        } else {
            TextField("invoicePayment.externalReference", text: paymentBinding(\.externalReference, fallback: ""))
        }
        TextField("invoicePayment.description", text: paymentBinding(\.description, fallback: ""), axis: .vertical)
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
