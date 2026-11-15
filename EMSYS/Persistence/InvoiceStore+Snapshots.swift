import CryptoKit
import Foundation
import GRDB

/// Invoice list and detail snapshots.
extension InvoiceStore {
    /// Updates invoice snapshots, optionally saving their ordered page membership.
    func saveDownloaded(_ invoices: [Invoice], page: Int? = nil, synchronizedAt: Date = .now, ifUnchangedSince version: Int64? = nil, asList: Bool = false) throws {
        // Validate the entire page before opening the transaction. A malformed
        // record must not leave a partially synchronized page on disk.
        guard invoices.allSatisfy({ Self.isObjectID($0.id) }) else {
            throw StoreError.invalidInvoiceID
        }
        if let page, page < 1 || invoices.count > 40 { throw StoreError.invalidPage }
        guard Set(invoices.map(\.id)).count == invoices.count else {
            throw StoreError.invalidPageContents
        }
        let encoder = JSONEncoder()
        let payloads = try invoices.map { try encoder.encode($0) }
        try writeInvoiceDatabase { database in
            if let version, try Self.downloadVersion(in: database) != version { return }
            for (invoice, payload) in zip(invoices, payloads) {
                let detailPayload: Data? = page == nil && !asList ? payload : nil
                try database.execute(sql: """
                    INSERT INTO invoiceSnapshots (id, number, payload, synchronizedAt, detailPayload)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET number = excluded.number,
                        payload = excluded.payload, synchronizedAt = excluded.synchronizedAt,
                        detailPayload = COALESCE(excluded.detailPayload, invoiceSnapshots.detailPayload)
                    WHERE NOT EXISTS (SELECT 1 FROM invoiceEdits WHERE invoiceID = excluded.id
                        AND state NOT IN ('completed', 'discarded', 'superseded'))
                    """, arguments: [invoice.id, invoice.number, payload, synchronizedAt.timeIntervalSince1970, detailPayload])
                if database.changesCount > 0 {
                    try Self.resumeAssignedAttachments(for: invoice, in: database)
                }
            }
            if let page {
                let invoiceIDs = try encoder.encode(invoices.map(\.id))
                try database.execute(sql: """
                    INSERT INTO invoicePages (page, invoiceIDs) VALUES (?, ?)
                    ON CONFLICT(page) DO UPDATE SET invoiceIDs = excluded.invoiceIDs
                    """, arguments: [page, invoiceIDs])
            }
        }
    }

