import Foundation

/// Frozen review context. Neither retry stage reads a mutable editor form.
nonisolated struct InvoiceCreationPlan: Codable, Sendable {
    enum PlanError: Error { case incomplete, changedReview, invalidReceipt, tooLarge }
    let invoiceRequestID: UUID
    let journalRequestID: UUID
    let content: InvoiceDraft.Content
    let branch: AuthenticatedUser.Branch

    init(content: InvoiceDraft.Content, branch: AuthenticatedUser.Branch,
         invoiceRequestID: UUID = UUID(), journalRequestID: UUID = UUID()) throws {
        self.content = content
        self.branch = branch
        self.invoiceRequestID = invoiceRequestID
        self.journalRequestID = journalRequestID
        _ = try validated()
    }

    var requiresJournal: Bool { ((try? validated().totals.payment) ?? 0) > 0 }

    private func validated() throws -> (amounts: InvoiceDraftAmounts, totals: InvoiceDraftPayment.Totals) {
        guard branch.id > 0, content.date.pickerDate != nil, content.pickup?.id != 0,
              let sender = content.senderCustomer, let senderWrite = content.senderWriteSnapshot,
              senderWrite.matches(sender), content.senderName == sender.name,
              let payment = content.payment,
              content.paymentRegion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let policies = content.policies else { throw PlanError.incomplete }
        _ = try senderWrite.party(addressID: content.senderAddressID)
        if let receiver = content.receiverCustomer {
            guard let snapshot = content.receiverWriteSnapshot, snapshot.matches(receiver), content.receiverName == receiver.name else { throw PlanError.incomplete }
            _ = try snapshot.party(addressID: content.receiverAddressID)
        } else if !content.receiverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PlanError.incomplete
        }
        let amounts = try InvoiceDraftAmounts(items: content.items)
        guard payment.validationIssue(subtotal: amounts.subtotal) == nil,
              let totals = payment.totals(subtotal: amounts.subtotal) else { throw PlanError.incomplete }
        let confirmation = content.confirmation
        if !policies.isEmpty || confirmation?.skipSignature == false {
            guard let confirmation, confirmation.isValid, confirmation.matches(content),
                  policies.isEmpty || confirmation.policiesAgreed,
                  confirmation.skipSignature || (content.senderSignature?.isValid == true
                      && content.senderSignature?.signerName == content.senderName) else { throw PlanError.changedReview }
        }
        return (amounts, totals)
    }

    func journalRequest() throws -> Data? {
        let checked = try validated()
        guard checked.totals.payment > 0, let payment = content.payment,
              let method = payment.method else { return nil }
        guard checked.amounts.subtotal > 0 else { throw PlanError.incomplete }
        let entry = JournalEntry(branch: branch, transactionType: "INITIAL-PAYMENT", amount: checked.totals.payment,
            description: payment.description,
            invoice: JournalInvoice(autoGenerateNumber: true, cost: checked.amounts.subtotal, discount: checked.totals.discount),
            sender: try content.senderWriteSnapshot?.party(addressID: content.senderAddressID),
            receiver: try content.receiverWriteSnapshot?.party(addressID: content.receiverAddressID),
            paymentMethod: Method(id: method.lookupID, name: method.rawValue),
            paymentAccount: method.requiresBankAccount ? payment.bankAccount : nil,
            paymentReference: method == .check ? payment.checkNumber.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            externalReferenceNumber: method == .check ? nil : payment.externalReference,
            employee: employee, vehicleRoute: route)
        return try encode(Envelope(requestId: journalRequestID.uuidString.lowercased(), entry: entry))
    }

    func invoiceRequest(receipt: InvoiceInitialPaymentReceipt? = nil) throws -> Data {
        let checked = try validated()
        let number: String?
        let paid: Double
        if checked.totals.payment > 0 {
            guard let receipt, InvoiceWriteDocument.isObjectID(receipt.id),
                  receipt.transactionType == "INITIAL-PAYMENT",
                  receipt.transactionAmount.isFinite,
                  abs(receipt.transactionAmount - checked.totals.payment) < 0.005,
                  InvoiceWriteDocument.isObjectID(receipt.invoice.id), !receipt.invoice.number.isEmpty,
                  receipt.invoice.cost.isFinite, abs(receipt.invoice.cost - checked.amounts.subtotal) < 0.005,
                  receipt.incomeStatement.id > 0 else { throw PlanError.invalidReceipt }
            number = receipt.invoice.number
            paid = receipt.invoice.payment ?? 0
        } else {
            guard receipt == nil else { throw PlanError.invalidReceipt }
            number = nil
            paid = 0
        }
        let balance = ((checked.amounts.subtotal - checked.totals.discount - paid) * 100).rounded() / 100
        guard paid.isFinite, paid >= 0, balance.isFinite, balance >= 0 else { throw PlanError.invalidReceipt }
        let items = try content.items.map { item -> Detail in
            guard let quantity = Double(item.quantity.trimmingCharacters(in: .whitespacesAndNewlines)), let price = Double(item.unitPrice.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let total = checked.amounts.lineTotals[item.id],
                  let labels = item.labelCount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? UInt8(exactly: quantity) : UInt8(item.labelCount.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw PlanError.incomplete }
            return Detail(name: item.name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: item.name.trimmingCharacters(in: .whitespacesAndNewlines), quantity: quantity,
                labels: labels, price: (price * 100).rounded() / 100, total: total)
        }
        let signature: InvoiceSenderSignature?
        if let confirmation = content.confirmation, confirmation.matches(content), !confirmation.skipSignature {
            signature = content.senderSignature
        } else { signature = nil }
        let request = InvoiceRequest(autoGenerateNumber: number == nil, number: number, date: content.date.apiValue,
            paidRegion: normalizedRegion, branch: branch, incomeStatement: receipt.map { Statement(id: $0.incomeStatement.id) },
            cost: checked.amounts.subtotal, discount: checked.totals.discount, payment: paid, balance: balance,
            container: content.container, sender: try content.senderWriteSnapshot?.party(addressID: content.senderAddressID),
            receiver: try content.receiverWriteSnapshot?.party(addressID: content.receiverAddressID),
            invoiceDetails: items, pickupSource: content.pickupSource?.rawValue, receivedBy: receivedBy,
            route: route?.route, pickupEmployee: employee, officeBranch: content.pickupSource == .office ? content.pickupEmployee?.branch : nil,
            senderSignature: signature, pickup: content.pickup)
        return try encode(InvoiceEnvelope(requestId: invoiceRequestID.uuidString.lowercased(), invoice: request))
    }

    private var normalizedRegion: String {
        let code = content.paymentRegion?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        switch code { case "US", "USA": return "NY"; case "DR", "DO": return "RD"; default: return code }
    }
    private var employee: Employee? {
        content.pickupEmployee.map { Employee(id: $0.id, name: $0.name) }
    }
    private var route: DailyRoute? {
        content.pickupRoute.map { DailyRoute(id: $0.id, name: $0.displayName, route: $0.route) }
    }
    private var receivedBy: ReceivedBy? {
        if let route { return ReceivedBy(type: "route", id: route.id, name: route.name, route: route.route, employee: nil) }
        guard let employee else { return nil }
        return ReceivedBy(type: "employee", id: String(employee.id), name: employee.name ?? "", route: nil, employee: employee)
    }
    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        guard payload.count <= 3 * 1024 * 1024 else { throw PlanError.tooLarge }
        return payload
    }

    private struct Envelope: Encodable {
        let requestId: String
        let entry: JournalEntry
    }
    private struct InvoiceEnvelope: Encodable {
        let requestId: String
        let invoice: InvoiceRequest
    }
    private struct Statement: Encodable {
        let id: UInt32
    }
    private struct Method: Encodable {
        let id: UInt16
        let name: String
    }
    private struct Employee: Encodable {
        let id: UInt16
        let name: String?
    }
    private struct DailyRoute: Encodable {
        let id: String
        let name: String
        let route: InvoicePickupRoute.Crew?
    }
    private struct ReceivedBy: Encodable {
        let type: String
        let id: String
        let name: String
        let route: InvoicePickupRoute.Crew?
        let employee: Employee?
    }
    private struct Detail: Encodable {
        let name: String
        let description: String
        let quantity: Double
        let labels: UInt8
        let price: Double
        let total: Double
    }
    private struct JournalInvoice: Encodable {
        let autoGenerateNumber: Bool
        let cost: Double
        let discount: Double
    }
    private struct JournalEntry: Encodable {
        let branch: AuthenticatedUser.Branch
        let transactionType: String
        let amount: Double
        let description: String
        let invoice: JournalInvoice
        let sender: InvoiceCustomerWriteSnapshot.Party?
        let receiver: InvoiceCustomerWriteSnapshot.Party?
        let paymentMethod: Method
        let paymentAccount: InvoiceBankAccount?
        let paymentReference: String?
        let externalReferenceNumber: String?
        let employee: Employee?
        let vehicleRoute: DailyRoute?
    }
    private struct InvoiceRequest: Encodable {
        let autoGenerateNumber: Bool
        let number: String?
        let date: String
        let paidRegion: String
        let branch: AuthenticatedUser.Branch
        let incomeStatement: Statement?
        let cost: Double
        let discount: Double
        let payment: Double
        let balance: Double
        let container: InvoiceContainer?
        let sender: InvoiceCustomerWriteSnapshot.Party?
        let receiver: InvoiceCustomerWriteSnapshot.Party?
        let invoiceDetails: [Detail]
        let pickupSource: String?
        let receivedBy: ReceivedBy?
        let route: InvoicePickupRoute.Crew?
        let pickupEmployee: Employee?
        let officeBranch: InvoicePickupBranch?
        let senderSignature: InvoiceSenderSignature?
        let pickup: InvoicePickupReference?
    }
}
