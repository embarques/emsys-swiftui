import GRDB

/// Registers the invoice database schema in the order shipped to existing installations.
nonisolated enum InvoiceDatabaseMigrations {
    /// Applies pending migrations for this tenant and API environment.
    static func migrate(_ database: DatabaseQueue, environment: String) throws {
        var migrator = DatabaseMigrator()
        // Create the primary invoice cache and its number lookup.
        migrator.registerMigration("createInvoiceSnapshots") { database in
            try database.create(table: "invoiceSnapshots") { table in
                table.column("id", .text).primaryKey()
                table.column("number", .text)
                table.column("payload", .blob).notNull()
                table.column("synchronizedAt", .double).notNull()
            }
            try database.create(index: "invoiceSnapshotsByNumber", on: "invoiceSnapshots", columns: ["number", "id"])
        }
        // Track which invoices belong to each previously downloaded page.
        migrator.registerMigration("createInvoicePages") { database in
            try database.create(table: "invoicePages") { table in
                table.column("page", .integer).primaryKey()
                table.column("invoiceIDs", .blob).notNull()
            }
        }
        // Keep full invoice detail separate from lighter list data.
        migrator.registerMigration("preserveInvoiceDetailSnapshots") { database in
            try database.alter(table: "invoiceSnapshots") { table in
                table.add(column: "detailPayload", .blob)
            }
            // Existing rows may contain the only downloaded detail copy. Keep
            // them intact until a fresh detail response replaces that snapshot.
            try database.execute(sql: "UPDATE invoiceSnapshots SET detailPayload = payload")
        }
        // Store local copies of generated and downloaded documents.
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
        // Track edit snapshots, pending writes, and the local cache revision.
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
        // Prevent multiple concurrent edits for the same invoice.
        migrator.registerMigration("indexActiveInvoiceEdits") { database in
            try database.execute(sql: """
                CREATE INDEX activeEditsByCreation ON invoiceEdits(createdAt, id)
                WHERE state NOT IN ('completed', 'discarded', 'superseded')
                """)
        }
        // Use the same case-insensitive number ordering for invoice lookup and indexing.
        migrator.registerMigration("indexInvoiceNumbersCaseInsensitive") { database in
            // Match the list ordering so SQLite can page without sorting the
            // entire local cache every time another page is requested.
            try database.execute(sql: """
                CREATE INDEX invoiceSnapshotsByNumberCaseInsensitive
                ON invoiceSnapshots(number COLLATE NOCASE DESC, id DESC)
                """)
            try database.execute(sql: "DROP INDEX invoiceSnapshotsByNumber")
        }
        // Persist draft content with a revision for optimistic editing.
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
        // Keep company settings for offline printing.
        migrator.registerMigration("cacheInvoicePrintCompany") { database in
            try database.create(table: "invoicePrintCompany") { table in
                table.column("id", .integer).primaryKey()
                table.column("payload", .blob).notNull()
            }
        }
        // Index saved customers by their role in the invoice.
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
        // Keep the last downloaded invoice policies for offline review.
        migrator.registerMigration("cacheInvoicePolicies") { database in
            try database.create(table: "invoicePolicies") { table in
                table.column("id", .integer).primaryKey()
                table.column("payload", .blob).notNull()
            }
        }
        // Persist the container lookup used by the invoice form.
        migrator.registerMigration("cacheInvoiceContainers") { database in
            try database.create(table: "invoiceContainers") { table in
                table.column("id", .integer).primaryKey()
                table.column("searchText", .text).notNull()
                table.column("payload", .blob).notNull()
            }
        }
        // Cache branch, employee, and route reference data.
        migrator.registerMigration("cacheInvoiceAssignments") { database in
            try database.create(table: "invoiceAssignmentCatalogs") { table in
                table.column("kind", .text).primaryKey()
                table.column("payload", .blob).notNull()
            }
        }
        // Cache item templates for offline invoice entry.
        migrator.registerMigration("cacheInvoiceItemCatalog") { database in
            try database.create(table: "invoiceItemCatalog") { table in
                table.column("id", .integer).primaryKey()
                table.column("payload", .blob).notNull()
            }
        }
        // Keep payment review results scoped to branch and business day.
        migrator.registerMigration("cacheInvoicePaymentReviews") { database in
            try database.create(table: "invoicePaymentReviews") { table in
                table.column("branchID", .integer).notNull()
                table.column("businessDate", .text).notNull()
                table.column("payload", .blob).notNull()
                table.primaryKey(["branchID", "businessDate"])
            }
        }
        // Persist customer write details separately from search data.
        migrator.registerMigration("cacheInvoiceCustomerWriteSnapshots") { database in
            try database.create(table: "invoiceCustomerWriteSnapshots") { table in
                table.column("id", .text).primaryKey()
                table.column("payload", .blob).notNull()
            }
        }
        // Keep the last validated chart-account choices for payment entry.
        migrator.registerMigration("cacheInvoiceBankAccounts") { database in
            try database.create(table: "invoiceBankAccounts") { table in
                table.column("id", .integer).primaryKey()
                table.column("payload", .blob).notNull()
            }
        }
        // Persist frozen invoice creation requests and their confirmation state.
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
        // Store attachment metadata and original bytes with their draft.
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
        // Flag records created under assigned-pickup permissions.
        migrator.registerMigration("scopeAssignedInvoiceDrafts") { database in
            try database.alter(table: "invoiceDrafts") { $0.add(column: "assignedOnly", .boolean).notNull().defaults(to: false) }
            try database.alter(table: "invoiceCreations") { $0.add(column: "assignedOnly", .boolean).notNull().defaults(to: false) }
            try database.create(index: "assignedInvoiceDrafts", on: "invoiceDrafts", columns: ["assignedOnly", "savedAt", "id"])
            try database.create(index: "assignedInvoiceCreations", on: "invoiceCreations", columns: ["assignedOnly", "state", "createdAt"])
        }
        // Persist reservations, pool metadata, and outstanding pool actions.
        migrator.registerMigration("reserveOfflineInvoiceNumbers") { database in
            try database.execute(sql: """
                CREATE TABLE invoicePoolMetadata (id INTEGER PRIMARY KEY CHECK(id = 1), deviceID TEXT NOT NULL, lowThreshold INTEGER NOT NULL DEFAULT 10, revision INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE invoiceReservations (id TEXT PRIMARY KEY, token TEXT NOT NULL, state TEXT NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX invoiceReservations_state ON invoiceReservations(state, id);
                CREATE TABLE invoiceReservationRetiredTokens (id TEXT NOT NULL, token TEXT NOT NULL, PRIMARY KEY(id, token));
                CREATE TABLE invoicePoolActions (id TEXT PRIMARY KEY, payload BLOB NOT NULL, createdAt DOUBLE NOT NULL);
                """)
        }
        // Preserve the last server failure for recovery and review.
        migrator.registerMigration("addInvoiceCreationFailure") { database in
            try database.alter(table: "invoiceCreations") { $0.add(column: "failure", .blob) }
        }
        try migrator.migrate(database)
    }
}
