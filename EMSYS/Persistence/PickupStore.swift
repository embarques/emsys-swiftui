import CryptoKit
import Foundation
import GRDB

/// Read-only server snapshots partitioned by API, tenant and authenticated user.
actor PickupStore {
    enum StoreError: Error { case invalidScope, invalidRecords }
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
        try migrator.migrate(database)
    }

    func save(_ pickups: [Pickup]) throws {
        guard pickups.allSatisfy({ $0.id > 0 }), Set(pickups.map(\.id)).count == pickups.count else {
            throw StoreError.invalidRecords
        }
        let encoded = try pickups.map { ($0.id, try JSONEncoder().encode($0)) }
        try database.write { database in
            for (id, payload) in encoded {
                try database.execute(sql: "INSERT OR REPLACE INTO pickupSnapshots (id, payload, synchronizedAt) VALUES (?, ?, ?)",
                    arguments: [id, payload, Date.now.timeIntervalSince1970])
            }
        }
    }

    func pickups(matching query: PickupListQuery) throws -> [Pickup] {
        try database.read { database in
            try Data.fetchAll(database, sql: "SELECT payload FROM pickupSnapshots ORDER BY id DESC")
                .map { try JSONDecoder().decode(Pickup.self, from: $0) }
                .filter { query.matches($0) }
                .sorted { left, right in
                    if left.date != right.date { return (left.date ?? "") > (right.date ?? "") }
                    return left.id > right.id
                }
        }
    }

    func pickup(id: UInt32) throws -> Pickup? {
        try database.read { database in
            try Data.fetchOne(database, sql: "SELECT payload FROM pickupSnapshots WHERE id = ?", arguments: [id])
                .map { try JSONDecoder().decode(Pickup.self, from: $0) }
        }
    }

    func remove(id: UInt32) throws {
        try database.write { database in
            try database.execute(sql: "DELETE FROM pickupSnapshots WHERE id = ?", arguments: [id])
        }
    }

    func removeAll() throws {
        try database.write { database in
            try database.execute(sql: "DELETE FROM pickupSnapshots")
        }
    }
}
