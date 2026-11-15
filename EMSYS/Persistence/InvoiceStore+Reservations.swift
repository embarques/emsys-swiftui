import CryptoKit
import Foundation
import GRDB

/// Offline invoice numbers and pool actions.
extension InvoiceStore {
    /// Returns the persistent device identity used to claim invoice numbers.
    func invoicePoolDeviceID() throws -> UUID {
        try writeInvoiceDatabase { database in
            if let stored = try String.fetchOne(database, sql: "SELECT deviceID FROM invoicePoolMetadata WHERE id = 1"), let id = UUID(uuidString: stored) { return id }
            let id = UUID()
            try database.execute(sql: "INSERT INTO invoicePoolMetadata (id, deviceID) VALUES (1, ?)", arguments: [id.uuidString.lowercased()])
            return id
        }
    }

    /// Counts unused invoice numbers in the local pool.
    func availableInvoiceReservationCount() throws -> Int {
        try readInvoiceDatabase { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM invoiceReservations WHERE state = 'available'") ?? 0 }
    }

    /// Reads the pool count and next number from the same SQLite snapshot.
    func invoiceNumberAvailability() throws -> (count: Int, nextNumber: String?) {
        try readInvoiceDatabase { database in
            let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM invoiceReservations WHERE state = 'available'") ?? 0
            return (count, try Self.nextInvoiceReservation(in: database)?.number)
        }
    }

    /// Reads the reserved-number screen from one consistent database snapshot.
    func invoicePoolStatus() throws -> (available: Int, reservations: [InvoiceReservation], threshold: Int, pendingCount: Int) {
        try readInvoiceDatabase { database in
            // The count, next choices, and queued actions must describe the same pool state.
            let available = try Int.fetchOne(database,
                sql: "SELECT COUNT(*) FROM invoiceReservations WHERE state = 'available'") ?? 0
            let reservations = try Self.availableInvoiceReservations(in: database)
            let threshold = try Int.fetchOne(database,
                sql: "SELECT lowThreshold FROM invoicePoolMetadata WHERE id = 1") ?? 10
            let actions = try Self.pendingInvoicePoolActions(in: database)
            return (available, reservations, threshold, actions.count)
        }
    }

    /// Returns the next available reservation in the database's selection order.
    nonisolated static func nextInvoiceReservation(in database: Database) throws -> InvoiceReservation? {
        guard let payload = try Data.fetchOne(database,
            sql: "SELECT payload FROM invoiceReservations WHERE state = 'available' ORDER BY id LIMIT 1") else {
                return nil
            }
        return try JSONDecoder().decode(InvoiceReservation.self, from: payload)
    }

    /// Persists the low-number warning threshold and advances the pool revision.
    func saveInvoicePoolThreshold(_ threshold: Int) throws {
        guard (0...10_000).contains(threshold) else {
            throw StoreError.invoiceReservationChanged
        }
        _ = try invoicePoolDeviceID()
        try writeInvoiceDatabase { database in
            try database.execute(sql: "UPDATE invoicePoolMetadata SET lowThreshold = ?, revision = revision + 1 WHERE id = 1", arguments: [threshold])
        }
    }

    /// Returns the warning threshold used by the invoice pool screens.
    func invoicePoolThreshold() throws -> Int {
        try readInvoiceDatabase { try Int.fetchOne($0, sql: "SELECT lowThreshold FROM invoicePoolMetadata WHERE id = 1") ?? 10 }
    }

    /// Returns the locally available reservations in selection order.
    func availableInvoiceReservations() throws -> [InvoiceReservation] {
        try readInvoiceDatabase { database in
            try Self.availableInvoiceReservations(in: database)
        }
    }

    /// Decodes the visible reservations inside the caller's read.
    private nonisolated static func availableInvoiceReservations(in database: Database) throws -> [InvoiceReservation] {
        let payloads = try Data.fetchAll(database,
            sql: "SELECT payload FROM invoiceReservations WHERE state = 'available' ORDER BY id LIMIT 100")
        let decoder = JSONDecoder()
        return try payloads.map { try decoder.decode(InvoiceReservation.self, from: $0) }
    }

    /// Reconcile only a completed download. Consumed and quarantined rows are
    /// protected even when the server still reports them as unused.
    func invoicePoolRevision() throws -> Int64 {
        try readInvoiceDatabase { try Int64.fetchOne($0, sql: "SELECT revision FROM invoicePoolMetadata WHERE id = 1") ?? 0 }
    }

    /// Applies a validated download while retaining locally consumed numbers.
    func reconcileInvoiceReservations(_ items: [InvoiceReservation], lowThreshold: Int, expectedRevision: Int64? = nil) throws {
        let deviceID = try invoicePoolDeviceID()
        guard lowThreshold >= 0, lowThreshold <= 10_000, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ $0.isValid(deviceID: deviceID) }) else {
                  throw StoreError.invoiceReservationChanged
              }
        let encoded = try items.map { ($0, try JSONEncoder().encode($0)) }
        try writeInvoiceDatabase { database in
            if let expectedRevision {
                let current = try Int64.fetchOne(database, sql: "SELECT revision FROM invoicePoolMetadata WHERE id = 1") ?? 0
                guard current == expectedRevision else {
                    throw StoreError.invoiceReservationChanged
                }
            }
            let available = try Row.fetchAll(database, sql: "SELECT id, token FROM invoiceReservations WHERE state = 'available'")
            let incoming = Set(items.map(\.id))
            for row in available {
                let id: String = row["id"]
                guard !incoming.contains(id) else {
                    continue
                }
                let token: String = row["token"]
                try database.execute(sql: "INSERT OR IGNORE INTO invoiceReservationRetiredTokens (id, token) VALUES (?, ?)", arguments: [id, token])
                try database.execute(sql: "UPDATE invoiceReservations SET state = 'returned' WHERE id = ? AND state = 'available'", arguments: [id])
            }
            for (item, payload) in encoded {
                guard try Int.fetchOne(database, sql: "SELECT 1 FROM invoiceReservationRetiredTokens WHERE id = ? AND token = ?", arguments: [item.id, item.allocation.token]) == nil else {
                    continue
                }
                try database.execute(sql: "INSERT OR IGNORE INTO invoiceReservationRetiredTokens (id, token) SELECT id, token FROM invoiceReservations WHERE id = ? AND token != ? AND state = 'available'", arguments: [item.id, item.allocation.token])
                try database.execute(sql: """
                    INSERT INTO invoiceReservations (id, token, state, payload) VALUES (?, ?, 'available', ?)
                    ON CONFLICT(id) DO UPDATE SET token = excluded.token, state = 'available', payload = excluded.payload
                    WHERE invoiceReservations.state = 'available'
                       OR (invoiceReservations.state = 'returned' AND invoiceReservations.token != excluded.token)
                    """, arguments: [item.id, item.allocation.token, payload])
            }
            try database.execute(sql: "UPDATE invoicePoolMetadata SET lowThreshold = ?, revision = revision + 1 WHERE id = 1", arguments: [lowThreshold])
        }
    }

    /// Returning quarantines local availability before the request can leave the
    /// device. A creation outbox operation has already marked its number consumed.
    func stageInvoicePoolAction(_ action: InvoicePoolAction) throws {
        let payload = try JSONEncoder().encode(action)
        try writeInvoiceDatabase { database in
            if action.action == .return {
                guard let proofs = action.items, !proofs.isEmpty, proofs.count <= 100 else {
                    throw StoreError.invoiceReservationChanged
                }
                for proof in proofs {
                    try database.execute(sql: "UPDATE invoiceReservations SET state = 'returning' WHERE id = ? AND token = ? AND state = 'available'", arguments: [proof.id, proof.token])
                    guard database.changesCount == 1 else {
                        throw StoreError.invoiceReservationChanged
                    }
                    try database.execute(sql: "INSERT OR IGNORE INTO invoiceReservationRetiredTokens (id, token) VALUES (?, ?)", arguments: [proof.id, proof.token])
                }
            }
            try database.execute(sql: "INSERT INTO invoicePoolActions (id, payload, createdAt) VALUES (?, ?, ?)", arguments: [action.requestId, payload, Date.now.timeIntervalSince1970])
            try database.execute(sql: "UPDATE invoicePoolMetadata SET revision = revision + 1 WHERE id = 1")
        }
    }

    /// Returns the exact request bytes saved for the pool action.
    func invoicePoolActionPayload(id: String) throws -> Data {
        try readInvoiceDatabase { database in
            guard let payload = try Data.fetchOne(database, sql: "SELECT payload FROM invoicePoolActions WHERE id = ?", arguments: [id]) else {
                throw StoreError.invoiceReservationChanged
            }
            return payload
        }
    }

    /// Restores pool requests that still need server acknowledgment.
    func pendingInvoicePoolActions() throws -> [InvoicePoolAction] {
        try readInvoiceDatabase { database in
            try Self.pendingInvoicePoolActions(in: database)
        }
    }

    /// Decodes the oldest pending actions inside the caller's read.
    private nonisolated static func pendingInvoicePoolActions(in database: Database) throws -> [InvoicePoolAction] {
        let payloads = try Data.fetchAll(database,
            sql: "SELECT payload FROM invoicePoolActions ORDER BY createdAt, id LIMIT 100")
        let decoder = JSONDecoder()
        return try payloads.map { try decoder.decode(InvoicePoolAction.self, from: $0) }
    }

    /// Applies the confirmed pool action and removes its outbox entry.
    func acknowledgeInvoicePoolAction(_ action: InvoicePoolAction) throws {
        try writeInvoiceDatabase { database in
            if action.action == .return {
                for proof in action.items ?? [] {
                    try database.execute(sql: "UPDATE invoiceReservations SET state = 'returned' WHERE id = ? AND token = ? AND state = 'returning'", arguments: [proof.id, proof.token])
                }
            }
            try database.execute(sql: "DELETE FROM invoicePoolActions WHERE id = ?", arguments: [action.requestId])
            try database.execute(sql: "UPDATE invoicePoolMetadata SET revision = revision + 1 WHERE id = 1")
        }
    }
}
