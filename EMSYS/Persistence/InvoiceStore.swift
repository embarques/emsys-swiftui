import CryptoKit
import Foundation
import GRDB

/// One durable database per authenticated user and tenant. No unscoped database
/// handle is exposed to screens, and all disk/database work runs off MainActor.
actor InvoiceStore {
    enum StoreError: Error {
        case invalidScope
        case invalidInvoiceID
        case invoicePoolEmpty
        case invoiceReservationChanged
        case invoiceNumberPreviewChanged
        case invalidCreationReceipt
        case invalidPage
        case invalidPageContents
        case missingEditSnapshot
        case editAlreadyPending
        case invalidEditState
        case editSnapshotChanged
        case invalidDraft
        case draftChanged
    }

    private let database: DatabaseQueue

    /// Opens the existing user and tenant partition off the main actor.
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

    /// Opens the invoice database scoped to one user, tenant, and API environment.
    private init(directory: URL, userID: String, companyID: String, apiEnvironment: String) throws {
        // Reject invalid scope keys before deriving the local database partition.
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
        // Protect offline invoices and keep the tenant cache out of device backups.
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

        // Open the existing file and apply only migrations that have not run yet.
        var configuration = Configuration()
        configuration.label = "EMSYS.InvoiceStore"
        configuration.foreignKeysEnabled = true
        database = try DatabaseQueue(path: folder.appending(path: "invoices.sqlite").path, configuration: configuration)
        try InvoiceDatabaseMigrations.migrate(database, environment: environment)
        // Confirm the persisted scope before returning a writable store.
        let savedEnvironment = try database.read { database in
            try String.fetchOne(database, sql: "SELECT apiEnvironment FROM invoiceCacheMetadata WHERE id = 1")
        }
        guard savedEnvironment == environment else {
            throw StoreError.invalidScope
        }
    }

    /// Runs a read against this store's tenant-scoped database.
    func readInvoiceDatabase<Value>(_ read: (Database) throws -> Value) throws -> Value {
        try database.read(read)
    }

    /// Runs a write in a single transaction against this store's tenant-scoped database.
    func writeInvoiceDatabase<Value>(_ write: (Database) throws -> Value) throws -> Value {
        try database.write(write)
    }
}
