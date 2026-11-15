import CryptoKit
import Foundation
import GRDB

/// Saved reports and offline printing settings.
extension InvoiceStore {
    /// Caches company details needed to render an invoice offline.
    func savePrintCompany(_ company: InvoicePrintCompany) throws {
        guard !company.name.isEmpty else {
            throw StoreError.invalidScope
        }
        let payload = try JSONEncoder().encode(company)
        try writeInvoiceDatabase { database in
            try database.execute(sql: "INSERT OR REPLACE INTO invoicePrintCompany (id, payload) VALUES (1, ?)", arguments: [payload])
        }
    }

    /// Loads the company details saved for local printing.
    func printCompany() throws -> InvoicePrintCompany? {
        try readInvoiceDatabase { database in
            guard let payload = try Data.fetchOne(database, sql: "SELECT payload FROM invoicePrintCompany WHERE id = 1") else {
                return nil
            }
            return try JSONDecoder().decode(InvoicePrintCompany.self, from: payload)
        }
    }

    /// Persists a generated or downloaded PDF under its invoice identity.
    func saveDocument(_ document: InvoiceDocument) throws {
        guard Self.isObjectID(document.selection.invoiceID),
              !document.reportID.isEmpty, document.reportID.utf8.count <= 200 else {
            throw DocumentError.invalidSelection
        }
        try InvoiceDocument.validate(document.pdf)
        let selection = try JSONEncoder().encode(document.selection)
        try writeInvoiceDatabase { database in
            try database.execute(sql: """
                INSERT INTO invoiceDocuments (id, invoiceID, reportID, selection, savedAt, pdf)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [document.id.uuidString, document.selection.invoiceID,
                    document.reportID, selection, document.savedAt.timeIntervalSince1970, document.pdf])
        }
    }

    /// Returns the most recently cached document for an invoice.
    func latestDocument(invoiceID: String) throws -> InvoiceDocument? {
        guard Self.isObjectID(invoiceID) else {
            throw StoreError.invalidInvoiceID
        }
        return try readInvoiceDatabase { database in
            guard let row = try Row.fetchOne(database, sql: """
                SELECT id, reportID, selection, savedAt, pdf FROM invoiceDocuments
                WHERE invoiceID = ? ORDER BY savedAt DESC, id DESC LIMIT 1
                """, arguments: [invoiceID]) else {
                    return nil
                }
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
}
