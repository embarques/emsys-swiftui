import CryptoKit
import Foundation
import GRDB

/// Draft loading, editing, and revision checks.
extension InvoiceStore {
    /// Lists local forms in save order, optionally restricted to assigned pickups.
    func draftSummaries(limit: Int = 40, offset: Int = 0, assignedOnly: Bool = false) throws -> [InvoiceDraftSummary] {
        guard (1...100).contains(limit), offset >= 0 else {
            throw StoreError.invalidPage
        }
        return try readInvoiceDatabase { database in
            try Row.fetchAll(database, sql: """
                SELECT d.id, d.revision, d.savedAt, d.senderName, d.receiverName, d.itemCount, c.state AS creationState,
                    (SELECT COUNT(*) FROM invoiceAttachments a WHERE a.draftID = d.id AND a.invoiceID IS NOT NULL AND a.state != 'completed') AS pendingAttachmentCount
                FROM invoiceDrafts d LEFT JOIN invoiceCreations c ON c.draftID = d.id
                WHERE \(assignedOnly ? "d.assignedOnly = 1" : "1")
                ORDER BY d.savedAt DESC, d.id DESC LIMIT ? OFFSET ?
                """, arguments: [limit, offset]).map { row in
                guard let id = UUID(uuidString: row["id"]) else {
                    throw StoreError.invalidDraft
                }
                return InvoiceDraftSummary(id: id, revision: row["revision"], savedAt: Date(timeIntervalSince1970: row["savedAt"]),
                    senderName: row["senderName"], receiverName: row["receiverName"], itemCount: row["itemCount"],
                    creationState: (row["creationState"] as String?).flatMap(PendingInvoiceCreation.State.init(rawValue:)),
                    pendingAttachmentCount: row["pendingAttachmentCount"])
            }
        }
    }

