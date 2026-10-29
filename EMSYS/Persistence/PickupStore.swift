import CryptoKit
import Foundation
import GRDB

/// Server snapshots and durable offline completion operations partitioned by API, tenant and authenticated user.
actor PickupStore {
    enum StoreError: Error { case invalidScope, invalidRecords, changed, needsDownload, pendingOperation }
    private let database: DatabaseQueue

    nonisolated static func open(directory: URL, userID: String, companyID: String,
                                 apiEnvironment: String = APIConfiguration.defaultRoot) async throws -> PickupStore {
        try await Task.detached(priority: .utility) {
            try PickupStore(directory: directory, userID: userID, companyID: companyID, apiEnvironment: apiEnvironment)
        }.value
    }

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
        database = try DatabaseQueue(path: folder.appending(path: "pickups.sqlite").path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createPickupSnapshots") { database in
            try database.create(table: "pickupSnapshots") { table in
                table.column("id", .integer).primaryKey()
                table.column("payload", .blob).notNull()
                table.column("synchronizedAt", .double).notNull()
            }
        }
        migrator.registerMigration("queuePickupCompletion") { database in
            try database.alter(table: "pickupSnapshots") { $0.add(column: "revision", .text); $0.add(column: "hidden", .boolean).notNull().defaults(to: false) }
            try database.create(table: "pickupCompletions") { table in
                table.column("id", .text).primaryKey()
                table.column("pickupID", .integer).notNull().unique()
                table.column("request", .blob).notNull()
                table.column("state", .text).notNull()
            }
        }
        migrator.registerMigration("cachePickupInvoiceContext") { database in
            try database.create(table: "pickupInvoiceContexts") { table in
                table.column("pickupID", .integer).notNull()
                table.column("receiverID", .text).notNull()
                table.column("payload", .blob).notNull()
                table.primaryKey(["pickupID", "receiverID"])
            }
        }
        try migrator.migrate(database)
    }

    func save(_ pickups: [Pickup]) throws {
        guard pickups.allSatisfy({ $0.id > 0 }), Set(pickups.map(\.id)).count == pickups.count else {
            throw StoreError.invalidRecords
        }
        let encoded = try pickups.map { ($0.id, try JSONEncoder().encode($0)) }
        try database.write { database in
            for (id, payload) in encoded {
                try database.execute(sql: "INSERT INTO pickupSnapshots (id, payload, synchronizedAt) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, synchronizedAt = excluded.synchronizedAt, revision = NULL, hidden = 0",
                    arguments: [id, payload, Date.now.timeIntervalSince1970])
            }
        }
    }

    func pickups(matching query: PickupListQuery) throws -> [Pickup] {
        try database.read { database in
            let pending = Set(try Int64.fetchAll(database, sql: "SELECT pickupID FROM pickupCompletions WHERE state != 'completed'"))
            return try Data.fetchAll(database, sql: "SELECT payload FROM pickupSnapshots WHERE hidden = 0 ORDER BY id DESC")
                .map { try JSONDecoder().decode(Pickup.self, from: $0) }
                .map { source in
                    var pickup = source
                    if pending.contains(Int64(pickup.id)) { pickup.completed = true; pickup.pendingCompletion = true }
                    return pickup
                }
                .filter { query.matches($0) }
                .sorted { left, right in
                    if left.date != right.date { return (left.date ?? "") > (right.date ?? "") }
                    return left.id > right.id
                }
        }
    }

    func pickup(id: UInt32) throws -> Pickup? {
        try database.read { database in
            guard let data = try Data.fetchOne(database, sql: "SELECT payload FROM pickupSnapshots WHERE id = ? AND hidden = 0", arguments: [id]) else { return nil }
            return try Self.project(JSONDecoder().decode(Pickup.self, from: data), in: database)
        }
    }

    func remove(id: UInt32) throws {
        try database.write { database in
            try database.execute(sql: "UPDATE pickupSnapshots SET hidden = 1 WHERE id = ?", arguments: [id])
            try database.execute(sql: "DELETE FROM pickupSnapshots WHERE id = ? AND id NOT IN (SELECT pickupID FROM pickupCompletions WHERE state != 'completed')", arguments: [id])
        }
    }

    func removeAll() throws {
        try database.write { database in
            try database.execute(sql: "UPDATE pickupSnapshots SET hidden = 1")
            try database.execute(sql: "DELETE FROM pickupSnapshots WHERE id NOT IN (SELECT pickupID FROM pickupCompletions WHERE state != 'completed')")
        }
    }
    private nonisolated static func project(_ source: Pickup, in database: Database) throws -> Pickup {
        var pickup = source
        let active = try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM pickupCompletions WHERE pickupID = ? AND state != 'completed')", arguments: [pickup.id]) ?? false
        if active { pickup.completed = true; pickup.pendingCompletion = true }
        return pickup
    }

    func save(_ snapshot: PickupSyncSnapshot) throws { try save([snapshot]) }

    func save(_ snapshots: [PickupSyncSnapshot]) throws {
        guard snapshots.allSatisfy(\.isValid), Set(snapshots.map { $0.pickup.id }).count == snapshots.count else { throw StoreError.invalidRecords }
        try database.write { database in
            for snapshot in snapshots { try Self.write(snapshot, in: database) }
        }
    }

    func activeCompletionCount() throws -> Int {
        try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pickupCompletions WHERE state != 'completed'") ?? 0 }
    }

    private nonisolated static func write(_ snapshot: PickupSyncSnapshot, in database: Database) throws {
        let payload = try JSONEncoder().encode(snapshot.pickup)
        try database.execute(sql: "INSERT INTO pickupSnapshots (id, payload, revision, synchronizedAt) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, revision = excluded.revision, synchronizedAt = excluded.synchronizedAt, hidden = 0",
            arguments: [snapshot.pickup.id, payload, snapshot.revision, Date.now.timeIntervalSince1970])
    }

    func revision(id: UInt32) throws -> String? {
        try database.read { try String.fetchOne($0, sql: "SELECT revision FROM pickupSnapshots WHERE id = ?", arguments: [id]) }
    }

    func queueCompletion(id: UInt32, revision: String) throws -> PickupCompletion {
        let operationID = UUID()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let request = try encoder.encode(PickupCompletion.Request(requestId: operationID.uuidString.lowercased(), revision: revision))
        return try database.write { database in
            if let row = try Row.fetchOne(database, sql: "SELECT * FROM pickupCompletions WHERE pickupID = ? AND state != 'completed'", arguments: [id]) {
                return try Self.completion(row)
            }
            guard let row = try Row.fetchOne(database, sql: "SELECT payload, revision FROM pickupSnapshots WHERE id = ? AND hidden = 0", arguments: [id]),
                  let current: String = row["revision"] else { throw StoreError.needsDownload }
            guard current == revision else { throw StoreError.changed }
            let raw: Data = row["payload"]
            let pickup = try JSONDecoder().decode(Pickup.self, from: raw)
            guard !pickup.isComplete else { throw StoreError.changed }
            try database.execute(sql: "DELETE FROM pickupCompletions WHERE pickupID = ? AND state = 'completed'", arguments: [id])
            try database.execute(sql: "INSERT INTO pickupCompletions (id, pickupID, request, state) VALUES (?, ?, ?, 'pending')",
                arguments: [operationID.uuidString, id, request])
            return PickupCompletion(id: operationID, pickupID: id, request: request, state: .pending)
        }
    }

    private nonisolated static func completion(_ row: Row) throws -> PickupCompletion {
        guard let id = UUID(uuidString: row["id"]), let state = PickupCompletion.State(rawValue: row["state"]),
              let pickupID = UInt32(exactly: row["pickupID"] as Int64) else { throw StoreError.invalidRecords }
        return PickupCompletion(id: id, pickupID: pickupID, request: row["request"], state: state)
    }

    func completion(id: UInt32) throws -> PickupCompletion? {
        try database.read { database in
            try Row.fetchOne(database, sql: "SELECT * FROM pickupCompletions WHERE pickupID = ? AND state != 'completed'", arguments: [id]).map(Self.completion)
        }
    }

    func pendingCompletions() throws -> [PickupCompletion] {
        try database.read { try Row.fetchAll($0, sql: "SELECT * FROM pickupCompletions WHERE state = 'pending' ORDER BY rowid LIMIT 40").map(Self.completion) }
    }

    func setCompletionState(id: UUID, state: PickupCompletion.State) throws {
        try database.write { try $0.execute(sql: "UPDATE pickupCompletions SET state = ? WHERE id = ? AND state != 'completed'", arguments: [state.rawValue, id.uuidString]) }
    }

    func acknowledgeCompletion(_ operation: PickupCompletion, snapshot: PickupSyncSnapshot) throws {
        guard snapshot.isValid, snapshot.pickup.id == operation.pickupID,
              snapshot.requestId.flatMap(UUID.init(uuidString:)) == operation.id else { throw StoreError.invalidRecords }
        try database.write { database in
            guard try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM pickupCompletions WHERE id = ? AND state = 'pending')", arguments: [operation.id.uuidString]) == true else { return }
            try Self.write(snapshot, in: database)
            try database.execute(sql: "UPDATE pickupCompletions SET state = 'completed' WHERE id = ?", arguments: [operation.id.uuidString])
        }
    }

    func discardRejectedCompletion(id: UInt32, snapshot: PickupSyncSnapshot) throws {
        guard snapshot.isValid, snapshot.pickup.id == id else { throw StoreError.invalidRecords }
        try database.write { database in
            guard try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM pickupCompletions WHERE pickupID = ? AND state = 'needsReview')", arguments: [id]) == true else { throw StoreError.pendingOperation }
            try Self.write(snapshot, in: database)
            try database.execute(sql: "DELETE FROM pickupCompletions WHERE pickupID = ? AND state = 'needsReview'", arguments: [id])
        }
    }

    func saveInvoiceContext(_ context: PickupInvoiceContext, pickup: Pickup, receiverID: String?) throws {
        guard context.matches(pickup, receiverID: receiverID) else { throw StoreError.invalidRecords }
        let payload = try JSONEncoder().encode(context)
        try database.write { database in
            try database.execute(sql: "INSERT INTO pickupInvoiceContexts (pickupID, receiverID, payload) VALUES (?, ?, ?) ON CONFLICT(pickupID, receiverID) DO UPDATE SET payload = excluded.payload",
                arguments: [pickup.id, context.receiver?.id ?? "", payload])
        }
    }

    func invoiceContext(pickup: Pickup, receiverID: String?) throws -> PickupInvoiceContext? {
        let choices = PickupInvoicePrefill.receivers(in: pickup)
        let selected = receiverID ?? (choices.count == 1 ? choices.first?.id : nil) ?? ""
        return try database.read { database in
            guard let payload = try Data.fetchOne(database, sql: "SELECT payload FROM pickupInvoiceContexts WHERE pickupID = ? AND receiverID = ? AND EXISTS(SELECT 1 FROM pickupSnapshots WHERE id = ? AND hidden = 0)",
                arguments: [pickup.id, selected, pickup.id]) else { return nil }
            let context = try JSONDecoder().decode(PickupInvoiceContext.self, from: payload)
            return context.matches(pickup, receiverID: receiverID) ? context : nil
        }
    }

}
