import SwiftUI

struct IncomeCloseoutSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let branch: AuthenticatedUser.Branch
    var resumesInvoice = false
    let submit: (String, Double) async throws -> Void
    @State private var currency = "USD"
    @State private var rate = ""
    @State private var isSubmitting = false
    @State private var serverMessage: String?
    @State private var failed = false

    /// Identifies branches that may choose a currency and exchange rate.
    private var needsCurrency: Bool {
        ["RD", "DR", "DO"].contains(branch.code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "")
    }

    /// Validates the exchange rate using the active locale.
    private var exchangeRate: Double? {
        // USD uses the server contract rate of one.
        if currency == "USD" {
            return 1
        }
        guard let value = try? Double(rate, format: .number.locale(locale)), value.isFinite, value > 0 else {
            return nil
        }
        return value
    }

    /// Presents the branch setup and keeps the form open for a failed request.
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(branch.name ?? branch.code ?? "")
                    if needsCurrency {
                        Picker("invoiceCreation.closeout.currency", selection: $currency) {
                            Text(verbatim: "USD").tag("USD")
                            Text(verbatim: "DOP").tag("DOP")
                        }
                        if currency == "DOP" {
                            TextField("invoiceCreation.closeout.rate", text: $rate)
                            #if os(iOS)
                                .keyboardType(.decimalPad)
                            #endif
                        }
                    } else {
                        LabeledContent("invoiceCreation.closeout.currency", value: "USD")
                        LabeledContent("invoiceCreation.closeout.rate", value: "1")
                    }
                } footer: {
                    // Only blocked invoice recovery retries a saved operation.
                    if resumesInvoice {
                        Text("invoiceCreation.closeout.resume")
                    }
                }
                if let serverMessage {
                    Text(verbatim: serverMessage).foregroundStyle(.red)
                } else if failed {
                    Text("invoiceCreation.closeout.failed").foregroundStyle(.red)
                }
                Button("invoiceCreation.closeout.open") {
                    // Only submit a validated amount once while the server request is active.
                    guard let exchangeRate, !isSubmitting else {
                        return
                    }
                    isSubmitting = true
                    serverMessage = nil
                    failed = false
                    Task {
                        defer {
                            isSubmitting = false
                        }
                        do {
                            try await submit(currency, exchangeRate)
                            dismiss()
                        } catch let error as APIServerFailure {
                            // Keep the current setup on screen when the API lets the user retry.
                            serverMessage = error.message
                            failed = true
                        } catch {
                            failed = true
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(exchangeRate == nil || isSubmitting)
            }
            .formStyle(.grouped)
            .navigationTitle("invoiceCreation.closeout.open")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("invoiceEdits.cancel") { dismiss() }.disabled(isSubmitting)
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 340)
        #endif
    }
}