    /// Restores the persisted invoices for a cached page in their original order.
    func page(_ number: Int) throws -> [Invoice]? {
        guard number > 0 else {
            throw StoreError.invalidPage
        }
        return try readInvoiceDatabase { database in
            guard let payload = try Data.fetchOne(database,
                sql: "SELECT invoiceIDs FROM invoicePages WHERE page = ?", arguments: [number]
            ) else {
                return nil
            }
            let invoiceIDs = try JSONDecoder().decode([String].self, from: payload)
            guard !invoiceIDs.isEmpty else {
                return []
            }
            guard invoiceIDs.count <= 40, Set(invoiceIDs).count == invoiceIDs.count,
                  invoiceIDs.allSatisfy(Self.isObjectID) else {
                throw StoreError.invalidPageContents
            }
            let placeholders = Array(repeating: "?", count: invoiceIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(database,
                sql: "SELECT id, payload FROM invoiceSnapshots WHERE id IN (\(placeholders))",
                arguments: StatementArguments(invoiceIDs)
            )
            let invoices = try Dictionary(uniqueKeysWithValues: rows.map { row in
                let id: String = row["id"]
                let payload: Data = row["payload"]
                return (id, try JSONDecoder().decode(Invoice.self, from: payload))
            })
            guard invoices.count == invoiceIDs.count else {
                throw StoreError.invalidPageContents
            }
            return invoiceIDs.compactMap { invoices[$0] }
        }
    }

    /// Lists previously cached pages that synchronization can refresh.
    func downloadedPages() throws -> [Int] {
        try readInvoiceDatabase { database in
            try Int.fetchAll(database, sql: "SELECT page FROM invoicePages ORDER BY page")
        }
    }

    /// Lists invoice identities with a full detail snapshot.
    func downloadedDetailIDs() throws -> [String] {
        try readInvoiceDatabase { database in
            try String.fetchAll(database, sql: "SELECT id FROM invoiceSnapshots WHERE detailPayload IS NOT NULL ORDER BY id")
        }
    }

    /// Reads a bounded slice of locally downloaded invoices.
    func invoices(limit: Int = 40, offset: Int = 0) throws -> [Invoice] {
        guard (1...200).contains(limit), offset >= 0 else {
            throw StoreError.invalidPage
        }
        return try readInvoiceDatabase { database in
            let payloads = try Data.fetchAll(database, sql: """
                SELECT payload FROM invoiceSnapshots
                ORDER BY number COLLATE NOCASE DESC, id DESC LIMIT ? OFFSET ?
                """, arguments: [limit, offset])
            return try payloads.map { try JSONDecoder().decode(Invoice.self, from: $0) }
        }
    }

    /// Searches the local invoice cache using the directory's filters.
    func matchingInvoices(_ query: InvoiceListQuery, limit: Int = InvoiceListQuery.batchSize, offset: Int = 0) throws -> [Invoice] {
        guard (1...200).contains(limit), offset >= 0 else {
            throw StoreError.invalidPage
        }
        let (predicate, values) = Self.invoicePredicate(query)
        return try readInvoiceDatabase { database in
            let payloads = try Data.fetchAll(database, sql: """
                SELECT payload FROM invoiceSnapshots WHERE \(predicate)
                ORDER BY json_extract(payload, '$.date') DESC, id DESC LIMIT ? OFFSET ?
                """, arguments: StatementArguments(values + [String(limit), String(offset)]))
            return try payloads.map { try JSONDecoder().decode(Invoice.self, from: $0) }
        }
    }

    /// Reads stored projections in the order requested by the caller.
    func cachedInvoices(ids: [String]) throws -> [Invoice] {
        guard ids.count <= 200, ids.allSatisfy(Self.isObjectID), Set(ids).count == ids.count else {
            throw StoreError.invalidPageContents
        }
        guard !ids.isEmpty else {
            return []
        }
        return try readInvoiceDatabase { database in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(database,
                sql: "SELECT id, payload FROM invoiceSnapshots WHERE id IN (\(placeholders))", arguments: StatementArguments(ids))
            let invoices = try Dictionary(uniqueKeysWithValues: rows.map { row in
                let id: String = row["id"]
                let payload: Data = row["payload"]
                return (id, try JSONDecoder().decode(Invoice.self, from: payload))
            })
            guard invoices.count == ids.count else {
                throw StoreError.invalidPageContents
            }
            return ids.compactMap { invoices[$0] }
        }
    }

    /// Totals the outstanding balances represented by the local cache.
    func downloadedBalance() throws -> Decimal {
        // Sum decimal values in bounded batches on the store actor, not SQLite
        // floating-point SUM or the UI thread. This is the downloaded scope.
        try readInvoiceDatabase { database in
            let cursor = try String.fetchCursor(database, sql: """
                SELECT CAST(json_extract(payload, '$.balance') AS TEXT) FROM invoiceSnapshots
                WHERE CAST(json_extract(payload, '$.balance') AS REAL) > 0
                """)
            var balance = Decimal.zero
            while let value = try cursor.next() {
                if let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) { balance += amount }
            }
            return balance
        }
    }

    /// Builds the SQL search predicate and binds the filter values separately.
    private nonisolated static func invoicePredicate(_ query: InvoiceListQuery) -> (String, [String]) {
        var clauses = ["1 = 1"]
        var values: [String] = []
        func contains(_ fields: [String], _ value: String) {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            clauses.append("(" + fields.map { "json_extract(payload, '$.\($0)') LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")")
            values.append(contentsOf: fields.map { _ in "%" + escaped + "%" })
        }
        if !query.normalizedText.isEmpty {
            contains(["number", "sender.name", "receiver.name", "container.name", "container.containerNumber"], query.normalizedText)
        }
        switch query.scope {
        case .all: break
        case .due: clauses.append("CAST(json_extract(payload, '$.balance') AS REAL) > 0")
        case .paid: clauses.append("json_extract(payload, '$.paidStatus') = 'CLOSED'")
        case .unsynced: clauses.append("0 = 1")
        case .incomplete: clauses.append("json_extract(payload, '$.registration') = 'PENDING'")
        }
        if !query.startDate.isEmpty {
            clauses.append("substr(json_extract(payload, '$.date'), 1, 10) >= ?")
            values.append(query.startDate)
        }
        if !query.endDate.isEmpty {
            clauses.append("substr(json_extract(payload, '$.date'), 1, 10) <= ?")
            values.append(query.endDate)
        }
        if !query.container.isEmpty { contains(["container.name"], query.container) }
        return (clauses.joined(separator: " AND "), values)
    }

    /// Returns the best stored projection for one invoice identity.
    func invoice(id: String) throws -> Invoice? {
        guard Self.isObjectID(id) else {
            throw StoreError.invalidInvoiceID
        }
        return try readInvoiceDatabase { database in
            guard let payload = try Data.fetchOne(database,
                sql: "SELECT COALESCE(detailPayload, payload) FROM invoiceSnapshots WHERE id = ?", arguments: [id]
            ) else {
                return nil
            }
            return try JSONDecoder().decode(Invoice.self, from: payload)
        }
    }

    /// Checks the canonical lowercase ObjectID representation used by EMSYS.
    nonisolated static func isObjectID(_ value: String) -> Bool {
        value.utf8.count == 24 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
