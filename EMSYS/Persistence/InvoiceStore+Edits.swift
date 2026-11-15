import CryptoKit
import Foundation
import GRDB

/// Offline invoice edit transactions.
extension InvoiceStore {
    /// A database version also protects against an older download arriving
    /// through another window/store instance after a local edit was confirmed.
    func downloadVersion() throws -> Int64 {
        try readInvoiceDatabase { try Self.downloadVersion(in: $0) }
    }

    /// Stores a validated edit baseline unless the local revision has moved.
    func saveEditSnapshot(_ snapshot: InvoiceEditSnapshot, ifUnchangedSince version: Int64? = nil) throws {
        guard let invoiceID = snapshot.invoice.id else {
            throw StoreError.invalidInvoiceID
        }
        try snapshot.validate(invoiceID: invoiceID)
        try writeInvoiceDatabase { database in
            if let version, try Self.downloadVersion(in: database) != version { return }
            try Self.writeEditSnapshot(snapshot, in: database)
        }
    }

    /// Reads the last server baseline used for editing an invoice.
    func editSnapshot(invoiceID: String) throws -> InvoiceEditSnapshot? {
        guard Self.isObjectID(invoiceID) else {
            throw StoreError.invalidInvoiceID
        }
        return try readInvoiceDatabase { database in
            try Self.editSnapshot(invoiceID: invoiceID, in: database)
        }
    }

    /// Persists proposed item names against the invoice's server revision.
    @discardableResult
    func queueItemNames(invoiceID: String, names: [String: String], basedOn base: InvoiceEditSnapshot? = nil) throws -> PendingInvoiceEdit {
        guard Self.isObjectID(invoiceID) else {
            throw StoreError.invalidInvoiceID
        }
        return try writeInvoiceDatabase { database in
            guard try !Self.hasActiveEdit(invoiceID: invoiceID, in: database) else {
                throw StoreError.editAlreadyPending
            }
            guard let current = try Self.editSnapshot(invoiceID: invoiceID, in: database) else {
                throw StoreError.missingEditSnapshot
            }
            let snapshot = base ?? current
            try snapshot.validate(invoiceID: invoiceID)
            let changed = try snapshot.invoice.changingItemNames(names)
            return try Self.insertEdit(invoiceID: invoiceID, baseRevision: snapshot.revision,
                document: changed.document, changes: changed.changes,
                state: current.revision == snapshot.revision ? .pending : .needsReview, in: database)
        }
    }

    /// Lists outstanding edits for the review screen in bounded pages.
    func activeEdits(limit: Int = 40, offset: Int = 0) throws -> [PendingInvoiceEdit] {
        guard (1...100).contains(limit), offset >= 0 else {
            throw StoreError.invalidPage
        }
        return try readInvoiceDatabase { database in
            try Row.fetchAll(database, sql: """
                SELECT * FROM invoiceEdits WHERE state NOT IN ('completed', 'discarded', 'superseded')
                ORDER BY createdAt, id LIMIT ? OFFSET ?
                """, arguments: [limit, offset]).map(Self.decodeEdit)
        }
    }

