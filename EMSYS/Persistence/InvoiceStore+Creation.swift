import CryptoKit
import Foundation
import GRDB

/// Invoice submission and durable acknowledgements.
extension InvoiceStore {
    /// The saved form and immutable first upload commit together. Network work
    /// starts only after this transaction returns successfully.
    func queueInvoiceCreation(draftID: UUID, expectedRevision: Int64?, plan: InvoiceCreationPlan,
                              expectedNumber: String? = nil) throws -> PendingInvoiceCreation {
        // Validate and size-check the draft before opening the write transaction.
        try Self.validateDraft(plan.content)
        let encoder = JSONEncoder()
        let content = try encoder.encode(plan.content)
        guard content.count <= 3 * 1024 * 1024 else {
            throw StoreError.invalidDraft
        }
        let operationID = plan.invoiceRequestID
        let now = Date.now
        return try writeInvoiceDatabase { database in
            // Reserve only the number the operator saw in the preview.
            guard let reservation = try Self.nextInvoiceReservation(in: database) else {
                throw StoreError.invoicePoolEmpty
            }
            if let expectedNumber, reservation.number != expectedNumber {
                throw StoreError.invoiceNumberPreviewChanged
            }

            // Freeze the plan and its first request before updating local state.
            let plan = try plan.reserving(reservation)
            let frozen = try encoder.encode(plan)
            guard frozen.count <= 3 * 1024 * 1024 else {
                throw StoreError.invalidDraft
            }
            let journal = try plan.journalRequest()
            let invoice = journal == nil ? try plan.invoiceRequest() : nil
            try Self.consumeInvoiceReservation(reservation, in: database)
            // An already queued draft cannot be submitted a second time.
            guard try Row.fetchOne(database, sql: "SELECT id FROM invoiceCreations WHERE draftID = ?", arguments: [draftID.uuidString]) == nil else {
                throw StoreError.draftChanged
            }
            // Prevent a stale editor from overwriting a newer draft revision.
            if let expectedRevision {
                guard expectedRevision > 0, expectedRevision < Int64.max else {
                    throw StoreError.invalidDraft
                }
                try database.execute(sql: """
                    UPDATE invoiceDrafts SET revision = revision + 1, savedAt = ?, senderName = ?, receiverName = ?, itemCount = ?, payload = ?
                    WHERE id = ? AND revision = ?
                    """, arguments: [now.timeIntervalSince1970, plan.content.senderName, plan.content.receiverName,
                        plan.content.items.count, content, draftID.uuidString, expectedRevision])
            } else {
                try database.execute(sql: """
                    INSERT INTO invoiceDrafts (id, revision, savedAt, senderName, receiverName, itemCount, payload)
                    VALUES (?, 1, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
                    """, arguments: [draftID.uuidString, now.timeIntervalSince1970, plan.content.senderName,
                        plan.content.receiverName, plan.content.items.count, content])
            }
            guard database.changesCount == 1 else {
                throw StoreError.draftChanged
            }
            try database.execute(sql: "UPDATE invoiceDrafts SET assignedOnly = ? WHERE id = ?", arguments: [plan.content.assignedPickup != nil, draftID.uuidString])
            // Confirm every referenced attachment is already saved under this draft.
            for attachment in plan.content.attachments ?? [] {
                guard let stored = try Data.fetchOne(database, sql: "SELECT metadata FROM invoiceAttachments WHERE id = ? AND draftID = ?", arguments: [attachment.id.uuidString, draftID.uuidString]),
                      try JSONDecoder().decode(InvoiceAttachment.self, from: stored) == attachment else {
                    throw StoreError.invalidDraft
                }
            }

            // Persist the request and its digest for byte-for-byte retries.
            try database.execute(sql: """
                INSERT INTO invoiceCreations (id, draftID, state, plan, journalRequest, journalHash, invoiceRequest, invoiceHash, createdAt)
                VALUES (?, ?, 'pending', ?, ?, ?, ?, ?, ?)
                """, arguments: [operationID.uuidString, draftID.uuidString, frozen, journal, journal.map { Data(SHA256.hash(data: $0)) }, invoice, invoice.map { Data(SHA256.hash(data: $0)) }, now.timeIntervalSince1970])
            try database.execute(sql: "UPDATE invoiceCreations SET assignedOnly = ? WHERE id = ?", arguments: [plan.content.assignedPickup != nil, operationID.uuidString])
            return PendingInvoiceCreation(id: operationID, draftID: draftID, state: .pending,
                plan: plan, journalRequest: journal, invoiceRequest: invoice, invoiceID: nil)
        }
    }

