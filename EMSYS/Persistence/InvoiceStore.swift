import CryptoKit
import Foundation
import GRDB

/// One durable database per authenticated user and tenant. No unscoped database
/// handle is exposed to screens, and all disk/database work runs off MainActor.
actor InvoiceStore {
    enum StoreError: Error {
        case invalidScope
        case invalidInvoiceID
        case invalidPage
        case invalidPageContents
        case missingEditSnapshot
        case editAlreadyPending
        case invalidEditState
        case editSnapshotChanged
        case invalidDraft
        case draftChanged
    }

    func savePrintCompany(_ company: InvoicePrintCompany) throws {
        guard !company.name.isEmpty else { throw StoreError.invalidScope }
        let payload = try JSONEncoder().encode(company)
        try database.write { database in
            try database.execute(sql: "INSERT OR REPLACE INTO invoicePrintCompany (id, payload) VALUES (1, ?)", arguments: [payload])
        }
    }

    func printCompany() throws -> InvoicePrintCompany? {
        try database.read { database in
            guard let payload = try Data.fetchOne(database, sql: "SELECT payload FROM invoicePrintCompany WHERE id = 1") else { return nil }
            return try JSONDecoder().decode(InvoicePrintCompany.self, from: payload)
        }
    }

    private let database: DatabaseQueue

    nonisolated static func open(
        directory: URL,
        userID: String,
        companyID: String,
        apiEnvironment: String = APIConfiguration.defaultRoot
    ) async throws -> InvoiceStore {
        try await Task.detached(priority: .utility) {
            try InvoiceStore(directory: directory, userID: userID, companyID: companyID, apiEnvironment: apiEnvironment)
        }.value
    }

    private init(directory: URL, userID: String, companyID: String, apiEnvironment: String) throws {
        guard !userID.isEmpty, !companyID.isEmpty,
              !userID.contains("\0"), !companyID.contains("\0") else {
            throw StoreError.invalidScope
        }
        let environment = apiEnvironment.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let root = URL(string: environment), root.scheme == "https", root.host != nil,
              root.user == nil, root.password == nil, root.query == nil, root.fragment == nil else {
            throw StoreError.invalidScope
        }
        // Preserve the existing default-server cache location. Custom API roots
        // get separate partitions before they can acquire writable snapshots.
        let identity = environment == APIConfiguration.defaultRoot
            ? "\(companyID)\0\(userID)" : "\(environment)\0\(companyID)\0\(userID)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        let partition = digest.map { String(format: "%02x", $0) }.joined()
        var folder = directory.appending(path: partition, directoryHint: .isDirectory)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: attributes
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try folder.setResourceValues(resourceValues)

        var configuration = Configuration()
        configuration.label = "EMSYS.InvoiceStore"
        configuration.foreignKeysEnabled = true
        database = try DatabaseQueue(path: folder.appending(path: "invoices.sqlite").path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createInvoiceSnapshots") { database in
            try database.create(table: "invoiceSnapshots") { table in
                table.column("id", .text).primaryKey()
                table.column("number", .text)
                table.column("payload", .blob).notNull()
                table.column("synchronizedAt", .double).notNull()
            }
            try database.create(index: "invoiceSnapshotsByNumber", on: "invoiceSnapshots", columns: ["number", "id"])
        }
        migrator.registerMigration("createInvoicePages") { database in
            try database.create(table: "invoicePages") { table in
                table.column("page", .integer).primaryKey()
                table.column("invoiceIDs", .blob).notNull()
            }
        }
        migrator.registerMigration("preserveInvoiceDetailSnapshots") { database in
            try database.alter(table: "invoiceSnapshots") { table in
                table.add(column: "detailPayload", .blob)
            }
            // Existing rows may contain the only downloaded detail copy. Keep
            // them intact until a fresh detail response replaces that snapshot.
            try database.execute(sql: "UPDATE invoiceSnapshots SET detailPayload = payload")
        }
        migrator.registerMigration("createInvoiceDocuments") { database in
            try database.create(table: "invoiceDocuments") { table in
                table.column("id", .text).primaryKey()
                table.column("invoiceID", .text).notNull()
                table.column("reportID", .text).notNull()
                table.column("selection", .blob).notNull()
                table.column("savedAt", .double).notNull()
                table.column("pdf", .blob).notNull()
            }
            try database.create(index: "documentsByInvoice", on: "invoiceDocuments", columns: ["invoiceID", "savedAt"])
        }
        migrator.registerMigration("createInvoiceEdits") { database in
            try database.create(table: "invoiceCacheMetadata") { table in
                table.column("id", .integer).primaryKey()
                table.column("apiEnvironment", .text).notNull()
                table.column("localWriteVersion", .integer).notNull().defaults(to: 0)
            }
            try database.execute(sql: "INSERT INTO invoiceCacheMetadata (id, apiEnvironment) VALUES (1, ?)", arguments: [environment])
            try database.create(table: "invoiceEditSnapshots") { table in
                table.column("invoiceID", .text).primaryKey()
                table.column("revision", .text).notNull()
                table.column("payload", .blob).notNull()
            }
            try database.create(table: "invoiceEdits") { table in
                table.column("id", .text).primaryKey()
                table.column("invoiceID", .text).notNull()
                table.column("expectedRevision", .text).notNull()
                table.column("requestBody", .blob).notNull()
                table.column("changes", .blob).notNull()
                table.column("createdAt", .double).notNull()
                table.column("state", .text).notNull()
                table.column("attempts", .integer).notNull().defaults(to: 0)
            }
            try database.execute(sql: """
                CREATE UNIQUE INDEX activeEditByInvoice ON invoiceEdits(invoiceID)
                WHERE state NOT IN ('completed', 'discarded', 'superseded')
                """)
            try database.create(index: "pendingEditsByCreation", on: "invoiceEdits", columns: ["state", "createdAt", "id"])
        }
        migrator.registerMigration("indexActiveInvoiceEdits") { database in
            try database.execute(sql: """
                CREATE INDEX activeEditsByCreation ON invoiceEdits(createdAt, id)
                WHERE state NOT IN ('completed', 'discarded', 'superseded')
                """)
        }
        migrator.registerMigration("indexInvoiceNumbersCaseInsensitive") { database in
            // Match the list ordering so SQLite can page without sorting the
            // entire local cache every time another page is requested.
            try database.execute(sql: """
                CREATE INDEX invoiceSnapshotsByNumberCaseInsensitive
                ON invoiceSnapshots(number COLLATE NOCASE DESC, id DESC)
                """)
            try database.execute(sql: "DROP INDEX invoiceSnapshotsByNumber")
        }
        migrator.registerMigration("createInvoiceDrafts") { database in
            try database.create(table: "invoiceDrafts") { table in
                table.column("id", .text).primaryKey()
                table.column("revision", .integer).notNull()
                table.column("savedAt", .double).notNull()
                table.column("senderName", .text).notNull()
                table.column("receiverName", .text).notNull()
                table.column("itemCount", .integer).notNull()
                table.column("payload", .blob).notNull()
            }
            try database.execute(sql: "CREATE INDEX draftsBySaveTime ON invoiceDrafts(savedAt DESC, id DESC)")
        }
        migrator.registerMigration("cacheInvoicePrintCompany") { database in
            try database.create(table: "invoicePrintCompany") { table in
                table.column("id", .integer).primaryKey()
                table.column("payload", .blob).notNull()
            }
        }
        migrator.registerMigration("cacheInvoiceCustomers") { database in
            try database.create(table: "invoiceCustomers") { table in
                table.column("id", .text).primaryKey()
                table.column("role", .integer)
                table.column("searchText", .text).notNull()
                table.column("payload", .blob).notNull()
                table.column("savedAt", .double).notNull()
            }
            try database.create(index: "invoiceCustomersByRole", on: "invoiceCustomers", columns: ["role", "savedAt"])
        }
        migrator.registerMigration("cacheInvoicePolicies") { database in
            try database.create(table: "invoicePolicies") { table in
                table.column("id", .integer).primaryKey()
                table.column("payload", .blob).notNull()
            }
        }
        migrator.registerMigration("cacheInvoiceContainers") { database in
            try database.create(table: "invoiceContainers") { table in
                table.column("id", .integer).primaryKey()
                table.column("searchText", .text).notNull()
                table.column("payload", .blob).notNull()
            }
        }
        migrator.registerMigration("cacheInvoiceAssignments") { database in
            try database.create(table: "invoiceAssignmentCatalogs") { table in
                table.column("kind", .text).primaryKey()
                table.column("payload", .blob).notNull()
            }
        }
        migrator.registerMigration("cacheInvoiceItemCatalog") { database in
            try database.create(table: "invoiceItemCatalog") { table in
                table.column("id", .integer).primaryKey()
                table.column("payload", .blob).notNull()
            }
        }
        migrator.registerMigration("cacheInvoicePaymentReviews") { database in
            try database.create(table: "invoicePaymentReviews") { table in
                table.column("branchID", .integer).notNull()
                table.column("businessDate", .text).notNull()
                table.column("payload", .blob).notNull()
                table.primaryKey(["branchID", "businessDate"])
            }
        }
        migrator.registerMigration("cacheInvoiceCustomerWriteSnapshots") { database in
            try database.create(table: "invoiceCustomerWriteSnapshots") { table in
                table.column("id", .text).primaryKey()
                table.column("payload", .blob).notNull()
            }
        }
        migrator.registerMigration("cacheInvoiceBankAccounts") { database in
            try database.create(table: "invoiceBankAccounts") { table in
                table.column("id", .integer).primaryKey()
                table.column("payload", .blob).notNull()
            }
        }
        migrator.registerMigration("createInvoiceCreationOutbox") { database in
            try database.create(table: "invoiceCreations") { table in
                table.column("id", .text).primaryKey()
                table.column("draftID", .text).notNull().unique()
                table.column("state", .text).notNull()
                table.column("plan", .blob).notNull()
                table.column("journalRequest", .blob)
                table.column("journalHash", .blob)
                table.column("invoiceRequest", .blob)
                table.column("invoiceHash", .blob)
                table.column("journalReceipt", .blob)
                table.column("invoiceID", .text)
                table.column("createdAt", .double).notNull()
            }
            try database.create(index: "invoiceCreationsByState", on: "invoiceCreations", columns: ["state", "createdAt"])
        }
        migrator.registerMigration("createInvoiceAttachmentOutbox") { database in
            try database.create(table: "invoiceAttachments") { table in
                table.column("id", .text).primaryKey()
                table.column("draftID", .text).notNull().references("invoiceDrafts", onDelete: .cascade)
                table.column("metadata", .blob).notNull()
                table.column("bytes", .blob).notNull()
                table.column("invoiceID", .text)
                table.column("state", .text).notNull()
                table.column("documentID", .text)
            }
            try database.create(index: "invoiceAttachmentsByDraft", on: "invoiceAttachments", columns: ["draftID"])
            try database.create(index: "invoiceAttachmentsByState", on: "invoiceAttachments", columns: ["state"])
        }
        try migrator.migrate(database)
        let savedEnvironment = try database.read { try String.fetchOne($0, sql: "SELECT apiEnvironment FROM invoiceCacheMetadata WHERE id = 1") }
        guard savedEnvironment == environment else { throw StoreError.invalidScope }
    }

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
        try database.write { database in
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

    func page(_ number: Int) throws -> [Invoice]? {
        guard number > 0 else { throw StoreError.invalidPage }
        return try database.read { database in
            guard let payload = try Data.fetchOne(database,
                sql: "SELECT invoiceIDs FROM invoicePages WHERE page = ?", arguments: [number]
            ) else { return nil }
            let invoiceIDs = try JSONDecoder().decode([String].self, from: payload)
            guard !invoiceIDs.isEmpty else { return [] }
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
            guard invoices.count == invoiceIDs.count else { throw StoreError.invalidPageContents }
            return invoiceIDs.compactMap { invoices[$0] }
        }
    }

    func downloadedPages() throws -> [Int] {
        try database.read { database in
            try Int.fetchAll(database, sql: "SELECT page FROM invoicePages ORDER BY page")
        }
    }

    func downloadedDetailIDs() throws -> [String] {
        try database.read { database in
            try String.fetchAll(database, sql: "SELECT id FROM invoiceSnapshots WHERE detailPayload IS NOT NULL ORDER BY id")
        }
    }

    func invoices(limit: Int = 40, offset: Int = 0) throws -> [Invoice] {
        guard (1...200).contains(limit), offset >= 0 else { throw StoreError.invalidPage }
        return try database.read { database in
            let payloads = try Data.fetchAll(database, sql: """
                SELECT payload FROM invoiceSnapshots
                ORDER BY number COLLATE NOCASE DESC, id DESC LIMIT ? OFFSET ?
                """, arguments: [limit, offset])
            return try payloads.map { try JSONDecoder().decode(Invoice.self, from: $0) }
        }
    }

    func matchingInvoices(_ query: InvoiceListQuery, limit: Int = InvoiceListQuery.batchSize, offset: Int = 0) throws -> [Invoice] {
        guard (1...200).contains(limit), offset >= 0 else { throw StoreError.invalidPage }
        let (predicate, values) = Self.invoicePredicate(query)
        return try database.read { database in
            let payloads = try Data.fetchAll(database, sql: """
                SELECT payload FROM invoiceSnapshots WHERE \(predicate)
                ORDER BY json_extract(payload, '$.date') DESC, id DESC LIMIT ? OFFSET ?
                """, arguments: StatementArguments(values + [String(limit), String(offset)]))
            return try payloads.map { try JSONDecoder().decode(Invoice.self, from: $0) }
        }
    }

    func cachedInvoices(ids: [String]) throws -> [Invoice] {
        guard ids.count <= 200, ids.allSatisfy(Self.isObjectID), Set(ids).count == ids.count else {
            throw StoreError.invalidPageContents
        }
        guard !ids.isEmpty else { return [] }
        return try database.read { database in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(database,
                sql: "SELECT id, payload FROM invoiceSnapshots WHERE id IN (\(placeholders))", arguments: StatementArguments(ids))
            let invoices = try Dictionary(uniqueKeysWithValues: rows.map { row in
                let id: String = row["id"]
                let payload: Data = row["payload"]
                return (id, try JSONDecoder().decode(Invoice.self, from: payload))
            })
            guard invoices.count == ids.count else { throw StoreError.invalidPageContents }
            return ids.compactMap { invoices[$0] }
        }
    }

    func downloadedBalance() throws -> Decimal {
        // Sum decimal values in bounded batches on the store actor, not SQLite
        // floating-point SUM or the UI thread. This is the downloaded scope.
        try database.read { database in
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

    func invoice(id: String) throws -> Invoice? {
        guard Self.isObjectID(id) else { throw StoreError.invalidInvoiceID }
        return try database.read { database in
            guard let payload = try Data.fetchOne(database,
                sql: "SELECT COALESCE(detailPayload, payload) FROM invoiceSnapshots WHERE id = ?", arguments: [id]
            ) else { return nil }
            return try JSONDecoder().decode(Invoice.self, from: payload)
        }
    }

    func saveDocument(_ document: InvoiceDocument) throws {
        guard Self.isObjectID(document.selection.invoiceID),
              !document.reportID.isEmpty, document.reportID.utf8.count <= 200 else {
            throw DocumentError.invalidSelection
        }
        try InvoiceDocument.validate(document.pdf)
        let selection = try JSONEncoder().encode(document.selection)
        try database.write { database in
            try database.execute(sql: """
                INSERT INTO invoiceDocuments (id, invoiceID, reportID, selection, savedAt, pdf)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [document.id.uuidString, document.selection.invoiceID,
                    document.reportID, selection, document.savedAt.timeIntervalSince1970, document.pdf])
        }
    }

    func latestDocument(invoiceID: String) throws -> InvoiceDocument? {
        guard Self.isObjectID(invoiceID) else { throw StoreError.invalidInvoiceID }
        return try database.read { database in
            guard let row = try Row.fetchOne(database, sql: """
                SELECT id, reportID, selection, savedAt, pdf FROM invoiceDocuments
                WHERE invoiceID = ? ORDER BY savedAt DESC, id DESC LIMIT 1
                """, arguments: [invoiceID]) else { return nil }
            let selection = try JSONDecoder().decode(InvoiceSignatureSelection.self, from: row["selection"])
            guard selection.invoiceID == invoiceID, let id = UUID(uuidString: row["id"]) else {
                throw DocumentError.invalidSelection
            }
            let pdf: Data = row["pdf"]
            try InvoiceDocument.validate(pdf)
            return InvoiceDocument(id: id, reportID: row["reportID"], selection: selection,
                savedAt: Date(timeIntervalSince1970: row["savedAt"]), pdf: pdf)
        }
    }

    private nonisolated static func isObjectID(_ value: String) -> Bool {
        value.utf8.count == 24 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

extension InvoiceStore {
    /// A database version also protects against an older download arriving
    /// through another window/store instance after a local edit was confirmed.
    func downloadVersion() throws -> Int64 {
        try database.read { try Self.downloadVersion(in: $0) }
    }

    func saveEditSnapshot(_ snapshot: InvoiceEditSnapshot, ifUnchangedSince version: Int64? = nil) throws {
        guard let invoiceID = snapshot.invoice.id else { throw StoreError.invalidInvoiceID }
        try snapshot.validate(invoiceID: invoiceID)
        try database.write { database in
            if let version, try Self.downloadVersion(in: database) != version { return }
            try Self.writeEditSnapshot(snapshot, in: database)
        }
    }

    func editSnapshot(invoiceID: String) throws -> InvoiceEditSnapshot? {
        guard Self.isObjectID(invoiceID) else { throw StoreError.invalidInvoiceID }
        return try database.read { database in
            try Self.editSnapshot(invoiceID: invoiceID, in: database)
        }
    }

    @discardableResult
    func queueItemNames(invoiceID: String, names: [String: String], basedOn base: InvoiceEditSnapshot? = nil) throws -> PendingInvoiceEdit {
        guard Self.isObjectID(invoiceID) else { throw StoreError.invalidInvoiceID }
        return try database.write { database in
            guard try !Self.hasActiveEdit(invoiceID: invoiceID, in: database) else { throw StoreError.editAlreadyPending }
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

    func activeEdits(limit: Int = 40, offset: Int = 0) throws -> [PendingInvoiceEdit] {
        guard (1...100).contains(limit), offset >= 0 else { throw StoreError.invalidPage }
        return try database.read { database in
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
        try database.write { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM invoiceEdits WHERE id = ?", arguments: [editID.uuidString]) else {
                throw StoreError.invalidEditState
            }
            let edit = try Self.decodeEdit(row)
            guard edit.state == .needsReview else { throw StoreError.invalidEditState }
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

    func activeEdit(invoiceID: String) throws -> PendingInvoiceEdit? {
        guard Self.isObjectID(invoiceID) else { throw StoreError.invalidInvoiceID }
        return try database.read { database in
            guard let row = try Row.fetchOne(database, sql: """
                SELECT * FROM invoiceEdits WHERE invoiceID = ?
                AND state NOT IN ('completed', 'discarded', 'superseded') LIMIT 1
                """, arguments: [invoiceID]) else { return nil }
            return try Self.decodeEdit(row)
        }
    }

    func pendingEdits(limit: Int = 20) throws -> [PendingInvoiceEdit] {
        guard (1...100).contains(limit) else { throw StoreError.invalidPage }
        return try database.read { database in
            try Row.fetchAll(database, sql: """
                SELECT * FROM invoiceEdits WHERE state = 'pending'
                ORDER BY createdAt, id LIMIT ?
                """, arguments: [limit]).map(Self.decodeEdit)
        }
    }

    func activeEditCount() throws -> Int {
        try database.read { database in
            try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM invoiceEdits
                WHERE state NOT IN ('completed', 'discarded', 'superseded')
                """) ?? 0
        }
    }

    func retryBlockedEdits() throws {
        try database.write { database in
            try database.execute(sql: """
                UPDATE invoiceEdits SET state = 'pending'
                WHERE state IN ('authorizationRequired', 'serverUnavailable')
                """)
        }
    }

    func recordAttempt(editID: UUID) throws -> Bool {
        try database.write { database in
            try database.execute(sql: """
                UPDATE invoiceEdits SET attempts = attempts + 1 WHERE id = ? AND state = 'pending'
                """, arguments: [editID.uuidString])
            return database.changesCount == 1
        }
    }

    func requireReview(editID: UUID, state: PendingInvoiceEdit.State) throws {
        guard [.needsReview, .authorizationRequired, .serverUnavailable].contains(state) else {
            throw StoreError.invalidEditState
        }
        try database.write { database in
            try database.execute(sql: "UPDATE invoiceEdits SET state = ? WHERE id = ? AND state = 'pending'",
                arguments: [state.rawValue, editID.uuidString])
        }
    }

    func completeEdit(editID: UUID, snapshot: InvoiceEditSnapshot) throws {
        try database.write { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM invoiceEdits WHERE id = ?", arguments: [editID.uuidString]) else {
                throw StoreError.invalidEditState
            }
            let edit = try Self.decodeEdit(row)
            // A second uploader may acknowledge the same receipt. It must not
            // replace a newer local projection with an earlier response.
            if edit.state == .completed { return }
            guard edit.state == .pending else { throw StoreError.invalidEditState }
            try snapshot.validate(invoiceID: edit.invoiceID)
            try database.execute(sql: "UPDATE invoiceEdits SET state = 'completed' WHERE id = ?", arguments: [editID.uuidString])
            try Self.advanceLocalVersion(in: database)
            try Self.writeEditSnapshot(snapshot, in: database)
        }
    }

    private nonisolated static func downloadVersion(in database: Database) throws -> Int64 {
        guard let version = try Int64.fetchOne(database, sql: "SELECT localWriteVersion FROM invoiceCacheMetadata WHERE id = 1") else {
            throw StoreError.invalidEditState
        }
        return version
    }

    private nonisolated static func advanceLocalVersion(in database: Database) throws {
        try database.execute(sql: "UPDATE invoiceCacheMetadata SET localWriteVersion = localWriteVersion + 1 WHERE id = 1")
    }

    private nonisolated static func hasActiveEdit(invoiceID: String, in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: """
            SELECT EXISTS(SELECT 1 FROM invoiceEdits WHERE invoiceID = ?
                AND state NOT IN ('completed', 'discarded', 'superseded'))
            """, arguments: [invoiceID]) ?? false
    }

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

    private nonisolated static func writeEditSnapshot(_ snapshot: InvoiceEditSnapshot, in database: Database) throws {
        guard let invoiceID = snapshot.invoice.id else { throw StoreError.invalidInvoiceID }
        let payload = try snapshot.invoice.encoded()
        try database.execute(sql: """
            INSERT INTO invoiceEditSnapshots (invoiceID, revision, payload) VALUES (?, ?, ?)
            ON CONFLICT(invoiceID) DO UPDATE SET revision = excluded.revision, payload = excluded.payload
            """, arguments: [invoiceID, snapshot.revision, payload])
        if try !hasActiveEdit(invoiceID: invoiceID, in: database) {
            try writeProjection(snapshot.invoice, synchronizedAt: .now, in: database)
        }
    }

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

    private nonisolated static func decodeEdit(_ row: Row) throws -> PendingInvoiceEdit {
        guard let id = UUID(uuidString: row["id"]), let state = PendingInvoiceEdit.State(rawValue: row["state"]) else {
            throw StoreError.invalidEditState
        }
        let invoiceID: String = row["invoiceID"]
        let body: Data = row["requestBody"]
        guard isObjectID(invoiceID), body.count <= 3 * 1024 * 1024 else { throw StoreError.invalidEditState }
        let submission = try JSONDecoder().decode(InvoiceUpdateSubmission.self, from: body)
        let revision: String = row["expectedRevision"]
        guard submission.requestID == id, submission.invoice.id == invoiceID, submission.revision == revision else {
            throw StoreError.invalidEditState
        }
        let changes = try JSONDecoder().decode([InvoiceWriteDocument.ItemNameChange].self, from: row["changes"])
        guard !changes.isEmpty, Set(changes.map(\.itemID)).count == changes.count else { throw StoreError.invalidEditState }
        return PendingInvoiceEdit(id: id, invoiceID: invoiceID, invoiceNumber: submission.invoice.number, expectedRevision: revision, requestBody: body,
            changes: changes, createdAt: Date(timeIntervalSince1970: row["createdAt"]), state: state, attempts: row["attempts"])
    }

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


extension InvoiceStore {
    func draftSummaries(limit: Int = 40, offset: Int = 0) throws -> [InvoiceDraftSummary] {
        guard (1...100).contains(limit), offset >= 0 else { throw StoreError.invalidPage }
        return try database.read { database in
            try Row.fetchAll(database, sql: """
                SELECT d.id, d.revision, d.savedAt, d.senderName, d.receiverName, d.itemCount, c.state AS creationState,
                    (SELECT COUNT(*) FROM invoiceAttachments a WHERE a.draftID = d.id AND a.invoiceID IS NOT NULL AND a.state != 'completed') AS pendingAttachmentCount
                FROM invoiceDrafts d LEFT JOIN invoiceCreations c ON c.draftID = d.id
                ORDER BY d.savedAt DESC, d.id DESC LIMIT ? OFFSET ?
                """, arguments: [limit, offset]).map { row in
                guard let id = UUID(uuidString: row["id"]) else { throw StoreError.invalidDraft }
                return InvoiceDraftSummary(id: id, revision: row["revision"], savedAt: Date(timeIntervalSince1970: row["savedAt"]),
                    senderName: row["senderName"], receiverName: row["receiverName"], itemCount: row["itemCount"],
                    creationState: (row["creationState"] as String?).flatMap(PendingInvoiceCreation.State.init(rawValue:)),
                    pendingAttachmentCount: row["pendingAttachmentCount"])
            }
        }
    }

    func draft(id: UUID) throws -> InvoiceDraft? {
        try database.read { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT revision, savedAt, payload FROM invoiceDrafts WHERE id = ?",
                arguments: [id.uuidString]) else { return nil }
            let payload: Data = row["payload"]
            guard payload.count <= 3 * 1024 * 1024 else { throw StoreError.invalidDraft }
            let content = try JSONDecoder().decode(InvoiceDraft.Content.self, from: payload)
            try Self.validateDraft(content)
            let revision: Int64 = row["revision"]
            guard revision > 0 else { throw StoreError.invalidDraft }
            return InvoiceDraft(id: id, revision: revision, savedAt: Date(timeIntervalSince1970: row["savedAt"]), content: content)
        }
    }

    /// A revision predicate protects another window's saved form. Draft saves
    /// never create an invoice, reserve a number, record payment or request upload.
    func saveDraft(id: UUID, content: InvoiceDraft.Content, expectedRevision: Int64?) throws -> InvoiceDraft {
        try database.write { database in
            try Self.writeDraft(id: id, content: content, expectedRevision: expectedRevision, in: database)
        }
    }

    private nonisolated static func writeDraft(
        id: UUID, content: InvoiceDraft.Content, expectedRevision: Int64?, in database: Database
    ) throws -> InvoiceDraft {
        try validateDraft(content)
        let payload = try JSONEncoder().encode(content)
        guard payload.count <= 3 * 1024 * 1024 else { throw StoreError.invalidDraft }
        if let expectedRevision, expectedRevision <= 0 || expectedRevision == Int64.max { throw StoreError.invalidDraft }
        guard try Row.fetchOne(database, sql: "SELECT id FROM invoiceCreations WHERE draftID = ?", arguments: [id.uuidString]) == nil else { throw StoreError.draftChanged }
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
        guard database.changesCount == 1 else { throw StoreError.draftChanged }
        // Metadata can only refer to bytes already staged for this exact draft.
        for attachment in content.attachments ?? [] {
            guard let stored = try Data.fetchOne(database, sql: "SELECT metadata FROM invoiceAttachments WHERE id = ? AND draftID = ?",
                arguments: [attachment.id.uuidString, id.uuidString]),
                try JSONDecoder().decode(InvoiceAttachment.self, from: stored) == attachment else { throw StoreError.invalidDraft }
        }
        return InvoiceDraft(id: id, revision: revision, savedAt: savedAt, content: content)
    }

    func copyDraft(sourceID: UUID, content: InvoiceDraft.Content) throws -> InvoiceDraft {
        try database.write { database in
            guard try Row.fetchOne(database, sql: "SELECT id FROM invoiceCreations WHERE draftID = ?", arguments: [sourceID.uuidString]) == nil else { throw StoreError.draftChanged }
            let copyID = UUID()
            var copied = content
            copied.attachments = nil
            _ = try Self.writeDraft(id: copyID, content: copied, expectedRevision: nil, in: database)
            for attachment in content.attachments ?? [] {
                guard let row = try Row.fetchOne(database, sql: "SELECT metadata, bytes FROM invoiceAttachments WHERE id = ? AND draftID = ? AND state = 'waiting'", arguments: [attachment.id.uuidString, sourceID.uuidString]),
                      try JSONDecoder().decode(InvoiceAttachment.self, from: row["metadata"]) == attachment else { throw StoreError.invalidDraft }
                let bytes: Data = row["bytes"]
                guard attachment.validates(bytes) else { throw StoreError.invalidDraft }
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
            guard payload.count <= 3 * 1024 * 1024 else { throw StoreError.invalidDraft }
            try database.execute(sql: "UPDATE invoiceDrafts SET payload = ? WHERE id = ?", arguments: [payload, copyID.uuidString])
            return InvoiceDraft(id: copyID, revision: 1, savedAt: .now, content: copied)
        }
    }

    func deleteDraft(id: UUID, expectedRevision: Int64) throws {
        try database.write { database in
            guard try Row.fetchOne(database, sql: "SELECT id FROM invoiceCreations WHERE draftID = ? AND state != 'completed'", arguments: [id.uuidString]) == nil else { throw StoreError.draftChanged }
            guard try Row.fetchOne(database, sql: "SELECT id FROM invoiceAttachments WHERE draftID = ? AND invoiceID IS NOT NULL AND state != 'completed'", arguments: [id.uuidString]) == nil else { throw StoreError.draftChanged }
            try database.execute(sql: "DELETE FROM invoiceDrafts WHERE id = ? AND revision = ?", arguments: [id.uuidString, expectedRevision])
            guard database.changesCount == 1 else { throw StoreError.draftChanged }
        }
    }

    private nonisolated static func validateDraft(_ content: InvoiceDraft.Content) throws {
        guard content.date.pickerDate != nil, content.pickup?.id != 0, Set(content.items.map(\.id)).count == content.items.count else { throw StoreError.invalidDraft }
        let attachments = content.attachments ?? []
        guard Set(attachments.map(\.id)).count == attachments.count, attachments.allSatisfy(\.isValid) else { throw StoreError.invalidDraft }
        if let confirmation = content.confirmation, !confirmation.isValid { throw StoreError.invalidDraft }
        // Incomplete drafts may have a cleared sender name. Preserve their
        // image without treating it as a valid signature for submission.
        if let signature = content.senderSignature, signature.pngData == nil { throw StoreError.invalidDraft }
        if let policies = content.policies, !InvoicePolicy.validate(policies) { throw StoreError.invalidDraft }
        if let container = content.container, !container.isValid { throw StoreError.invalidDraft }
        if let review = content.paymentReview, !review.isValid { throw StoreError.invalidDraft }
        if let account = content.payment?.bankAccount, !account.isValid { throw StoreError.invalidDraft }
        switch content.pickupSource {
        case nil:
            guard content.pickupRoute == nil, content.pickupEmployee == nil else { throw StoreError.invalidDraft }
        case .route:
            guard content.pickupEmployee == nil else { throw StoreError.invalidDraft }
            if let route = content.pickupRoute, !route.isValid || !route.isPickup { throw StoreError.invalidDraft }
        case .warehouse, .office:
            guard content.pickupRoute == nil else { throw StoreError.invalidDraft }
            if let employee = content.pickupEmployee, !employee.isValid || !employee.isEligible { throw StoreError.invalidDraft }
        }
        for (snapshot, customer, addressID) in [
            (content.senderWriteSnapshot, content.senderCustomer, content.senderAddressID),
            (content.receiverWriteSnapshot, content.receiverCustomer, content.receiverAddressID)
        ] {
            if let snapshot {
                guard let customer, snapshot.matches(customer) else { throw StoreError.invalidDraft }
                _ = try snapshot.party(addressID: addressID)
            }
        }
        for (customer, name, addressID, role) in [
            (content.senderCustomer, content.senderName, content.senderAddressID, InvoiceCustomer.Role.sender),
            (content.receiverCustomer, content.receiverName, content.receiverAddressID, InvoiceCustomer.Role.receiver)
        ] {
            if let customer {
                guard customer.isValid, customer.name == name, customer.customerType == role.rawValue else { throw StoreError.invalidDraft }
                if let addressID {
                    guard InvoiceWriteDocument.isObjectID(addressID),
                          customer.addresses?.contains(where: { $0.id == addressID }) == true else { throw StoreError.invalidDraft }
                }
            } else if addressID != nil { throw StoreError.invalidDraft }
        }
    }

    /// The saved form and immutable first upload commit together. Network work
    /// starts only after this transaction returns successfully.
    func queueInvoiceCreation(draftID: UUID, expectedRevision: Int64?, plan: InvoiceCreationPlan) throws -> PendingInvoiceCreation {
        try Self.validateDraft(plan.content)
        let encoder = JSONEncoder()
        let content = try encoder.encode(plan.content)
        let frozen = try encoder.encode(plan)
        guard content.count <= 3 * 1024 * 1024, frozen.count <= 3 * 1024 * 1024 else { throw StoreError.invalidDraft }
        let journal = try plan.journalRequest()
        let invoice = journal == nil ? try plan.invoiceRequest() : nil
        let operationID = plan.invoiceRequestID
        let now = Date.now
        return try database.write { database in
            guard try Row.fetchOne(database, sql: "SELECT id FROM invoiceCreations WHERE draftID = ?", arguments: [draftID.uuidString]) == nil else {
                throw StoreError.draftChanged
            }
            if let expectedRevision {
                guard expectedRevision > 0, expectedRevision < Int64.max else { throw StoreError.invalidDraft }
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
            guard database.changesCount == 1 else { throw StoreError.draftChanged }
            for attachment in plan.content.attachments ?? [] {
                guard let stored = try Data.fetchOne(database, sql: "SELECT metadata FROM invoiceAttachments WHERE id = ? AND draftID = ?", arguments: [attachment.id.uuidString, draftID.uuidString]),
                      try JSONDecoder().decode(InvoiceAttachment.self, from: stored) == attachment else { throw StoreError.invalidDraft }
            }

            try database.execute(sql: """
                INSERT INTO invoiceCreations (id, draftID, state, plan, journalRequest, journalHash, invoiceRequest, invoiceHash, createdAt)
                VALUES (?, ?, 'pending', ?, ?, ?, ?, ?, ?)
                """, arguments: [operationID.uuidString, draftID.uuidString, frozen, journal, journal.map { Data(SHA256.hash(data: $0)) }, invoice, invoice.map { Data(SHA256.hash(data: $0)) }, now.timeIntervalSince1970])
            return PendingInvoiceCreation(id: operationID, draftID: draftID, state: .pending,
                plan: plan, journalRequest: journal, invoiceRequest: invoice, invoiceID: nil)
        }
    }

    func invoiceCreation(draftID: UUID) throws -> PendingInvoiceCreation? {
        try database.read {
            try Row.fetchOne($0, sql: "SELECT * FROM invoiceCreations WHERE draftID = ?", arguments: [draftID.uuidString])
                .map(Self.decodeInvoiceCreation)
        }
    }

    func pendingInvoiceCreations() throws -> [PendingInvoiceCreation] {
        try database.read {
            try Row.fetchAll($0, sql: "SELECT * FROM invoiceCreations WHERE state = 'pending' ORDER BY createdAt LIMIT 40")
                .map(Self.decodeInvoiceCreation)
        }
    }

    func activeInvoiceCreationCount() throws -> Int {
        try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM invoiceCreations WHERE state != 'completed'") ?? 0 }
    }

    func setInvoiceCreationState(id: UUID, state: PendingInvoiceCreation.State) throws {
        guard state != .completed else { throw StoreError.invalidDraft }
        try database.write {
            try $0.execute(sql: "UPDATE invoiceCreations SET state = ? WHERE id = ? AND state != 'completed'",
                           arguments: [state.rawValue, id.uuidString])
        }
    }

    func saveInitialPaymentReceipt(creationID: UUID, receipt: InvoiceInitialPaymentReceipt) throws {
        try database.write { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM invoiceCreations WHERE id = ?", arguments: [creationID.uuidString]) else { throw StoreError.invalidDraft }
            let operation = try Self.decodeInvoiceCreation(row)
            // Preserve the first confirmed result. Replayed journal responses
            // contain current totals and must not rebuild a submitted invoice.
            if operation.invoiceRequest != nil { return }
            guard operation.state == .pending, operation.journalRequest != nil else { throw StoreError.invalidDraft }
            let invoice = try operation.plan.invoiceRequest(receipt: receipt)
            try database.execute(sql: "UPDATE invoiceCreations SET journalReceipt = ?, invoiceRequest = ?, invoiceHash = ? WHERE id = ? AND invoiceRequest IS NULL",
                arguments: [try JSONEncoder().encode(receipt), invoice, Data(SHA256.hash(data: invoice)), creationID.uuidString])
        }
    }

    func completeInvoiceCreation(id: UUID, invoice: Invoice) throws {
        guard Self.isObjectID(invoice.id), invoice.number?.isEmpty == false else { throw StoreError.invalidInvoiceID }
        let payload = try JSONEncoder().encode(invoice)
        try database.write { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM invoiceCreations WHERE id = ?", arguments: [id.uuidString]) else { throw StoreError.invalidDraft }
            let operation = try Self.decodeInvoiceCreation(row)
            if operation.state == .completed { return }
            guard operation.state == .pending, operation.invoiceRequest != nil else { throw StoreError.invalidDraft }
            if let receiptData: Data = row["journalReceipt"] {
                let receipt = try JSONDecoder().decode(InvoiceInitialPaymentReceipt.self, from: receiptData)
                guard receipt.invoice.id == invoice.id, receipt.invoice.number == invoice.number else { throw StoreError.invalidDraft }
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
            try database.execute(sql: "UPDATE invoiceCreations SET state = 'completed', invoiceID = ? WHERE id = ?",
                                 arguments: [invoice.id, id.uuidString])
        }
    }

    private nonisolated static func decodeInvoiceCreation(_ row: Row) throws -> PendingInvoiceCreation {
        guard let id = UUID(uuidString: row["id"]), let draftID = UUID(uuidString: row["draftID"]),
              let state = PendingInvoiceCreation.State(rawValue: row["state"]) else { throw StoreError.invalidDraft }
        let payload: Data = row["plan"]
        guard payload.count <= 3 * 1024 * 1024 else { throw StoreError.invalidDraft }
        let plan = try JSONDecoder().decode(InvoiceCreationPlan.self, from: payload)
        let journal: Data? = row["journalRequest"]
        let invoice: Data? = row["invoiceRequest"]
        try validateDraft(plan.content)
        let journalHash: Data? = row["journalHash"]
        let invoiceHash: Data? = row["invoiceHash"]
        guard journalHash == journal.map({ Data(SHA256.hash(data: $0)) }),
              invoiceHash == invoice.map({ Data(SHA256.hash(data: $0)) }),
              plan.invoiceRequestID == id, journal != nil || invoice != nil,
              (journal?.count ?? 0) <= 3 * 1024 * 1024, (invoice?.count ?? 0) <= 3 * 1024 * 1024 else { throw StoreError.invalidDraft }
        return PendingInvoiceCreation(id: id, draftID: draftID, state: state, plan: plan,
            journalRequest: journal, invoiceRequest: invoice, invoiceID: row["invoiceID"])
    }

    func saveInvoiceBankAccounts(_ accounts: [InvoiceBankAccount]) throws {
        guard accounts.count <= 1000, accounts.allSatisfy(\.isValid),
              Set(accounts.map(\.id)).count == accounts.count else { throw StoreError.invalidPageContents }
        let encoded = try accounts.map { ($0.id, try JSONEncoder().encode($0)) }
        try database.write {
            try $0.execute(sql: "DELETE FROM invoiceBankAccounts")
            for (id, payload) in encoded {
                try $0.execute(sql: "INSERT INTO invoiceBankAccounts (id, payload) VALUES (?, ?)", arguments: [id, payload])
            }
        }
    }

    func invoiceBankAccounts() throws -> [InvoiceBankAccount] {
        try database.read {
            let payloads = try Data.fetchAll($0, sql: "SELECT payload FROM invoiceBankAccounts ORDER BY id LIMIT 1001")
            guard payloads.count <= 1000 else { throw StoreError.invalidPageContents }
            let accounts = try payloads.map { try JSONDecoder().decode(InvoiceBankAccount.self, from: $0) }
            guard accounts.allSatisfy(\.isValid) else { throw StoreError.invalidPageContents }
            return accounts
        }
    }

    func saveCustomerWriteSnapshot(_ snapshot: InvoiceCustomerWriteSnapshot) throws {
        guard snapshot.isValid else { throw StoreError.invalidDraft }
        let payload = try JSONEncoder().encode(snapshot)
        guard payload.count <= 512 * 1024 else { throw StoreError.invalidDraft }
        try database.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO invoiceCustomerWriteSnapshots (id, payload) VALUES (?, ?)",
                           arguments: [snapshot.id, payload])
        }
    }

    func customerWriteSnapshot(id: String) throws -> InvoiceCustomerWriteSnapshot? {
        try database.read {
            guard let payload = try Data.fetchOne($0, sql: "SELECT payload FROM invoiceCustomerWriteSnapshots WHERE id = ?", arguments: [id]) else { return nil }
            guard payload.count <= 512 * 1024 else { throw StoreError.invalidDraft }
            let snapshot = try JSONDecoder().decode(InvoiceCustomerWriteSnapshot.self, from: payload)
            guard snapshot.id == id, snapshot.isValid else { throw StoreError.invalidDraft }
            return snapshot
        }
    }

    func saveCustomers(_ customers: [InvoiceCustomer]) throws {
        guard customers.count <= 40, customers.allSatisfy(\.isValid),
              Set(customers.map(\.id)).count == customers.count else { throw StoreError.invalidPageContents }
        let encoded = try customers.map { ($0, try JSONEncoder().encode($0)) }
        try database.write { database in
            for (customer, payload) in encoded {
                try database.execute(sql: """
                    INSERT OR REPLACE INTO invoiceCustomers (id, role, searchText, payload, savedAt)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [customer.id, customer.customerType, customer.searchText, payload, Date.now.timeIntervalSince1970])
            }
        }
    }

    func savePolicies(_ policies: [InvoicePolicy]) throws {
        guard InvoicePolicy.validate(policies) else { throw StoreError.invalidPageContents }
        let payload = try JSONEncoder().encode(policies)
        guard payload.count <= 2 * 1024 * 1024 else { throw StoreError.invalidPageContents }
        try database.write { database in
            try database.execute(sql: "INSERT OR REPLACE INTO invoicePolicies (id, payload) VALUES (1, ?)", arguments: [payload])
        }
    }

    func policies() throws -> [InvoicePolicy]? {
        try database.read { database in
            guard let payload = try Data.fetchOne(database, sql: "SELECT payload FROM invoicePolicies WHERE id = 1") else { return nil }
            return try JSONDecoder().decode([InvoicePolicy].self, from: payload)
        }
    }

    func saveContainers(_ containers: [InvoiceContainer]) throws {
        guard containers.count <= 40, containers.allSatisfy(\.isValid),
              Set(containers.map(\.id)).count == containers.count else { throw StoreError.invalidPageContents }
        let encoded = try containers.map { ($0, try JSONEncoder().encode($0)) }
        try database.write { database in
            for (container, payload) in encoded {
                try database.execute(sql: "INSERT OR REPLACE INTO invoiceContainers (id, searchText, payload) VALUES (?, ?, ?)",
                    arguments: [container.id, container.searchText, payload])
            }
        }
    }

    func containers(matching query: String) throws -> [InvoiceContainer] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_DO"))
        return try database.read { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT payload FROM invoiceContainers WHERE instr(searchText, ?) > 0 ORDER BY id DESC LIMIT 40
                """, arguments: [term])
            return try rows.map { try JSONDecoder().decode(InvoiceContainer.self, from: $0["payload"] as Data) }
        }
    }

    func customers(matching query: String, role: InvoiceCustomer.Role) throws -> [InvoiceCustomer] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_DO"))
        return try database.read { database in
            // instr treats %, _ and quotes as literal search text.
            let rows = try Row.fetchAll(database, sql: """
                SELECT payload FROM invoiceCustomers WHERE role = ? AND instr(searchText, ?) > 0
                ORDER BY savedAt DESC, id LIMIT 40
                """, arguments: [role.rawValue, term])
            return try rows.map { try JSONDecoder().decode(InvoiceCustomer.self, from: $0["payload"] as Data) }
        }
    }

    func savePickupRoutes(_ routes: [InvoicePickupRoute]) throws {
        guard routes.allSatisfy({ $0.isValid && $0.isPickup }) else { throw StoreError.invalidPageContents }
        try saveAssignmentCatalog(routes, kind: "routes")
    }

    func pickupRoutes() throws -> [InvoicePickupRoute]? {
        try assignmentCatalog(kind: "routes", as: InvoicePickupRoute.self)
    }

    func savePickupEmployees(_ employees: [InvoicePickupEmployee]) throws {
        guard employees.allSatisfy({ $0.isValid && $0.isEligible }) else { throw StoreError.invalidPageContents }
        try saveAssignmentCatalog(employees, kind: "employees")
    }

    func pickupEmployees() throws -> [InvoicePickupEmployee]? {
        try assignmentCatalog(kind: "employees", as: InvoicePickupEmployee.self)
    }

    func savePickupBranches(_ branches: [InvoicePickupBranch]) throws {
        guard branches.allSatisfy({ $0.id > 0 }) else { throw StoreError.invalidPageContents }
        try saveAssignmentCatalog(branches, kind: "branches")
    }

    func pickupBranches() throws -> [InvoicePickupBranch]? {
        try assignmentCatalog(kind: "branches", as: InvoicePickupBranch.self)
    }

    func savePaymentReview(_ review: InvoicePaymentReview) throws {
        guard review.isValid else { throw StoreError.invalidPageContents }
        let payload = try JSONEncoder().encode(review)
        guard payload.count <= 256 * 1024 else { throw StoreError.invalidPageContents }
        try database.write { database in
            try database.execute(sql: """
                INSERT OR REPLACE INTO invoicePaymentReviews (branchID, businessDate, payload) VALUES (?, ?, ?)
                """, arguments: [review.branchID, review.day.apiValue, payload])
        }
    }

    func paymentReview(branchID: UInt16, day: InvoiceDate) throws -> InvoicePaymentReview? {
        guard branchID > 0, day.pickerDate != nil else { throw StoreError.invalidPageContents }
        return try database.read { database in
            guard let payload = try Data.fetchOne(database, sql: "SELECT payload FROM invoicePaymentReviews WHERE branchID = ? AND businessDate = ?",
                arguments: [branchID, day.apiValue]) else { return nil }
            let review = try JSONDecoder().decode(InvoicePaymentReview.self, from: payload)
            guard review.isValid, review.branchID == branchID, review.day == day else { throw StoreError.invalidPageContents }
            return review
        }
    }

    private func saveAssignmentCatalog<Item: Encodable & Identifiable>(_ items: [Item], kind: String) throws {
        guard items.count <= 1_000, Set(items.map(\.id)).count == items.count else { throw StoreError.invalidPageContents }
        let payload = try JSONEncoder().encode(items)
        guard payload.count <= 2 * 1024 * 1024 else { throw StoreError.invalidPageContents }
        try database.write { database in
            try database.execute(sql: "INSERT OR REPLACE INTO invoiceAssignmentCatalogs (kind, payload) VALUES (?, ?)", arguments: [kind, payload])
        }
    }

    private func assignmentCatalog<Item: Decodable & Identifiable>(kind: String, as type: Item.Type) throws -> [Item]? {
        try database.read { database in
            guard let payload = try Data.fetchOne(database, sql: "SELECT payload FROM invoiceAssignmentCatalogs WHERE kind = ?", arguments: [kind]) else { return nil }
            let items = try JSONDecoder().decode([Item].self, from: payload)
            guard items.count <= 1_000, Set(items.map(\.id)).count == items.count else { throw StoreError.invalidPageContents }
            return items
        }
    }
}


extension InvoiceStore {
    /// Imported bytes and the form referencing them commit together, including
    /// the first save of a previously unsaved draft.
    func stageAttachment(
        _ attachment: InvoiceAttachment, bytes: Data, draftID: UUID,
        content: InvoiceDraft.Content, expectedRevision: Int64?
    ) throws -> InvoiceDraft {
        guard attachment.validates(bytes) else { throw StoreError.invalidDraft }
        return try database.write { database in
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
            guard payload.count <= 3 * 1024 * 1024 else { throw StoreError.invalidDraft }
            try database.execute(sql: "UPDATE invoiceDrafts SET payload = ? WHERE id = ?", arguments: [payload, draftID.uuidString])
            return InvoiceDraft(id: draftID, revision: (expectedRevision ?? 0) + 1, savedAt: .now, content: savedContent)
        }
    }

    func removeAttachment(id: UUID, draftID: UUID, content: InvoiceDraft.Content, expectedRevision: Int64) throws -> InvoiceDraft {
        try database.write { database in
            guard try Row.fetchOne(database, sql: "SELECT id FROM invoiceAttachments WHERE id = ? AND draftID = ? AND state = 'waiting'", arguments: [id.uuidString, draftID.uuidString]) != nil else { throw StoreError.invalidDraft }
            var updated = content
            updated.attachments = (content.attachments ?? []).filter { $0.id != id }
            let saved = try Self.writeDraft(id: draftID, content: updated, expectedRevision: expectedRevision, in: database)
            try database.execute(sql: "DELETE FROM invoiceAttachments WHERE id = ?", arguments: [id.uuidString])
            return saved
        }
    }

    func invoiceAttachments(draftID: UUID? = nil, pendingOnly: Bool = false) throws -> [PendingInvoiceAttachment] {
        try database.read { database in
            let rows: [Row]
            if let draftID {
                rows = try Row.fetchAll(database, sql: "SELECT metadata, invoiceID, state FROM invoiceAttachments WHERE draftID = ? ORDER BY id", arguments: [draftID.uuidString])
            } else {
                rows = try Row.fetchAll(database, sql: "SELECT metadata, invoiceID, state FROM invoiceAttachments WHERE state = ? LIMIT 40", arguments: [pendingOnly ? "pending" : "waiting"])
            }
            return try rows.map { row in
                let metadata: Data = row["metadata"]
                let attachment = try JSONDecoder().decode(InvoiceAttachment.self, from: metadata)
                guard attachment.isValid, let state = PendingInvoiceAttachment.State(rawValue: row["state"]) else { throw StoreError.invalidDraft }
                return PendingInvoiceAttachment(attachment: attachment, invoiceID: row["invoiceID"], state: state)
            }
        }
    }

    func attachmentBody(id: UUID) throws -> Data {
        try database.read { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT metadata, bytes FROM invoiceAttachments WHERE id = ?", arguments: [id.uuidString]) else { throw StoreError.invalidDraft }
            let attachment = try JSONDecoder().decode(InvoiceAttachment.self, from: row["metadata"])
            return try attachment.multipart(bytes: row["bytes"])
        }
    }

    func setAttachmentState(id: UUID, state: PendingInvoiceAttachment.State) throws {
        guard state != .completed, state != .waiting else { throw StoreError.invalidDraft }
        try database.write { database in
            // A user retry cannot invent a container assignment. Only a
            // downloaded server invoice can release this waiting state.
            try database.execute(sql: "UPDATE invoiceAttachments SET state = ? WHERE id = ? AND invoiceID IS NOT NULL AND state NOT IN ('completed', 'awaitingContainer')",
                arguments: [state.rawValue, id.uuidString])
        }
    }

    private nonisolated static func resumeAssignedAttachments(for invoice: Invoice, in database: Database) throws {
        guard invoice.hasDocumentContainer else { return }
        try database.execute(sql: "UPDATE invoiceAttachments SET state = 'pending' WHERE invoiceID = ? AND state = 'awaitingContainer'",
            arguments: [invoice.id])
    }

    func completeAttachment(_ pending: PendingInvoiceAttachment, receipt: InvoiceDocumentReceipt) throws {
        guard Self.isObjectID(receipt.id), receipt.invoiceId == pending.invoiceID,
              receipt.originalName == pending.attachment.name.trimmingCharacters(in: .whitespacesAndNewlines),
              receipt.mimeType == pending.attachment.mimeType,
              receipt.size == pending.attachment.size else { throw StoreError.invalidDraft }
        try database.write { database in
            try database.execute(sql: "UPDATE invoiceAttachments SET state = 'completed', documentID = ? WHERE id = ? AND invoiceID = ? AND state = 'pending'",
                arguments: [receipt.id, pending.id.uuidString, receipt.invoiceId])
        }
    }

    func activeAttachmentCount(excludingAwaitingContainer: Bool = false) throws -> Int {
        try database.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM invoiceAttachments WHERE invoiceID IS NOT NULL AND state != 'completed' AND (? = 0 OR state != 'awaitingContainer')", arguments: [excludingAwaitingContainer]) ?? 0
        }
    }
}


extension InvoiceStore {
    func saveItemCatalog(_ items: [InvoiceCatalogItem]) throws {
        guard items.count <= 1_000, items.allSatisfy(\.isValid), Set(items.map(\.id)).count == items.count else {
            throw StoreError.invalidPageContents
        }
        let payload = try JSONEncoder().encode(items)
        guard payload.count <= 2 * 1024 * 1024 else { throw StoreError.invalidPageContents }
        try database.write { database in
            try database.execute(sql: "INSERT OR REPLACE INTO invoiceItemCatalog (id, payload) VALUES (1, ?)", arguments: [payload])
        }
    }

    func itemCatalog() throws -> [InvoiceCatalogItem] {
        try database.read { database in
            guard let payload = try Data.fetchOne(database, sql: "SELECT payload FROM invoiceItemCatalog WHERE id = 1") else { return [] }
            return try JSONDecoder().decode([InvoiceCatalogItem].self, from: payload)
        }
    }
}


extension InvoiceStore {
    /// Only the confirmed creation for this invoice can supply a local sender
    /// signature. Historical server-only invoices need their server report.
    func localSenderSignature(invoiceID: String) throws -> Data? {
        try database.read { database in
            guard let row = try Row.fetchOne(database,
                sql: "SELECT * FROM invoiceCreations WHERE invoiceID = ? AND state = 'completed' ORDER BY createdAt DESC LIMIT 1",
                arguments: [invoiceID]) else { return nil }
            let operation = try Self.decodeInvoiceCreation(row)
            let content = operation.plan.content
            guard let confirmation = content.confirmation, confirmation.isValid,
                  confirmation.matches(content), !confirmation.skipSignature,
                  let signature = content.senderSignature, signature.signerName == content.senderName,
                  let png = signature.pngData,
                  let payload = try Data.fetchOne(database, sql: "SELECT payload FROM invoiceSnapshots WHERE id = ?", arguments: [invoiceID]) else { return nil }
            let invoice = try JSONDecoder().decode(Invoice.self, from: payload)
            guard invoice.sender?.id == content.senderCustomer?.id,
                  invoice.sender?.id != nil,
                  invoice.sender?.name == content.senderName else { return nil }
            return png
        }
    }
}