    /// Rebase only the explicitly reviewed names onto current server fields.
    /// It never replaces the old operation's frozen payload under its UUID.
    @discardableResult
    func resolveEdit(editID: UUID, latest: InvoiceEditSnapshot, keepLocalNames: Bool) throws -> PendingInvoiceEdit? {
        try writeInvoiceDatabase { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM invoiceEdits WHERE id = ?", arguments: [editID.uuidString]) else {
                throw StoreError.invalidEditState
            }
            let edit = try Self.decodeEdit(row)
            guard edit.state == .needsReview else {
                throw StoreError.invalidEditState
            }
            try latest.validate(invoiceID: edit.invoiceID)
            guard try Self.editSnapshot(invoiceID: edit.invoiceID, in: database)?.revision == latest.revision else {
                throw StoreError.editSnapshotChanged
            }
            var changed: (document: InvoiceWriteDocument, changes: [InvoiceWriteDocument.ItemNameChange])?
            if keepLocalNames {
                let names = Dictionary(uniqueKeysWithValues: edit.changes.map { ($0.itemID, $0.updatedName) })
                do { changed = try latest.invoice.changingItemNames(names) }
                catch InvoiceWriteDocument.WriteError.noChanges { changed = nil }
            }
            let terminal: PendingInvoiceEdit.State = keepLocalNames ? .superseded : .discarded
            try database.execute(sql: "UPDATE invoiceEdits SET state = ? WHERE id = ?", arguments: [terminal.rawValue, editID.uuidString])
            try Self.writeEditSnapshot(latest, in: database)
            if let changed {
                return try Self.insertEdit(invoiceID: edit.invoiceID, baseRevision: latest.revision,
                    document: changed.document, changes: changed.changes, in: database)
            }
            try Self.advanceLocalVersion(in: database)
            return nil
        }
    }

    /// Returns the outstanding edit currently protecting an invoice.
    func activeEdit(invoiceID: String) throws -> PendingInvoiceEdit? {
        guard Self.isObjectID(invoiceID) else {
            throw StoreError.invalidInvoiceID
        }
        return try readInvoiceDatabase { database in
            guard let row = try Row.fetchOne(database, sql: """
                SELECT * FROM invoiceEdits WHERE invoiceID = ?
                AND state NOT IN ('completed', 'discarded', 'superseded') LIMIT 1
                """, arguments: [invoiceID]) else {
                    return nil
                }
            return try Self.decodeEdit(row)
        }
    }

    /// Returns the next sendable batch in queue order.
    func pendingEdits(limit: Int = 20) throws -> [PendingInvoiceEdit] {
        guard (1...100).contains(limit) else {
            throw StoreError.invalidPage
        }
        return try readInvoiceDatabase { database in
            try Row.fetchAll(database, sql: """
                SELECT * FROM invoiceEdits WHERE state = 'pending'
                ORDER BY createdAt, id LIMIT ?
                """, arguments: [limit]).map(Self.decodeEdit)
        }
    }

    /// Counts edits that still need upload, authorization, or review.
    func activeEditCount() throws -> Int {
        try readInvoiceDatabase { database in
            try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM invoiceEdits
                WHERE state NOT IN ('completed', 'discarded', 'superseded')
                """) ?? 0
        }
    }

    /// Returns recoverable server and authorization failures to the sendable queue.
    func retryBlockedEdits() throws {
        try writeInvoiceDatabase { database in
            try database.execute(sql: """
                UPDATE invoiceEdits SET state = 'pending'
                WHERE state IN ('authorizationRequired', 'serverUnavailable')
                """)
        }
    }

    /// Records an upload attempt only while the edit is eligible to send.
    func recordAttempt(editID: UUID) throws -> Bool {
        try writeInvoiceDatabase { database in
            try database.execute(sql: """
                UPDATE invoiceEdits SET attempts = attempts + 1 WHERE id = ? AND state = 'pending'
                """, arguments: [editID.uuidString])
            return database.changesCount == 1
        }
    }

    /// Records why an edit must leave the sendable queue.
    func requireReview(editID: UUID, state: PendingInvoiceEdit.State) throws {
        guard [.needsReview, .authorizationRequired, .serverUnavailable].contains(state) else {
            throw StoreError.invalidEditState
        }
        try writeInvoiceDatabase { database in
            try database.execute(sql: "UPDATE invoiceEdits SET state = ? WHERE id = ? AND state = 'pending'",
                arguments: [state.rawValue, editID.uuidString])
        }
    }

    /// Commits the confirmed server projection and completes the outbox entry together.
    func completeEdit(editID: UUID, snapshot: InvoiceEditSnapshot) throws {
        try writeInvoiceDatabase { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM invoiceEdits WHERE id = ?", arguments: [editID.uuidString]) else {
                throw StoreError.invalidEditState
            }
            let edit = try Self.decodeEdit(row)
            // A second uploader may acknowledge the same receipt. It must not
            // replace a newer local projection with an earlier response.
            if edit.state == .completed { return }
            guard edit.state == .pending else {
                throw StoreError.invalidEditState
            }
            try snapshot.validate(invoiceID: edit.invoiceID)
            try database.execute(sql: "UPDATE invoiceEdits SET state = 'completed' WHERE id = ?", arguments: [editID.uuidString])
            try Self.advanceLocalVersion(in: database)
            try Self.writeEditSnapshot(snapshot, in: database)
        }
    }

    /// Reads the cache revision that protects against stale downloads.
    nonisolated static func downloadVersion(in database: Database) throws -> Int64 {
        guard let version = try Int64.fetchOne(database, sql: "SELECT localWriteVersion FROM invoiceCacheMetadata WHERE id = 1") else {
            throw StoreError.invalidEditState
        }
        return version
    }

    /// Invalidates in-flight downloads after a local edit changes the projection.
    nonisolated static func advanceLocalVersion(in database: Database) throws {
        try database.execute(sql: "UPDATE invoiceCacheMetadata SET localWriteVersion = localWriteVersion + 1 WHERE id = 1")
    }

    /// Checks whether an outstanding edit protects this invoice from replacement.
    private nonisolated static func hasActiveEdit(invoiceID: String, in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: """
            SELECT EXISTS(SELECT 1 FROM invoiceEdits WHERE invoiceID = ?
                AND state NOT IN ('completed', 'discarded', 'superseded'))
            """, arguments: [invoiceID]) ?? false
    }

    /// Reads the last server baseline used for editing an invoice.
    private nonisolated static func editSnapshot(invoiceID: String, in database: Database) throws -> InvoiceEditSnapshot? {
        guard let row = try Row.fetchOne(database, sql: "SELECT revision, payload FROM invoiceEditSnapshots WHERE invoiceID = ?", arguments: [invoiceID]) else {
            return nil
        }
        let payload: Data = row["payload"]
        let document = try JSONDecoder().decode(InvoiceWriteDocument.self, from: payload)
        let snapshot = InvoiceEditSnapshot(invoice: document, revision: row["revision"])
        try snapshot.validate(invoiceID: invoiceID)
        return snapshot
    }

    /// Writes a validated server baseline into the transaction's edit cache.
    private nonisolated static func writeEditSnapshot(_ snapshot: InvoiceEditSnapshot, in database: Database) throws {
        guard let invoiceID = snapshot.invoice.id else {
            throw StoreError.invalidInvoiceID
        }
        let payload = try snapshot.invoice.encoded()
        try database.execute(sql: """
            INSERT INTO invoiceEditSnapshots (invoiceID, revision, payload) VALUES (?, ?, ?)
            ON CONFLICT(invoiceID) DO UPDATE SET revision = excluded.revision, payload = excluded.payload
            """, arguments: [invoiceID, snapshot.revision, payload])
        if try !hasActiveEdit(invoiceID: invoiceID, in: database) {
            try writeProjection(snapshot.invoice, synchronizedAt: .now, in: database)
        }
    }

    /// Updates the cached invoice shown while an edit awaits confirmation.
    private nonisolated static func writeProjection(_ document: InvoiceWriteDocument, synchronizedAt: Date? = nil, in database: Database) throws {
        let invoice = try document.projection()
        let payload = try document.encoded()
        try database.execute(sql: """
            INSERT INTO invoiceSnapshots (id, number, payload, detailPayload, synchronizedAt)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET number = excluded.number, payload = excluded.payload,
                detailPayload = excluded.detailPayload,
                synchronizedAt = COALESCE(?, invoiceSnapshots.synchronizedAt)
            """, arguments: [invoice.id, invoice.number, payload, payload, Date.now.timeIntervalSince1970,
                synchronizedAt?.timeIntervalSince1970])
        try resumeAssignedAttachments(for: invoice, in: database)
    }

    /// Restores a durable edit entry from its stored request and change fields.
    private nonisolated static func decodeEdit(_ row: Row) throws -> PendingInvoiceEdit {
        guard let id = UUID(uuidString: row["id"]), let state = PendingInvoiceEdit.State(rawValue: row["state"]) else {
            throw StoreError.invalidEditState
        }
        let invoiceID: String = row["invoiceID"]
        let body: Data = row["requestBody"]
        guard isObjectID(invoiceID), body.count <= 3 * 1024 * 1024 else {
            throw StoreError.invalidEditState
        }
        let submission = try JSONDecoder().decode(InvoiceUpdateSubmission.self, from: body)
        let revision: String = row["expectedRevision"]
        guard submission.requestID == id, submission.invoice.id == invoiceID, submission.revision == revision else {
            throw StoreError.invalidEditState
        }
        let changes = try JSONDecoder().decode([InvoiceWriteDocument.ItemNameChange].self, from: row["changes"])
        guard !changes.isEmpty, Set(changes.map(\.itemID)).count == changes.count else {
            throw StoreError.invalidEditState
        }
        return PendingInvoiceEdit(id: id, invoiceID: invoiceID, invoiceNumber: submission.invoice.number, expectedRevision: revision, requestBody: body,
            changes: changes, createdAt: Date(timeIntervalSince1970: row["createdAt"]), state: state, attempts: row["attempts"])
    }

    /// Freezes a new edit and updates its local projection in the same transaction.
    private nonisolated static func insertEdit(
        invoiceID: String, baseRevision: String, document: InvoiceWriteDocument,
        changes: [InvoiceWriteDocument.ItemNameChange], state: PendingInvoiceEdit.State = .pending, in database: Database
    ) throws -> PendingInvoiceEdit {
        let id = UUID()
        let body = try InvoiceUpdateSubmission(requestID: id, revision: baseRevision, invoice: document).encoded()
        let encodedChanges = try JSONEncoder().encode(changes)
        let createdAt = Date.now
        try database.execute(sql: """
            INSERT INTO invoiceEdits (id, invoiceID, expectedRevision, requestBody, changes, createdAt, state)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id.uuidString, invoiceID, baseRevision, body, encodedChanges, createdAt.timeIntervalSince1970, state.rawValue])
        try advanceLocalVersion(in: database)
        try writeProjection(document, in: database)
        return PendingInvoiceEdit(id: id, invoiceID: invoiceID, invoiceNumber: document.number, expectedRevision: baseRevision,
            requestBody: body, changes: changes, createdAt: createdAt, state: state, attempts: 0)
    }
}
