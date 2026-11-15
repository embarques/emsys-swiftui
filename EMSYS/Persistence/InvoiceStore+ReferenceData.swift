import CryptoKit
import Foundation
import GRDB

/// Invoice reference data and search caches.
extension InvoiceStore {
    /// Replaces the offline list of validated payment bank accounts.
    func saveInvoiceBankAccounts(_ accounts: [InvoiceBankAccount]) throws {
        guard accounts.count <= 1000, accounts.allSatisfy(\.isValid),
              Set(accounts.map(\.id)).count == accounts.count else {
                  throw StoreError.invalidPageContents
              }
        let encoded = try accounts.map { ($0.id, try JSONEncoder().encode($0)) }
        try writeInvoiceDatabase {
            try $0.execute(sql: "DELETE FROM invoiceBankAccounts")
            for (id, payload) in encoded {
                try $0.execute(sql: "INSERT INTO invoiceBankAccounts (id, payload) VALUES (?, ?)", arguments: [id, payload])
            }
        }
    }

    /// Reads the payment accounts available to the offline editor.
    func invoiceBankAccounts() throws -> [InvoiceBankAccount] {
        try readInvoiceDatabase {
            let payloads = try Data.fetchAll($0, sql: "SELECT payload FROM invoiceBankAccounts ORDER BY id LIMIT 1001")
            guard payloads.count <= 1000 else {
                throw StoreError.invalidPageContents
            }
            let accounts = try payloads.map { try JSONDecoder().decode(InvoiceBankAccount.self, from: $0) }
            guard accounts.allSatisfy(\.isValid) else {
                throw StoreError.invalidPageContents
            }
            return accounts
        }
    }

    /// Stores the customer fields required to encode an invoice party.
    func saveCustomerWriteSnapshot(_ snapshot: InvoiceCustomerWriteSnapshot) throws {
        guard snapshot.isValid else {
            throw StoreError.invalidDraft
        }
        let payload = try JSONEncoder().encode(snapshot)
        guard payload.count <= 512 * 1024 else {
            throw StoreError.invalidDraft
        }
        try writeInvoiceDatabase {
            try $0.execute(sql: "INSERT OR REPLACE INTO invoiceCustomerWriteSnapshots (id, payload) VALUES (?, ?)",
                           arguments: [snapshot.id, payload])
        }
    }

    /// Loads cached write details for the selected customer.
    func customerWriteSnapshot(id: String) throws -> InvoiceCustomerWriteSnapshot? {
        try readInvoiceDatabase {
            guard let payload = try Data.fetchOne($0, sql: "SELECT payload FROM invoiceCustomerWriteSnapshots WHERE id = ?", arguments: [id]) else {
                return nil
            }
            guard payload.count <= 512 * 1024 else {
                throw StoreError.invalidDraft
            }
            let snapshot = try JSONDecoder().decode(InvoiceCustomerWriteSnapshot.self, from: payload)
            guard snapshot.id == id, snapshot.isValid else {
                throw StoreError.invalidDraft
            }
            return snapshot
        }
    }

