import CryptoKit
import Foundation
import UniformTypeIdentifiers

nonisolated struct InvoiceAttachment: Codable, Equatable, Identifiable, Sendable {
    static let maximumSize = 25 * 1024 * 1024
    enum AttachmentError: Error { case invalidFile, unsupportedType, tooLarge }
    let id: UUID
    let name: String
    let mimeType: String
    let size: Int
    let digest: Data

    static var allowedTypes: [UTType] {
        [UTType.pdf] + ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif"]
            .compactMap { UTType(filenameExtension: $0) }
    }

    var isValid: Bool {
        !name.isEmpty && name.count <= 200 && size > 0 && size <= Self.maximumSize && digest.count == 32
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || "/\\\"".unicodeScalars.contains($0) }
            && ["application/pdf", "image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp", "image/tiff", "image/heic", "image/heif", "image/avif"].contains(mimeType)
    }

    static func prepare(url: URL) async throws -> (attachment: InvoiceAttachment, bytes: Data) {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw AttachmentError.invalidFile }
            if let size = values.fileSize, size > maximumSize { throw AttachmentError.tooLarge }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var bytes = Data()
            while bytes.count <= maximumSize {
                let remaining = maximumSize + 1 - bytes.count
                let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
                if chunk.isEmpty { break }
                bytes.append(chunk)
            }
            return try prepare(name: url.lastPathComponent, bytes: bytes)
        }.value
    }

    static func prepare(name: String, bytes: Data) throws -> (attachment: InvoiceAttachment, bytes: Data) {
        guard bytes.count <= maximumSize else { throw AttachmentError.tooLarge }
        guard !bytes.isEmpty else { throw AttachmentError.invalidFile }
        let originalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalName.isEmpty, originalName != ".", originalName != "..", originalName.unicodeScalars.count <= 200 else {
            throw AttachmentError.invalidFile
        }
        let attachment = InvoiceAttachment(id: UUID(), name: originalName, mimeType: try detectType(bytes),
            size: bytes.count, digest: Data(SHA256.hash(data: bytes)))
        guard attachment.isValid else { throw AttachmentError.invalidFile }
        return (attachment, bytes)
    }

    func validates(_ bytes: Data) -> Bool {
        isValid && bytes.count == size && Data(SHA256.hash(data: bytes)) == digest
    }

    var boundary: String { "EMSYS-\(id.uuidString)" }

    func multipart(bytes: Data) throws -> Data {
        guard validates(bytes) else { throw AttachmentError.invalidFile }
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"uploadId\"\r\n\r\n\(id.uuidString)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8)
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func detectType(_ bytes: Data) throws -> String {
        let head = Array(bytes.prefix(512))
        if head.starts(with: Array("%PDF-".utf8)) { return "application/pdf" }
        if head.starts(with: [0xff, 0xd8, 0xff]) { return "image/jpeg" }
        if head.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return "image/png" }
        if head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if head.count >= 14, String(bytes: head[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: head[8..<14], encoding: .ascii) == "WEBPVP" { return "image/webp" }
        if head.starts(with: [66, 77]) { return "image/bmp" }
        if head.starts(with: [73, 73, 42, 0]) || head.starts(with: [77, 77, 0, 42]) { return "image/tiff" }
        if head.count >= 16, String(bytes: head[4..<8], encoding: .ascii) == "ftyp" {
            let declaredSize = head.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            let end = min(declaredSize, head.count)
            var detected: String?
            for offset in stride(from: 8, through: max(8, end - 4), by: 4) where offset != 12 && offset + 4 <= end {
                switch String(bytes: head[offset..<(offset + 4)], encoding: .ascii) {
                case "heic", "heix", "hevc", "hevx": return "image/heic"
                case "mif1", "msf1": detected = "image/heif"
                case "avif", "avis": return "image/avif"
                default: break
                }
            }
            if let detected { return detected }
        }
        throw AttachmentError.unsupportedType
    }
}

nonisolated struct PendingInvoiceAttachment: Identifiable, Sendable {
    enum State: String, Sendable { case waiting, awaitingContainer, pending, needsReview, authorizationRequired, serverUnavailable, completed }
    let attachment: InvoiceAttachment
    let invoiceID: String?
    let state: State
    var id: UUID { attachment.id }
}

nonisolated struct InvoiceDocumentReceipt: Decodable, Sendable {
    let id: String
    let invoiceId: String
    let originalName: String
    let mimeType: String
    let size: Int
}
