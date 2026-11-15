import Foundation

/// Data changes shared by the invoice form and its saved draft.
extension InvoiceDraft.Content {
    /// Applies the default payment mode and location to fields that are still unset.
    mutating func applyPaymentDefaults(canRecordPayment: Bool, defaultRegion: String?) {
        // Start eligible users in cash payment mode and preserve previously entered details.
        if payment == nil {
            if canRecordPayment {
                payment = .init(mode: .record, method: .cash)
            } else {
                payment = .init(mode: .skip)
            }
        } else if payment?.mode == .record, payment?.method == nil, canRecordPayment {
            payment?.method = .cash
        }

        // Use the user's branch only when a payment region has not already been supplied.
        let existingRegion = paymentRegion?.trimmingCharacters(in: .whitespacesAndNewlines)
        if existingRegion?.isEmpty != false, let defaultRegion, !defaultRegion.isEmpty {
            paymentRegion = defaultRegion
        }
    }

    /// Changes whether a payment will be recorded without discarding its saved fields.
    mutating func setPaymentMode(_ mode: InvoiceDraftPayment.Mode) {
        // A draft with no selected method starts with cash when recording is enabled.
        var updatedPayment = payment ?? InvoiceDraftPayment(mode: mode)
        updatedPayment.mode = mode
        if mode == .record, updatedPayment.method == nil {
            updatedPayment.method = .cash
        }
        payment = updatedPayment
    }

    /// Changes the payment method and clears details that only apply to the previous one.
    mutating func setPaymentMethod(_ method: InvoiceDraftPayment.Method?) {
        // Reselecting the same method preserves its existing details.
        guard payment?.method != method else {
            return
        }
        payment?.method = method
        payment?.bankAccount = nil
        payment?.checkNumber = ""
        payment?.externalReference = ""
    }

    /// Validates a write snapshot against the selected customer's identity and role.
    func matchesCustomerDetails(_ snapshot: InvoiceCustomerWriteSnapshot, customer: InvoiceCustomer) -> Bool {
        // Pickup parties are historical snapshots and may keep an older display name.
        if pickup != nil {
            return snapshot.isValid && snapshot.id == customer.id && snapshot.customerType == customer.customerType
        }
        return snapshot.matches(customer)
    }

    /// Applies a current snapshot and returns whether the saved address needs replacement.
    mutating func applyCustomerDetails(
        _ snapshot: InvoiceCustomerWriteSnapshot,
        matching customer: InvoiceCustomer,
        role: InvoiceCustomer.Role
    ) -> Bool {
        let selected = role == .sender ? senderCustomer : receiverCustomer

        // Ignore a response for a customer the user has already replaced.
        guard selected?.id == customer.id, selected?.name == customer.name else {
            return false
        }
        var addressID = role == .sender ? senderAddressID : receiverAddressID

        // A search result can omit addresses, so default only if no address was selected.
        if addressID == nil, selected?.addresses?.isEmpty != false {
            let firstAddress = snapshot.addresses?.first { InvoiceWriteDocument.isObjectID($0.id ?? "") }
            addressID = firstAddress?.id
        }
        let addressExists = addressID == nil || snapshot.addresses?.contains { $0.id == addressID } == true
        let refreshed = snapshot.publicCustomer(active: selected?.active)
        let address = addressExists ? addressID : nil
        let writeSnapshot = addressExists ? snapshot : nil

        // Update only the requested party and clear a stale address alongside its write data.
        switch role {
        case .sender:
            senderCustomer = refreshed
            if pickup != nil {
                senderName = refreshed.name
            }
            senderWriteSnapshot = writeSnapshot
            senderAddressID = address
        case .receiver:
            receiverCustomer = refreshed
            if pickup != nil {
                receiverName = refreshed.name
            }
            receiverWriteSnapshot = writeSnapshot
            receiverAddressID = address
        }
        return !addressExists
    }

    /// Replaces the selected party and awaits that customer's write snapshot.
    mutating func selectCustomer(_ customer: InvoiceCustomer, role: InvoiceCustomer.Role) {
        // Keep the existing default of the first server address with a valid identity.
        let firstAddress = customer.addresses?.first { InvoiceWriteDocument.isObjectID($0.id ?? "") }
        let firstAddressID = firstAddress?.id

        // Invalidate the old write snapshot when replacing a party.
        switch role {
        case .sender:
            senderName = customer.name
            senderCustomer = customer
            senderWriteSnapshot = nil
            senderAddressID = firstAddressID
        case .receiver:
            receiverName = customer.name
            receiverCustomer = customer
            receiverWriteSnapshot = nil
            receiverAddressID = firstAddressID
        }
    }

    /// Clears selected customer data when an operator replaces the visible party name.
    mutating func setPartyName(_ name: String, role: InvoiceCustomer.Role) {
        // A modified name can no longer be paired with the original customer's write details.
        switch role {
        case .sender:
            if senderName != name {
                senderCustomer = nil
                senderWriteSnapshot = nil
                senderAddressID = nil
            }
            senderName = name
        case .receiver:
            if receiverName != name {
                receiverCustomer = nil
                receiverWriteSnapshot = nil
                receiverAddressID = nil
            }
            receiverName = name
        }
    }

    /// Returns the acknowledgment while it belongs to the current content and sender.
    var validConfirmation: InvoiceDraftConfirmation? {
        // The reviewed content hash must match before an acknowledgment can be reused.
        guard let confirmation, confirmation.matches(self), confirmation.isValid else {
            return nil
        }
        if let senderSignature {
            guard senderSignature.isValid, senderSignature.signerName == senderName else {
                return nil
            }
        }
        return confirmation
    }

    /// Updates the reviewed choices and clears a signature that no longer belongs to them.
    mutating func updateConfirmation(contextHash: Data, defaultSkip: Bool,
                                     apply: (inout InvoiceDraftConfirmation) -> Void) {
        let current = validConfirmation
        var updated = current ?? InvoiceDraftConfirmation(
            contextHash: contextHash, policiesAgreed: false, skipSignature: defaultSkip)

        // Apply changes before deciding whether the existing signature can be reused.
        apply(&updated)
        if current == nil || updated.skipSignature {
            senderSignature = nil
            senderSignatureCapturedAt = nil
        }
        confirmation = updated
    }
}
