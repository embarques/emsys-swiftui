import CryptoKit
import Foundation
import GRDB

/// Attachment staging and upload state.
extension InvoiceStore {
    /// Imported bytes and the form referencing them commit together, including
    /// the first save of a previously unsaved draft.
    func stageAttachment(
        _ attachment: InvoiceAttachment, bytes: Data, draftID: UUID,
        content: InvoiceDraft.Content, expectedRevision: Int64?
    ) throws -> InvoiceDraft {
        guard attachment.validates(bytes) else {
            throw StoreError.invalidDraft
        }
        return try writeInvoiceDatabase { database in
            var existingContent = content
            existingContent.attachments = (content.attachments ?? []).filter { $0.id != attachment.id }
            _ = try Self.writeDraft(id: draftID, content: existingContent, expectedRevision: expectedRevision, in: database)
            try database.execute(sql: """
                INSERT INTO invoiceAttachments (id, draftID, metadata, bytes, state) VALUES (?, ?, ?, ?, 'waiting')
                """, arguments: [attachment.id.uuidString, draftID.uuidString, try JSONEncoder().encode(attachment), bytes])
            var savedContent = content
            savedContent.attachments = (existingContent.attachments ?? []) + [attachment]
            try Self.validateDraft(savedContent)
            let payload = try JSONEncoder().encode(savedContent)
            guard payload.count <= 3 * 1024 * 1024 else {
                throw StoreError.invalidDraft
            }
            try database.execute(sql: "UPDATE invoiceDrafts SET payload = ? WHERE id = ?", arguments: [payload, draftID.uuidString])
            return InvoiceDraft(id: draftID, revision: (expectedRevision ?? 0) + 1, savedAt: .now, content: savedContent)
        }
    }

    /// Removes an attachment and revises its draft in one transaction.
    func removeAttachment(id: UUID, draftID: UUID, content: InvoiceDraft.Content, expectedRevision: Int64) throws -> InvoiceDraft {
        try writeInvoiceDatabase { database in
            guard try Row.fetchOne(database, sql: "SELECT id FROM invoiceAttachments WHERE id = ? AND draftID = ? AND state = 'waiting'", arguments: [id.uuidString, draftID.uuidString]) != nil else {
                throw StoreError.invalidDraft
            }
            var updated = content
            updated.attachments = (content.attachments ?? []).filter { $0.id != id }
            let saved = try Self.writeDraft(id: draftID, content: updated, expectedRevision: expectedRevision, in: database)
            try database.execute(sql: "DELETE FROM invoiceAttachments WHERE id = ?", arguments: [id.uuidString])
            return saved
        }
    }

    /// Reads the attachment records for a draft or an upload batch.
    func invoiceAttachments(draftID: UUID? = nil, pendingOnly: Bool = false) throws -> [PendingInvoiceAttachment] {
        try readInvoiceDatabase { database in
            let rows: [Row]
            if let draftID {
                rows = try Row.fetchAll(database, sql: "SELECT metadata, invoiceID, state FROM invoiceAttachments WHERE draftID = ? ORDER BY id", arguments: [draftID.uuidString])
            } else {
                rows = try Row.fetchAll(database, sql: "SELECT metadata, invoiceID, state FROM invoiceAttachments WHERE state = ? LIMIT 40", arguments: [pendingOnly ? "pending" : "waiting"])
            }
            return try rows.map { row in
                let metadata: Data = row["metadata"]
                let attachment = try JSONDecoder().decode(InvoiceAttachment.self, from: metadata)
                guard attachment.isValid, let state = PendingInvoiceAttachment.State(rawValue: row["state"]) else {
                    throw StoreError.invalidDraft
                }
                return PendingInvoiceAttachment(attachment: attachment, invoiceID: row["invoiceID"], state: state)
            }
        }
    }

    /// Loads the persisted attachment and produces the same upload body on every retry.
    func attachmentBody(id: UUID) throws -> Data {
        // Read both fields from the same database snapshot, then release the read transaction.
        let stored: (metadata: Data, bytes: Data) = try readInvoiceDatabase { database in
            let query = "SELECT metadata, bytes FROM invoiceAttachments WHERE id = ?"
            guard let row = try Row.fetchOne(database, sql: query, arguments: [id.uuidString]) else {
                throw StoreError.invalidDraft
            }
            return (metadata: row["metadata"], bytes: row["bytes"])
        }

        // Let the upload encoder validate the content and construct the transport body.
        let attachment = try JSONDecoder().decode(InvoiceAttachment.self, from: stored.metadata)
        return try InvoiceAttachmentUpload.encode(attachment, bytes: stored.bytes)
    }

    /// Records an upload outcome without changing the original file.
    func setAttachmentState(id: UUID, state: PendingInvoiceAttachment.State) throws {
        guard state != .completed, state != .waiting else {
            throw StoreError.invalidDraft
        }
        try writeInvoiceDatabase { database in
            // A user retry cannot invent a container assignment. Only a
            // downloaded server invoice can release this waiting state.
            try database.execute(sql: "UPDATE invoiceAttachments SET state = ? WHERE id = ? AND invoiceID IS NOT NULL AND state NOT IN ('completed', 'awaitingContainer')",
                arguments: [state.rawValue, id.uuidString])
        }
    }

    /// Makes waiting files sendable once their invoice gains a container.
    nonisolated static func resumeAssignedAttachments(for invoice: Invoice, in database: Database) throws {
        guard invoice.hasDocumentContainer else {
            return
        }
        try database.execute(sql: "UPDATE invoiceAttachments SET state = 'pending' WHERE invoiceID = ? AND state = 'awaitingContainer'",
            arguments: [invoice.id])
    }

    /// Records a matching server receipt and completes the queued upload.
    func completeAttachment(_ pending: PendingInvoiceAttachment, receipt: InvoiceDocumentReceipt) throws {
        guard Self.isObjectID(receipt.id), receipt.invoiceId == pending.invoiceID,
              receipt.originalName == pending.attachment.name.trimmingCharacters(in: .whitespacesAndNewlines),
              receipt.mimeType == pending.attachment.mimeType,
              receipt.size == pending.attachment.size else {
                  throw StoreError.invalidDraft
              }
        try writeInvoiceDatabase { database in
            try database.execute(sql: "UPDATE invoiceAttachments SET state = 'completed', documentID = ? WHERE id = ? AND invoiceID = ? AND state = 'pending'",
                arguments: [receipt.id, pending.id.uuidString, receipt.invoiceId])
        }
    }

    /// Counts attachments that still need synchronization or review.
    func activeAttachmentCount(excludingAwaitingContainer: Bool = false) throws -> Int {
        try readInvoiceDatabase { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM invoiceAttachments WHERE invoiceID IS NOT NULL AND state != 'completed' AND (? = 0 OR state != 'awaitingContainer')", arguments: [excludingAwaitingContainer]) ?? 0
        }
    }
}
