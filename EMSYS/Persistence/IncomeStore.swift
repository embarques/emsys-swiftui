import CryptoKit
import Foundation
import GRDB

/// Journal snapshots and outbox scoped to one API, tenant and user.
actor IncomeStore {
    enum StoreError: Error { case invalidScope, invalidReceipt }
    private let database: DatabaseQueue

    /// Opens the authenticated journal partition off the main actor.
    nonisolated static func open(directory: URL, userID: String, companyID: String,
                                 apiEnvironment: String = APIConfiguration.defaultRoot) async throws -> IncomeStore {
        try await Task.detached(priority: .utility) {
            try IncomeStore(directory: directory, userID: userID, companyID: companyID, apiEnvironment: apiEnvironment)
        }.value
    }

    /// Validates and creates the tenant-scoped journal database.
    private init(directory: URL, userID: String, companyID: String, apiEnvironment: String) throws {
        guard !userID.isEmpty, !companyID.isEmpty, !userID.contains("\0"), !companyID.contains("\0"),
              let root = URL(string: apiEnvironment), root.scheme == "https", root.host != nil,
              root.user == nil, root.password == nil, root.query == nil, root.fragment == nil else {
            throw StoreError.invalidScope
        }
        let identity = apiEnvironment.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "\0" + companyID + "\0" + userID
        let partition = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        var folder = directory.appending(path: partition, directoryHint: .isDirectory)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: attributes)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try folder.setResourceValues(resources)
        database = try DatabaseQueue(path: folder.appending(path: "income.sqlite").path)
        try database.write { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS incomePeriods (key TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS incomeJournalOutbox (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS incomeRevision (id INTEGER PRIMARY KEY, value INTEGER NOT NULL);
                INSERT OR IGNORE INTO incomeRevision (id, value) VALUES (1, 0);
                """)
        }
    }

    /// Builds the existing branch and date key for a journal period.
    private nonisolated static func periodKey(branchID: UInt16, day: InvoiceDate) -> String {
        "\(branchID):\(day.apiValue)"
    }

    /// Returns the downloaded period for the requested branch and day.
    func period(branchID: UInt16, day: InvoiceDate) throws -> IncomePeriod? {
        try database.read { try Self.period(branchID: branchID, day: day, in: $0) }
    }

    /// Reads posted activity and pending operations from the same SQLite snapshot.
    func activity(branchID: UInt16, day: InvoiceDate) throws -> (period: IncomePeriod?, pending: [PendingIncomeJournal]) {
        try database.read { database in
            let period = try Self.period(branchID: branchID, day: day, in: database)

            // Pending entries from older business days still need operator attention.
            let pending = try Self.outbox(in: database).filter { $0.branchID == branchID }
            return (period, pending)
        }
    }

    /// Returns the timezone from the branch’s latest cached period.
    func knownTimeZone(branchID: UInt16) throws -> String? {
        try database.read {
            let payload = try Data.fetchOne($0, sql: "SELECT payload FROM incomePeriods WHERE key LIKE ? ORDER BY key DESC LIMIT 1",
                                            arguments: ["\(branchID):%"])
            return try payload.map { try JSONDecoder().decode(IncomePeriod.self, from: $0).timeZone }
        }
    }

    /// Returns the revision used to detect a stale network refresh.
    func revision() throws -> Int64 {
        try database.read { try Self.revision(in: $0) }
    }

    /// Stores a refreshed period only if no intervening write advanced the revision.
    func save(_ period: IncomePeriod, ifUnchangedSince revision: Int64) throws -> Bool {
        try database.write { database in
            // A stale refresh may not overwrite a receipt saved after the read began.
            guard try Self.revision(in: database) == revision else {
                return false
            }
            try Self.save(period, in: database)
            try Self.advanceRevision(in: database)
            return true
        }
    }

    /// Durably records an operation with its original submission bytes.
    func enqueue(_ operation: PendingIncomeJournal) throws {
        try database.write { database in
            try database.execute(sql: "INSERT INTO incomeJournalOutbox (id, payload) VALUES (?, ?)",
                arguments: [operation.id.uuidString, try JSONEncoder().encode(operation)])
        }
    }

    /// Returns all pending and blocked journal entries in queue order.
    func outbox() throws -> [PendingIncomeJournal] {
        try database.read { database in
            try Self.outbox(in: database)
        }
    }

    /// Reads outbox records in queue order within the caller's transaction.
    private nonisolated static func outbox(in database: Database) throws -> [PendingIncomeJournal] {
        let payloads = try Data.fetchAll(database, sql: "SELECT payload FROM incomeJournalOutbox ORDER BY rowid")
        let decoder = JSONDecoder()
        return try payloads.map { try decoder.decode(PendingIncomeJournal.self, from: $0) }
    }

    /// Preserves the original request and records why operator review is required.
    func flagForReview(_ operation: PendingIncomeJournal, reason: String) throws {
        var blocked = operation
        blocked.reviewReason = reason
        let bytes = try JSONEncoder().encode(blocked)
        try database.write {
            try $0.execute(sql: "UPDATE incomeJournalOutbox SET payload = ? WHERE id = ?",
                arguments: [bytes, operation.id.uuidString])
        }
    }

    /// Applies a verified receipt at most once and removes its original outbox entry.
    func confirm(_ operation: PendingIncomeJournal, receipt: IncomeJournal) throws {
        guard InvoiceWriteDocument.isObjectID(receipt.id),
              receipt.transactionType == operation.request.entry.transactionType,
              receipt.transactionAmount == operation.request.entry.amount,
              receipt.incomeStatement?.id == operation.request.entry.incomeStatementId,
              receipt.currency == operation.currency else {
            throw StoreError.invalidReceipt
        }
        try database.write { database in
            guard try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM incomeJournalOutbox WHERE id = ?)",
                arguments: [operation.id.uuidString]) == true else {
                return
            }

            // Commit the server projection and remove the queued request together.
            if var period = try Self.period(branchID: operation.branchID, day: operation.day, in: database),
               period.statement?.id == receipt.incomeStatement?.id {
                period.journals.removeAll { $0.id == receipt.id }
                period.journals.insert(receipt, at: 0)
                try Self.save(period, in: database)
            }
            try database.execute(sql: "DELETE FROM incomeJournalOutbox WHERE id = ?", arguments: [operation.id.uuidString])
            try Self.advanceRevision(in: database)
        }
    }

    /// Decodes one period within the caller’s database transaction.
    private nonisolated static func period(branchID: UInt16, day: InvoiceDate, in database: Database) throws -> IncomePeriod? {
        let key = periodKey(branchID: branchID, day: day)
        return try Data.fetchOne(database, sql: "SELECT payload FROM incomePeriods WHERE key = ?", arguments: [key])
            .map { try JSONDecoder().decode(IncomePeriod.self, from: $0) }
    }

    /// Writes or replaces one cached period inside the current transaction.
    private nonisolated static func save(_ period: IncomePeriod, in database: Database) throws {
        try database.execute(sql: """
            INSERT INTO incomePeriods (key, payload) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET payload = excluded.payload
            """, arguments: [periodKey(branchID: period.branchID, day: period.day), try JSONEncoder().encode(period)])
    }

    /// Reads the journal database revision inside the active transaction.
    private nonisolated static func revision(in database: Database) throws -> Int64 {
        try Int64.fetchOne(database, sql: "SELECT value FROM incomeRevision WHERE id = 1") ?? 0
    }

    /// Advances the revision so in-flight downloads recognize newer local data.
    private nonisolated static func advanceRevision(in database: Database) throws {
        try database.execute(sql: "UPDATE incomeRevision SET value = value + 1 WHERE id = 1")
    }
}