    /// Replaces a rejected reservation atomically and keeps the new request paused for review.
    func replaceDuplicateInvoiceNumber(creationID: UUID) throws -> PendingInvoiceCreation {
        try writeInvoiceDatabase { database in
            // Decode the latest operation inside the same transaction that will replace it.
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM invoiceCreations WHERE id = ?",
                                            arguments: [creationID.uuidString]) else {
                throw StoreError.draftChanged
            }
            let operation = try Self.decodeInvoiceCreation(row)
            guard operation.canReplaceInvoiceNumber else {
                throw StoreError.draftChanged
            }

            // Skip the rejected number and numbers already present in the local invoice cache.
            guard let payload = try Data.fetchOne(database, sql: """
                SELECT r.payload FROM invoiceReservations r
                WHERE r.state = 'available'
                  AND json_extract(CAST(r.payload AS TEXT), '$.number') != ?
                  AND NOT EXISTS (
                    SELECT 1 FROM invoiceSnapshots s
                    WHERE s.id = r.id OR s.number = json_extract(CAST(r.payload AS TEXT), '$.number')
                  )
                ORDER BY r.id LIMIT 1
                """, arguments: [operation.plan.reservation?.number ?? ""]) else {
                throw StoreError.invoicePoolEmpty
            }

            // A different number requires a new operation identity and frozen request.
            let reservation = try JSONDecoder().decode(InvoiceReservation.self, from: payload)
            let plan = try InvoiceCreationPlan(content: operation.plan.content, branch: operation.plan.branch,
                                               reservation: reservation)
            let frozen = try JSONEncoder().encode(plan)
            let journal = try plan.journalRequest()
            let invoice = journal == nil ? try plan.invoiceRequest() : nil
            try Self.consumeInvoiceReservation(reservation, in: database)
            try database.execute(sql: """
                UPDATE invoiceCreations
                SET id = ?, state = 'replacementReady', plan = ?, failure = NULL,
                    journalRequest = ?, journalHash = ?, invoiceRequest = ?, invoiceHash = ?
                WHERE id = ?
                """, arguments: [plan.invoiceRequestID.uuidString, frozen, journal,
                    journal.map { Data(SHA256.hash(data: $0)) }, invoice,
                    invoice.map { Data(SHA256.hash(data: $0)) }, creationID.uuidString])
            return PendingInvoiceCreation(id: plan.invoiceRequestID, draftID: operation.draftID, state: .replacementReady,
                                          plan: plan, journalRequest: journal, invoiceRequest: invoice, invoiceID: nil)
        }
    }

    /// Marks a verified reservation as consumed and advances the pool revision.
    private nonisolated static func consumeInvoiceReservation(_ reservation: InvoiceReservation, in database: Database) throws {
        try database.execute(sql: "UPDATE invoiceReservations SET state = 'consumed' WHERE id = ? AND token = ? AND state = 'available'", arguments: [reservation.id, reservation.allocation.token])
        // A stale or already used claim cannot be recorded for this draft.
        guard database.changesCount == 1 else {
            throw StoreError.invoiceReservationChanged
        }
        try database.execute(sql: "UPDATE invoicePoolMetadata SET revision = revision + 1 WHERE id = 1")
    }

    /// Removes a creation only while its state allows local deletion.
    func deleteOfflineInvoice(id: String, draftID: UUID) throws {
        try writeInvoiceDatabase { database in
            // Keep the reserved number consumed. A response lost during a previous
            // sync may have already used it on the server.
            try database.execute(sql: """
                DELETE FROM invoiceCreations
                WHERE id = ? AND draftID = ? AND state != 'completed'
                  AND invoiceID IS NULL AND journalReceipt IS NULL
                  AND NOT EXISTS (
                    SELECT 1 FROM invoiceAttachments WHERE draftID = ? AND invoiceID IS NOT NULL
                  )
                """, arguments: [id, draftID.uuidString, draftID.uuidString])
            guard database.changesCount == 1 else {
                throw StoreError.draftChanged
            }
            try database.execute(sql: "DELETE FROM invoiceDrafts WHERE id = ?", arguments: [draftID.uuidString])
        }
    }

    /// Reads the invoice identities and reserved numbers linked to requested pickups.
    func pickupInvoiceLinks(pickupID: UInt32) throws -> [PickupInvoiceLink] {
        try pickupInvoiceLinks(pickupIDs: [pickupID])[pickupID] ?? []
    }

    /// Returns distinct display numbers in the same order as their stored pickup links.
    func pickupInvoiceNumbers(pickupIDs: [UInt32]) throws -> [UInt32: [String]] {
        let linksByPickup = try pickupInvoiceLinks(pickupIDs: pickupIDs)
        return linksByPickup.mapValues { links in
            // A server invoice and its retained local operation can report the same number.
            var seen = Set<String>()
            var numbers: [String] = []
            for link in links {
                guard let number = link.number, seen.insert(number).inserted else {
                    continue
                }
                numbers.append(number)
            }
            return numbers
        }
    }

    /// Match the stored pickup ID, including when an invoice receipt omits it.
    func pickupInvoiceLinks(pickupIDs: [UInt32]) throws -> [UInt32: [PickupInvoiceLink]] {
        guard !pickupIDs.isEmpty else {
            return [:]
        }
        let ids = String(decoding: try JSONEncoder().encode(pickupIDs), as: UTF8.self)
        return try readInvoiceDatabase { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT id, number, json_extract(CAST(payload AS TEXT), '$.pickup.id') AS pickupID
                FROM invoiceSnapshots
                WHERE pickupID IN (SELECT value FROM json_each(?))
                ORDER BY number COLLATE NOCASE, id
                """, arguments: [ids])
            var links: [UInt32: [PickupInvoiceLink]] = [:]
            var invoiceIDs: [UInt32: Set<String>] = [:]
            for row in rows {
                let pickupID: UInt32 = row["pickupID"]
                let id: String = row["id"]
                links[pickupID, default: []].append(.init(id: id, invoiceID: id, number: row["number"], state: nil))
                invoiceIDs[pickupID, default: []].insert(id)
            }

            let creations = try Row.fetchAll(database, sql: """
                SELECT c.*, s.number AS confirmedNumber,
                       json_extract(CAST(c.plan AS TEXT), '$.content.pickup.id') AS pickupID
                FROM invoiceCreations c LEFT JOIN invoiceSnapshots s ON c.invoiceID = s.id
                WHERE pickupID IN (SELECT value FROM json_each(?))
                ORDER BY c.createdAt, c.id
                """, arguments: [ids])
            for row in creations {
                let pickupID: UInt32 = row["pickupID"]
                let creation = try Self.decodeInvoiceCreation(row)
                if let id = creation.invoiceID {
                    guard invoiceIDs[pickupID, default: []].insert(id).inserted else {
                        continue
                    }
                    links[pickupID, default: []].append(.init(id: id, invoiceID: id,
                        number: row["confirmedNumber"], state: creation.state))
                } else {
                    links[pickupID, default: []].append(.init(id: creation.id.uuidString, invoiceID: nil,
                        number: creation.plan.reservation?.number, state: creation.state))
                }
            }
            return links
        }
    }

    /// Restores the saved submission and recovery state for one draft.
    func invoiceCreation(draftID: UUID) throws -> PendingInvoiceCreation? {
        try readInvoiceDatabase {
            try Row.fetchOne($0, sql: "SELECT * FROM invoiceCreations WHERE draftID = ?", arguments: [draftID.uuidString])
                .map(Self.decodeInvoiceCreation)
        }
    }

    /// Builds directory rows for pending work and recently confirmed invoices.
    func localInvoiceListEntries(includeRecentConfirmed: Bool) throws -> [LocalInvoiceListEntry] {
        try readInvoiceDatabase { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT c.id, c.draftID, c.state, c.journalReceipt IS NULL AND c.invoiceID IS NULL AS canDelete,
                    json_extract(CAST(c.plan AS TEXT), '$.reservation.number') AS number,
                    json_extract(CAST(c.plan AS TEXT), '$.content.senderName') AS senderName,
                    json_extract(CAST(c.plan AS TEXT), '$.content.receiverName') AS receiverName,
                    printf('%04d-%02d-%02d',
                        json_extract(CAST(c.plan AS TEXT), '$.content.date.year'),
                        json_extract(CAST(c.plan AS TEXT), '$.content.date.month'),
                        json_extract(CAST(c.plan AS TEXT), '$.content.date.day')) AS date,
                    json_extract(CAST(c.plan AS TEXT), '$.content.container.name') AS container,
                    COALESCE(s.detailPayload, s.payload) AS invoice
                FROM invoiceCreations c LEFT JOIN invoiceSnapshots s ON c.invoiceID = s.id
                WHERE c.state != 'completed' OR c.id IN (
                    SELECT id FROM invoiceCreations WHERE state = 'completed' AND ? AND createdAt >= ?
                    ORDER BY createdAt DESC, id DESC LIMIT 50
                )
                ORDER BY c.createdAt DESC, c.id DESC
                """, arguments: [includeRecentConfirmed, Date.now.addingTimeInterval(-86_400).timeIntervalSince1970])
            return try rows.compactMap { row in
                guard let draftID = UUID(uuidString: row["draftID"]),
                      let state = PendingInvoiceCreation.State(rawValue: row["state"]) else {
                          throw StoreError.invalidDraft
                      }
                let payload: Data? = row["invoice"]
                let invoice = try payload.map { try JSONDecoder().decode(Invoice.self, from: $0) }
                guard state != .completed || invoice != nil else {
                    return nil
                }
                return LocalInvoiceListEntry(id: row["id"], draftID: draftID,
                    number: invoice?.number ?? row["number"], senderName: row["senderName"] ?? "",
                    receiverName: row["receiverName"] ?? "", date: row["date"] ?? "",
                    container: row["container"], state: state, invoice: invoice, canDelete: row["canDelete"])
            }
        }
    }

    /// Lists sendable creations in the order they were saved.
    func pendingInvoiceCreations(assignedOnly: Bool = false) throws -> [PendingInvoiceCreation] {
        try readInvoiceDatabase {
            try Row.fetchAll($0, sql: "SELECT * FROM invoiceCreations WHERE state = 'pending' \(assignedOnly ? "AND assignedOnly = 1" : "") ORDER BY createdAt LIMIT 40")
                .map(Self.decodeInvoiceCreation)
        }
    }

    /// Counts creations that have yet to receive server confirmation.
    func activeInvoiceCreationCount(assignedOnly: Bool = false) throws -> Int {
        try readInvoiceDatabase { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM invoiceCreations WHERE state != 'completed' \(assignedOnly ? "AND assignedOnly = 1" : "")") ?? 0 }
    }

    /// Requeues the original operation and keeps its last failure visible until a new result arrives.
    func requeueInvoiceCreation(id: UUID) throws {
        // Change only the queue state so an overlapping upload cannot lose its latest failure.
        try writeInvoiceDatabase { database in
            try database.execute(sql: "UPDATE invoiceCreations SET state = 'pending' WHERE id = ? AND state != 'completed'",
                                 arguments: [id.uuidString])
        }
    }

    /// Updates recovery state without replacing frozen invoice or payment requests.
    func setInvoiceCreationState(id: UUID, state: PendingInvoiceCreation.State,
                                 failure: PendingInvoiceCreation.Failure? = nil) throws {
        guard state != .completed else {
            throw StoreError.invalidDraft
        }
        let failureData = try failure.map { try JSONEncoder().encode($0) }
        try writeInvoiceDatabase {
            try $0.execute(sql: "UPDATE invoiceCreations SET state = ?, failure = ? WHERE id = ? AND state != 'completed'",
                           arguments: [state.rawValue, failureData, id.uuidString])
        }
    }

    /// Records the confirmed payment and prepares the next frozen invoice request.
    func saveInitialPaymentReceipt(creationID: UUID, receipt: InvoiceInitialPaymentReceipt) throws {
        try writeInvoiceDatabase { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM invoiceCreations WHERE id = ?", arguments: [creationID.uuidString]) else {
                throw StoreError.invalidDraft
            }
            let operation = try Self.decodeInvoiceCreation(row)
            // Preserve the first confirmed result. Replayed journal responses
            // contain current totals and must not rebuild a submitted invoice.
            if operation.invoiceRequest != nil { return }
            guard operation.state == .pending, operation.journalRequest != nil else {
                throw StoreError.invalidDraft
            }
            let invoice = try operation.plan.invoiceRequest(receipt: receipt)
            try database.execute(sql: "UPDATE invoiceCreations SET journalReceipt = ?, invoiceRequest = ?, invoiceHash = ? WHERE id = ? AND invoiceRequest IS NULL",
                arguments: [try JSONEncoder().encode(receipt), invoice, Data(SHA256.hash(data: invoice)), creationID.uuidString])
        }
    }

    /// Commits the server invoice and makes its attachments eligible for upload.
    func completeInvoiceCreation(id: UUID, invoice: Invoice) throws {
        guard Self.isObjectID(invoice.id), invoice.number?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw StoreError.invalidCreationReceipt
        }
        let payload = try JSONEncoder().encode(invoice)
        try writeInvoiceDatabase { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM invoiceCreations WHERE id = ?", arguments: [id.uuidString]) else {
                throw StoreError.invalidDraft
            }
            let operation = try Self.decodeInvoiceCreation(row)
            if operation.state == .completed { return }
            guard operation.state == .pending, operation.invoiceRequest != nil else {
                throw StoreError.invalidDraft
            }
            if let reservation = operation.plan.reservation,
               (reservation.id != invoice.id || reservation.number != invoice.number) { throw StoreError.invalidCreationReceipt }
            if let receiptData: Data = row["journalReceipt"] {
                let receipt = try JSONDecoder().decode(InvoiceInitialPaymentReceipt.self, from: receiptData)
                guard receipt.invoice.id == invoice.id, receipt.invoice.number == invoice.number else {
                    throw StoreError.invalidCreationReceipt
                }
            }
            try Self.advanceLocalVersion(in: database)
            try database.execute(sql: """
                INSERT INTO invoiceSnapshots (id, number, payload, synchronizedAt, detailPayload)
                VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET number = excluded.number,
                    payload = excluded.payload, detailPayload = excluded.detailPayload, synchronizedAt = excluded.synchronizedAt
                WHERE NOT EXISTS (SELECT 1 FROM invoiceEdits WHERE invoiceID = excluded.id
                    AND state NOT IN ('completed', 'discarded', 'superseded'))
                """, arguments: [invoice.id, invoice.number, payload, Date.now.timeIntervalSince1970, payload])
            for attachment in operation.plan.content.attachments ?? [] {
                try database.execute(sql: "UPDATE invoiceAttachments SET invoiceID = ?, state = ? WHERE id = ? AND draftID = ? AND state = 'waiting'",
                    arguments: [invoice.id, invoice.hasDocumentContainer ? "pending" : "awaitingContainer", attachment.id.uuidString, operation.draftID.uuidString])
            }
            // Clear the previous failure in the same transaction that confirms the invoice.
            try database.execute(sql: "UPDATE invoiceCreations SET state = 'completed', invoiceID = ?, failure = NULL WHERE id = ?",
                                 arguments: [invoice.id, id.uuidString])
        }
    }

    /// Restores a queued creation after verifying the stored bytes and identities.
    private nonisolated static func decodeInvoiceCreation(_ row: Row) throws -> PendingInvoiceCreation {
        guard let id = UUID(uuidString: row["id"]), let draftID = UUID(uuidString: row["draftID"]),
              let state = PendingInvoiceCreation.State(rawValue: row["state"]) else {
                  throw StoreError.invalidDraft
              }
        let payload: Data = row["plan"]
        guard payload.count <= 3 * 1024 * 1024 else {
            throw StoreError.invalidDraft
        }
        let plan = try JSONDecoder().decode(InvoiceCreationPlan.self, from: payload)
        let journal: Data? = row["journalRequest"]
        let invoice: Data? = row["invoiceRequest"]
        try validateDraft(plan.content)
        let journalHash: Data? = row["journalHash"]
        let invoiceHash: Data? = row["invoiceHash"]
        guard journalHash == journal.map({ Data(SHA256.hash(data: $0)) }),
              invoiceHash == invoice.map({ Data(SHA256.hash(data: $0)) }),
              plan.invoiceRequestID == id, journal != nil || invoice != nil,
              (journal?.count ?? 0) <= 3 * 1024 * 1024, (invoice?.count ?? 0) <= 3 * 1024 * 1024 else {
                  throw StoreError.invalidDraft
              }
        let failureData: Data? = row["failure"]
        let receiptData: Data? = row["journalReceipt"]
        return PendingInvoiceCreation(id: id, draftID: draftID, state: state, plan: plan,
            journalRequest: journal, invoiceRequest: invoice, invoiceID: row["invoiceID"],
            failure: try failureData.map { try JSONDecoder().decode(PendingInvoiceCreation.Failure.self, from: $0) },
            paymentReceipt: try receiptData.map { try JSONDecoder().decode(InvoiceInitialPaymentReceipt.self, from: $0) })
    }

    /// Only the confirmed creation for this invoice can supply a local sender
    /// signature. Historical server-only invoices need their server report.
    func localSenderSignature(invoiceID: String) throws -> Data? {
        try readInvoiceDatabase { database in
            guard let row = try Row.fetchOne(database,
                sql: "SELECT * FROM invoiceCreations WHERE invoiceID = ? AND state = 'completed' ORDER BY createdAt DESC LIMIT 1",
                arguments: [invoiceID]) else {
                    return nil
                }
            let operation = try Self.decodeInvoiceCreation(row)
            let content = operation.plan.content
            guard let confirmation = content.confirmation, confirmation.isValid,
                  confirmation.matches(content), !confirmation.skipSignature,
                  let signature = content.senderSignature, signature.signerName == content.senderName,
                  let png = signature.pngData,
                  let payload = try Data.fetchOne(database, sql: "SELECT payload FROM invoiceSnapshots WHERE id = ?", arguments: [invoiceID]) else {
                      return nil
                  }
            let invoice = try JSONDecoder().decode(Invoice.self, from: payload)
            guard invoice.sender?.id == content.senderCustomer?.id,
                  invoice.sender?.id != nil,
                  invoice.sender?.name == content.senderName else {
                      return nil
                  }
            return png
        }
    }
}