    /// Loads a saved form and its revision by local draft identity.
    func draft(id: UUID) throws -> InvoiceDraft? {
        try readInvoiceDatabase { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT revision, savedAt, payload FROM invoiceDrafts WHERE id = ?",
                arguments: [id.uuidString]) else {
                    return nil
                }
            let payload: Data = row["payload"]
            guard payload.count <= 3 * 1024 * 1024 else {
                throw StoreError.invalidDraft
            }
            let content = try JSONDecoder().decode(InvoiceDraft.Content.self, from: payload)
            try Self.validateDraft(content)
            let revision: Int64 = row["revision"]
            guard revision > 0 else {
                throw StoreError.invalidDraft
            }
            return InvoiceDraft(id: id, revision: revision, savedAt: Date(timeIntervalSince1970: row["savedAt"]), content: content)
        }
    }

    /// A revision predicate protects another window's saved form. Draft saves
    /// never create an invoice, reserve a number, record payment or request upload.
    func saveDraft(id: UUID, content: InvoiceDraft.Content, expectedRevision: Int64?) throws -> InvoiceDraft {
        try writeInvoiceDatabase { database in
            try Self.writeDraft(id: id, content: content, expectedRevision: expectedRevision, in: database)
        }
    }

    /// Writes a new or revised draft within the caller's transaction.
    nonisolated static func writeDraft(
        id: UUID, content: InvoiceDraft.Content, expectedRevision: Int64?, in database: Database
    ) throws -> InvoiceDraft {
        try validateDraft(content)
        let payload = try JSONEncoder().encode(content)
        guard payload.count <= 3 * 1024 * 1024 else {
            throw StoreError.invalidDraft
        }
        // Revision zero is reserved for new drafts and the next revision must fit in SQLite.
        if let expectedRevision, expectedRevision <= 0 || expectedRevision == Int64.max {
            throw StoreError.invalidDraft
        }
        // A queued operation owns the saved draft until synchronization finishes.
        guard try Row.fetchOne(database, sql: "SELECT id FROM invoiceCreations WHERE draftID = ?", arguments: [id.uuidString]) == nil else {
            throw StoreError.draftChanged
        }
        let savedAt = Date.now
        let revision = (expectedRevision ?? 0) + 1
        if let expectedRevision {
            try database.execute(sql: """
                UPDATE invoiceDrafts SET revision = ?, savedAt = ?, senderName = ?, receiverName = ?, itemCount = ?, payload = ?
                WHERE id = ? AND revision = ?
                """, arguments: [revision, savedAt.timeIntervalSince1970, content.senderName, content.receiverName,
                    content.items.count, payload, id.uuidString, expectedRevision])
        } else {
            try database.execute(sql: """
                INSERT INTO invoiceDrafts (id, revision, savedAt, senderName, receiverName, itemCount, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
                """, arguments: [id.uuidString, revision, savedAt.timeIntervalSince1970, content.senderName,
                    content.receiverName, content.items.count, payload])
        }
        guard database.changesCount == 1 else {
            throw StoreError.draftChanged
        }
        try database.execute(sql: "UPDATE invoiceDrafts SET assignedOnly = ? WHERE id = ?", arguments: [content.assignedPickup != nil, id.uuidString])
        // Metadata can only refer to bytes already staged for this exact draft.
        for attachment in content.attachments ?? [] {
            guard let stored = try Data.fetchOne(database, sql: "SELECT metadata FROM invoiceAttachments WHERE id = ? AND draftID = ?",
                arguments: [attachment.id.uuidString, id.uuidString]),
                try JSONDecoder().decode(InvoiceAttachment.self, from: stored) == attachment else {
                    throw StoreError.invalidDraft
                }
        }
        return InvoiceDraft(id: id, revision: revision, savedAt: savedAt, content: content)
    }

    /// Creates an independent draft and copies any eligible attachment bytes.
    func copyDraft(sourceID: UUID, content: InvoiceDraft.Content) throws -> InvoiceDraft {
        try writeInvoiceDatabase { database in
            guard try Row.fetchOne(database, sql: "SELECT id FROM invoiceCreations WHERE draftID = ?", arguments: [sourceID.uuidString]) == nil else {
                throw StoreError.draftChanged
            }
            let copyID = UUID()
            var copied = content
            copied.attachments = nil
            _ = try Self.writeDraft(id: copyID, content: copied, expectedRevision: nil, in: database)
            for attachment in content.attachments ?? [] {
                guard let row = try Row.fetchOne(database, sql: "SELECT metadata, bytes FROM invoiceAttachments WHERE id = ? AND draftID = ? AND state = 'waiting'", arguments: [attachment.id.uuidString, sourceID.uuidString]),
                      try JSONDecoder().decode(InvoiceAttachment.self, from: row["metadata"]) == attachment else {
                          throw StoreError.invalidDraft
                      }
                let bytes: Data = row["bytes"]
                guard attachment.validates(bytes) else {
                    throw StoreError.invalidDraft
                }
                let copiedAttachment = InvoiceAttachment(id: UUID(), name: attachment.name, mimeType: attachment.mimeType,
                    size: attachment.size, digest: attachment.digest)
                copied.attachments = (copied.attachments ?? []) + [copiedAttachment]
                try database.execute(sql: "INSERT INTO invoiceAttachments (id, draftID, metadata, bytes, state) VALUES (?, ?, ?, ?, 'waiting')",
                    arguments: [copiedAttachment.id.uuidString, copyID.uuidString, try JSONEncoder().encode(copiedAttachment), bytes])
            }
            // New upload identities change the review context, so a copied form
            // must be reviewed again before a signature/agreement can be sent.
            if copied.attachments != content.attachments { copied.confirmation = nil }
            let payload = try JSONEncoder().encode(copied)
            guard payload.count <= 3 * 1024 * 1024 else {
                throw StoreError.invalidDraft
            }
            try database.execute(sql: "UPDATE invoiceDrafts SET payload = ? WHERE id = ?", arguments: [payload, copyID.uuidString])
            return InvoiceDraft(id: copyID, revision: 1, savedAt: .now, content: copied)
        }
    }

    /// Deletes an editable draft only if its revision still matches.
    func deleteDraft(id: UUID, expectedRevision: Int64) throws {
        try writeInvoiceDatabase { database in
            guard try Row.fetchOne(database, sql: "SELECT id FROM invoiceCreations WHERE draftID = ? AND state != 'completed'", arguments: [id.uuidString]) == nil else {
                throw StoreError.draftChanged
            }
            guard try Row.fetchOne(database, sql: "SELECT id FROM invoiceAttachments WHERE draftID = ? AND invoiceID IS NOT NULL AND state != 'completed'", arguments: [id.uuidString]) == nil else {
                throw StoreError.draftChanged
            }
            try database.execute(sql: "DELETE FROM invoiceDrafts WHERE id = ? AND revision = ?", arguments: [id.uuidString, expectedRevision])
            guard database.changesCount == 1 else {
                throw StoreError.draftChanged
            }
        }
    }

    /// Rejects inconsistent local form data before it can be saved or submitted.
    nonisolated static func validateDraft(_ content: InvoiceDraft.Content) throws {
        guard content.date.pickerDate != nil, content.pickup?.id != 0, Set(content.items.map(\.id)).count == content.items.count else {
            throw StoreError.invalidDraft
        }
        // Every attachment needs a unique identity and valid metadata.
        let attachments = content.attachments ?? []
        guard Set(attachments.map(\.id)).count == attachments.count, attachments.allSatisfy(\.isValid) else {
            throw StoreError.invalidDraft
        }
        if let confirmation = content.confirmation, !confirmation.isValid {
            throw StoreError.invalidDraft
        }
        // Incomplete drafts may have a cleared sender name. Preserve their
        // image without treating it as a valid signature for submission.
        if let signature = content.senderSignature, signature.pngData == nil {
            throw StoreError.invalidDraft
        }
        // Optional reference data must be valid whenever an operator selects it.
        if let policies = content.policies, !InvoicePolicy.validate(policies) {
            throw StoreError.invalidDraft
        }
        if let container = content.container, !container.isValid {
            throw StoreError.invalidDraft
        }
        if let review = content.paymentReview, !review.isValid {
            throw StoreError.invalidDraft
        }
        if let account = content.payment?.bankAccount, !account.isValid {
            throw StoreError.invalidDraft
        }
        // The pickup source determines which type of assignment is allowed.
        switch content.pickupSource {
        case nil:
            guard content.pickupRoute == nil, content.pickupEmployee == nil else {
                throw StoreError.invalidDraft
            }
        case .route:
            guard content.pickupEmployee == nil else {
                throw StoreError.invalidDraft
            }
            if let route = content.pickupRoute, !route.isValid || !route.isPickup {
                throw StoreError.invalidDraft
            }
        case .warehouse, .office:
            guard content.pickupRoute == nil else {
                throw StoreError.invalidDraft
            }
            if let employee = content.pickupEmployee, !employee.isValid || !employee.isEligible {
                throw StoreError.invalidDraft
            }
        }
        // A write snapshot must still belong to the selected party and address.
        for (snapshot, customer, addressID) in [
            (content.senderWriteSnapshot, content.senderCustomer, content.senderAddressID),
            (content.receiverWriteSnapshot, content.receiverCustomer, content.receiverAddressID)
        ] {
            if let snapshot {
                guard let customer, snapshot.matches(customer) else {
                    throw StoreError.invalidDraft
                }
                _ = try snapshot.party(addressID: addressID)
            }
        }
        // Keep the public customer, typed name, and selected address consistent.
        for (customer, name, addressID, role) in [
            (content.senderCustomer, content.senderName, content.senderAddressID, InvoiceCustomer.Role.sender),
            (content.receiverCustomer, content.receiverName, content.receiverAddressID, InvoiceCustomer.Role.receiver)
        ] {
            if let customer {
                guard customer.isValid, customer.name == name, customer.customerType == role.rawValue else {
                    throw StoreError.invalidDraft
                }
                if let addressID {
                    guard InvoiceWriteDocument.isObjectID(addressID),
                          customer.addresses?.contains(where: { $0.id == addressID }) == true else {
                              throw StoreError.invalidDraft
                          }
                }
            } else if addressID != nil {
                throw StoreError.invalidDraft
            }
        }
    }
}