    /// Stores customers so party searches can still work offline.
    func saveCustomers(_ customers: [InvoiceCustomer]) throws {
        guard customers.count <= 40, customers.allSatisfy(\.isValid),
              Set(customers.map(\.id)).count == customers.count else {
                  throw StoreError.invalidPageContents
              }
        let encoded = try customers.map { ($0, try JSONEncoder().encode($0)) }
        try writeInvoiceDatabase { database in
            for (customer, payload) in encoded {
                try database.execute(sql: """
                    INSERT OR REPLACE INTO invoiceCustomers (id, role, searchText, payload, savedAt)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [customer.id, customer.customerType, customer.searchText, payload, Date.now.timeIntervalSince1970])
            }
        }
    }

    /// Replaces the policy list available for offline invoice review.
    func savePolicies(_ policies: [InvoicePolicy]) throws {
        guard InvoicePolicy.validate(policies) else {
            throw StoreError.invalidPageContents
        }
        let payload = try JSONEncoder().encode(policies)
        guard payload.count <= 2 * 1024 * 1024 else {
            throw StoreError.invalidPageContents
        }
        try writeInvoiceDatabase { database in
            try database.execute(sql: "INSERT OR REPLACE INTO invoicePolicies (id, payload) VALUES (1, ?)", arguments: [payload])
        }
    }

    /// Returns the last saved policy list, if one has been downloaded.
    func policies() throws -> [InvoicePolicy]? {
        try readInvoiceDatabase { database in
            guard let payload = try Data.fetchOne(database, sql: "SELECT payload FROM invoicePolicies WHERE id = 1") else {
                return nil
            }
            return try JSONDecoder().decode([InvoicePolicy].self, from: payload)
        }
    }

    /// Caches containers returned by the invoice assignment endpoint.
    func saveContainers(_ containers: [InvoiceContainer]) throws {
        guard containers.count <= 40, containers.allSatisfy(\.isValid),
              Set(containers.map(\.id)).count == containers.count else {
                  throw StoreError.invalidPageContents
              }
        let encoded = try containers.map { ($0, try JSONEncoder().encode($0)) }
        try writeInvoiceDatabase { database in
            for (container, payload) in encoded {
                try database.execute(sql: "INSERT OR REPLACE INTO invoiceContainers (id, searchText, payload) VALUES (?, ?, ?)",
                    arguments: [container.id, container.searchText, payload])
            }
        }
    }

    /// Searches saved container suggestions without contacting the server.
    func containers(matching query: String) throws -> [InvoiceContainer] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_DO"))
        return try readInvoiceDatabase { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT payload FROM invoiceContainers WHERE instr(searchText, ?) > 0 ORDER BY id DESC LIMIT 40
                """, arguments: [term])
            return try rows.map { try JSONDecoder().decode(InvoiceContainer.self, from: $0["payload"] as Data) }
        }
    }

    /// Searches cached customers in the requested invoice party role.
    func customers(matching query: String, role: InvoiceCustomer.Role) throws -> [InvoiceCustomer] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_DO"))
        return try readInvoiceDatabase { database in
            // instr treats %, _ and quotes as literal search text.
            let rows = try Row.fetchAll(database, sql: """
                SELECT payload FROM invoiceCustomers WHERE role = ? AND instr(searchText, ?) > 0
                ORDER BY savedAt DESC, id LIMIT 40
                """, arguments: [role.rawValue, term])
            return try rows.map { try JSONDecoder().decode(InvoiceCustomer.self, from: $0["payload"] as Data) }
        }
    }

    /// Stores the route choices available to invoice pickup assignment.
    func savePickupRoutes(_ routes: [InvoicePickupRoute]) throws {
        guard routes.allSatisfy({ $0.isValid && $0.isPickup }) else {
            throw StoreError.invalidPageContents
        }
        try saveAssignmentCatalog(routes, kind: "routes")
    }

    /// Loads the last downloaded route choices.
    func pickupRoutes() throws -> [InvoicePickupRoute]? {
        try assignmentCatalog(kind: "routes", as: InvoicePickupRoute.self)
    }

    /// Stores employees eligible for invoice pickup assignment.
    func savePickupEmployees(_ employees: [InvoicePickupEmployee]) throws {
        guard employees.allSatisfy({ $0.isValid && $0.isEligible }) else {
            throw StoreError.invalidPageContents
        }
        try saveAssignmentCatalog(employees, kind: "employees")
    }

    /// Loads the saved employee catalog.
    func pickupEmployees() throws -> [InvoicePickupEmployee]? {
        try assignmentCatalog(kind: "employees", as: InvoicePickupEmployee.self)
    }

    /// Persists branches used for pickup and payment location selection.
    func savePickupBranches(_ branches: [InvoicePickupBranch]) throws {
        guard branches.allSatisfy({ $0.id > 0 }) else {
            throw StoreError.invalidPageContents
        }
        try saveAssignmentCatalog(branches, kind: "branches")
    }

