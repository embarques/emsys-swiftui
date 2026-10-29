import Foundation
import PDFKit

nonisolated struct InvoiceDocument: Identifiable, Sendable {
    let id: UUID
    let reportID: String
    let selection: InvoiceSignatureSelection
    let savedAt: Date
    let pdf: Data

    static let maximumBytes = 20 * 1024 * 1024

    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumBytes,
              data.starts(with: Data("%PDF-".utf8)),
              let document = PDFDocument(data: data), !document.isLocked,
              (1...1000).contains(document.pageCount) else {
            throw DocumentError.invalidPDF
        }
    }
}

nonisolated enum DocumentError: Error {
    case invalidURL
    case invalidResponse
    case tooLarge
    case invalidPDF
    case invalidSelection
}
