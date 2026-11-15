import Foundation

/// Frozen review context. Neither retry stage reads a mutable editor form.
nonisolated struct InvoiceCreationPlan: Codable, Sendable {
    enum PlanError: Error { case incomplete, changedReview, invalidReceipt, tooLarge }
    let invoiceRequestID: UUID
    let journalRequestID: UUID
    let content: InvoiceDraft.Content
    let reservation: InvoiceReservation?
    let branch: AuthenticatedUser.Branch

    /// Freezes the draft and validates it before assigning any durable request bytes.
    init(content: InvoiceDraft.Content, branch: AuthenticatedUser.Branch,
         invoiceRequestID: UUID = UUID(), journalRequestID: UUID = UUID(), reservation: InvoiceReservation? = nil) throws {
        self.reservation = reservation
        self.content = content
        self.branch = branch
        self.invoiceRequestID = invoiceRequestID
        self.journalRequestID = journalRequestID
        _ = try validated()
    }

    /// Returns the same plan and request identities with the chosen reservation.
    func reserving(_ reservation: InvoiceReservation) throws -> InvoiceCreationPlan {
        try InvoiceCreationPlan(content: content, branch: branch, invoiceRequestID: invoiceRequestID,
            journalRequestID: journalRequestID, reservation: reservation)
    }

    /// Checks whether the frozen submission has an initial payment.
    var requiresJournal: Bool { ((try? validated().totals.payment) ?? 0) > 0 }

    /// Checks that all required invoice data still matches the frozen review.
    private func validated() throws -> (amounts: InvoiceDraftAmounts, totals: InvoiceDraftPayment.Totals) {
        guard content.assignedPickup?.matches(content) != false, branch.id > 0, content.date.pickerDate != nil, content.pickup?.id != 0,
              let sender = content.senderCustomer, let senderWrite = content.senderWriteSnapshot,
              senderWrite.matches(sender), content.senderName == sender.name,
              let payment = content.payment,
              content.paymentRegion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let policies = content.policies else {
            throw PlanError.incomplete
        }
        _ = try senderWrite.party(addressID: content.senderAddressID)
        if let receiver = content.receiverCustomer {
            guard let snapshot = content.receiverWriteSnapshot, snapshot.matches(receiver), content.receiverName == receiver.name else {
                throw PlanError.incomplete
            }
            _ = try snapshot.party(addressID: content.receiverAddressID)
        } else if !content.receiverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PlanError.incomplete
        }
        // Recalculate amounts from the frozen draft before building either request.
        let amounts = try InvoiceDraftAmounts(items: content.items)
        guard payment.validationIssue(subtotal: amounts.subtotal) == nil,
              let totals = payment.totals(subtotal: amounts.subtotal) else {
            throw PlanError.incomplete
        }
        // Agreement and signature are valid only for the same reviewed draft.
        let confirmation = content.confirmation
        if !policies.isEmpty || confirmation?.skipSignature == false {
            guard let confirmation, confirmation.isValid, confirmation.matches(content),
                  policies.isEmpty || confirmation.policiesAgreed,
                  confirmation.skipSignature || (content.senderSignature?.isValid == true
                      && content.senderSignature?.signerName == content.senderName) else {
                throw PlanError.changedReview
            }
        }
        return (amounts, totals)
    }

    /// Encodes the initial payment request if this plan includes a payment.
    func journalRequest() throws -> Data? {
        let checked = try validated()
        guard checked.totals.payment > 0, let payment = content.payment,
              let method = payment.method else {
            return nil
        }
        guard checked.amounts.subtotal > 0 else {
            throw PlanError.incomplete
        }
        let entry = JournalEntry(branch: branch, transactionType: "INITIAL-PAYMENT", amount: checked.totals.payment,
            description: payment.description,
            invoice: JournalInvoice(autoGenerateNumber: reservation == nil, number: reservation?.number, reservation: reservation?.proof, cost: checked.amounts.subtotal, discount: checked.totals.discount),
            sender: try content.senderWriteSnapshot?.party(addressID: content.senderAddressID),
            receiver: try content.receiverWriteSnapshot?.party(addressID: content.receiverAddressID),
            paymentMethod: Method(id: method.lookupID, name: method.rawValue),
            paymentAccount: method.requiresBankAccount ? payment.bankAccount : nil,
            paymentReference: method == .check ? payment.checkNumber.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            externalReferenceNumber: method == .check ? nil : payment.externalReference,
            employee: employee, vehicleRoute: route)
        return try encode(Envelope(requestId: journalRequestID.uuidString.lowercased(), entry: entry))
    }

    /// Encodes the invoice request using the verified receipt when required.
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
                  receipt.incomeStatement.id > 0 else {
                throw PlanError.invalidReceipt
            }
            // A payment receipt can finalize only the exact number reserved for this draft.
            if let reservation {
                guard receipt.invoice.id == reservation.id, receipt.invoice.number == reservation.number else {
                    throw PlanError.invalidReceipt
                }
            }
            number = receipt.invoice.number
            paid = receipt.invoice.payment ?? 0
        } else {
            guard receipt == nil else {
                throw PlanError.invalidReceipt
            }
            number = reservation?.number
            paid = 0
        }
        let balance = ((checked.amounts.subtotal - checked.totals.discount - paid) * 100).rounded() / 100
        guard paid.isFinite, paid >= 0, balance.isFinite, balance >= 0 else {
            throw PlanError.invalidReceipt
        }
        // Serialize each item using the independently validated totals.
        let items = try content.items.map { item in
            try invoiceDetail(for: item, amounts: checked.amounts)
        }
        let signature: InvoiceSenderSignature?
        if let confirmation = content.confirmation, confirmation.matches(content), !confirmation.skipSignature {
            signature = content.senderSignature
        } else {
            signature = nil
        }
        let request = InvoiceRequest(autoGenerateNumber: number == nil, reservation: receipt == nil ? reservation?.proof : nil, number: number, date: content.date.apiValue,
            paidRegion: normalizedRegion, branch: branch, incomeStatement: receipt.map { Statement(id: $0.incomeStatement.id) },
            cost: checked.amounts.subtotal, discount: checked.totals.discount, payment: paid, balance: balance,
            container: content.container, sender: try content.senderWriteSnapshot?.party(addressID: content.senderAddressID),
            receiver: try content.receiverWriteSnapshot?.party(addressID: content.receiverAddressID),
            invoiceDetails: items, pickupSource: content.pickupSource?.rawValue, receivedBy: receivedBy,
            route: route?.route, pickupEmployee: employee, officeBranch: content.pickupSource == .office ? content.pickupEmployee?.branch : nil,
            senderSignature: signature, pickup: content.pickup)
        return try encode(InvoiceEnvelope(requestId: invoiceRequestID.uuidString.lowercased(), invoice: request))
    }

    /// Builds the invoice API row using the reviewed quantity, price, and labels.
    private func invoiceDetail(for item: InvoiceDraft.Item, amounts: InvoiceDraftAmounts) throws -> Detail {
        // Parse the same values validated by the draft and use the frozen line total.
        let quantityText = item.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let priceText = item.unitPrice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quantity = Double(quantityText), let price = Double(priceText),
              let total = amounts.lineTotals[item.id] else {
            throw PlanError.incomplete
        }

        // Serialize the same label count accepted by the item validation.
        guard let labelCount = item.resolvedLabelCount(quantity: quantity) else {
            throw PlanError.incomplete
        }

        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let roundedPrice = (price * 100).rounded() / 100
        return Detail(name: name, description: name, quantity: quantity,
            labels: labelCount, price: roundedPrice, total: total)
    }

    /// Returns a payment region code accepted by the API.
    private var normalizedRegion: String {
        let code = content.paymentRegion?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        // Normalize aliases to the region codes expected by the invoice API.
        switch code {
        case "US", "USA":
            return "NY"
        case "DR", "DO":
            return "RD"
        default:
            return code
        }
    }
    /// Builds the employee reference included in invoice and journal requests.
    private var employee: Employee? {
        content.pickupEmployee.map { Employee(id: $0.id, name: $0.name) }
    }
    /// Builds the daily route reference required by the API.
    private var route: DailyRoute? {
        content.pickupRoute.map { DailyRoute(id: $0.id, name: $0.displayName, route: $0.route) }
    }
    /// Returns the field identifying who received the shipment.
    private var receivedBy: ReceivedBy? {
        // A route assignment takes precedence over an employee reference.
        if let route {
            return ReceivedBy(type: "route", id: route.id, name: route.name, route: route.route, employee: nil)
        }
        guard let employee else {
            return nil
        }
        return ReceivedBy(type: "employee", id: String(employee.id), name: employee.name ?? "", route: nil, employee: employee)
    }
    /// Serializes stable request bytes and enforces the payload size limit.
    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        guard payload.count <= 3 * 1024 * 1024 else {
            throw PlanError.tooLarge
        }
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
        let number: String?
        let reservation: InvoiceReservationProof?
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
        let reservation: InvoiceReservationProof?
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

/// Only server-confirmed registration fields; no inferred settlement status.
nonisolated struct InvoiceInitialPaymentReceipt: Codable, Sendable {
    struct InvoiceReference: Codable, Sendable {
        let id: String
        let number: String
        let cost: Double
        let payment: Double?
        let balance: Double?
    }
    struct Statement: Codable, Sendable { let id: UInt32 }
    let id: String
    let transactionType: String
    let transactionAmount: Double
    let invoice: InvoiceReference
    let incomeStatement: Statement
}