    /// Returns the cached branches, if that list has been downloaded.
    func pickupBranches() throws -> [InvoicePickupBranch]? {
        try assignmentCatalog(kind: "branches", as: InvoicePickupBranch.self)
    }

    /// Caches the selected branch and day's payment review.
    func savePaymentReview(_ review: InvoicePaymentReview) throws {
        guard review.isValid else {
            throw StoreError.invalidPageContents
        }
        let payload = try JSONEncoder().encode(review)
        guard payload.count <= 256 * 1024 else {
            throw StoreError.invalidPageContents
        }
        try writeInvoiceDatabase { database in
            try database.execute(sql: """
                INSERT OR REPLACE INTO invoicePaymentReviews (branchID, businessDate, payload) VALUES (?, ?, ?)
                """, arguments: [review.branchID, review.day.apiValue, payload])
        }
    }

    /// Reads the saved review for the requested branch and business day.
    func paymentReview(branchID: UInt16, day: InvoiceDate) throws -> InvoicePaymentReview? {
        guard branchID > 0, day.pickerDate != nil else {
            throw StoreError.invalidPageContents
        }
        return try readInvoiceDatabase { database in
            guard let payload = try Data.fetchOne(database, sql: "SELECT payload FROM invoicePaymentReviews WHERE branchID = ? AND businessDate = ?",
                arguments: [branchID, day.apiValue]) else {
                    return nil
                }
            let review = try JSONDecoder().decode(InvoicePaymentReview.self, from: payload)
            guard review.isValid, review.branchID == branchID, review.day == day else {
                throw StoreError.invalidPageContents
            }
            return review
        }
    }

    /// Writes a validated reference catalog under its lookup kind.
    private func saveAssignmentCatalog<Item: Encodable & Identifiable>(_ items: [Item], kind: String) throws {
        guard items.count <= 1_000, Set(items.map(\.id)).count == items.count else {
            throw StoreError.invalidPageContents
        }
        let payload = try JSONEncoder().encode(items)
        guard payload.count <= 2 * 1024 * 1024 else {
            throw StoreError.invalidPageContents
        }
        try writeInvoiceDatabase { database in
            try database.execute(sql: "INSERT OR REPLACE INTO invoiceAssignmentCatalogs (kind, payload) VALUES (?, ?)", arguments: [kind, payload])
        }
    }

    /// Decodes the requested assignment catalog and checks its identity bounds.
    private func assignmentCatalog<Item: Decodable & Identifiable>(kind: String, as type: Item.Type) throws -> [Item]? {
        try readInvoiceDatabase { database in
            guard let payload = try Data.fetchOne(database, sql: "SELECT payload FROM invoiceAssignmentCatalogs WHERE kind = ?", arguments: [kind]) else {
                return nil
            }
            let items = try JSONDecoder().decode([Item].self, from: payload)
            guard items.count <= 1_000, Set(items.map(\.id)).count == items.count else {
                throw StoreError.invalidPageContents
            }
            return items
        }
    }

    /// Persists the complete validated item catalog for offline use.
    func saveItemCatalog(_ items: [InvoiceCatalogItem]) throws {
        guard items.count <= 1_000, items.allSatisfy(\.isValid), Set(items.map(\.id)).count == items.count else {
            throw StoreError.invalidPageContents
        }
        let payload = try JSONEncoder().encode(items)
        guard payload.count <= 2 * 1024 * 1024 else {
            throw StoreError.invalidPageContents
        }
        try writeInvoiceDatabase { database in
            try database.execute(sql: "INSERT OR REPLACE INTO invoiceItemCatalog (id, payload) VALUES (1, ?)", arguments: [payload])
        }
    }

    /// Reads the available item templates in their cached order.
    func itemCatalog() throws -> [InvoiceCatalogItem] {
        try readInvoiceDatabase { database in
            guard let payload = try Data.fetchOne(database, sql: "SELECT payload FROM invoiceItemCatalog WHERE id = 1") else {
                return []
            }
            return try JSONDecoder().decode([InvoiceCatalogItem].self, from: payload)
        }
    }
}
