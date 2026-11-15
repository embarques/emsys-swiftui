import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Reads a selected file and prepares validated attachment metadata for the draft.
nonisolated enum InvoiceAttachmentFile {
    // These formats start with a fixed signature. GIF and TIFF have two accepted variants.
    private static let signatures: [(bytes: [UInt8], mimeType: String)] = [
        (Array("%PDF-".utf8), "application/pdf"),
        ([0xff, 0xd8, 0xff], "image/jpeg"),
        ([137, 80, 78, 71, 13, 10, 26, 10], "image/png"),
        (Array("GIF87a".utf8), "image/gif"),
        (Array("GIF89a".utf8), "image/gif"),
        ([66, 77], "image/bmp"),
        ([73, 73, 42, 0], "image/tiff"),
        ([77, 77, 0, 42], "image/tiff")
    ]

    /// Lists the formats accepted by the system file picker.
    static var allowedTypes: [UTType] {
        // Some image formats are available through extension lookup on supported systems.
        let extensions = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif"]
        let imageTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        return [.pdf] + imageTypes
    }

    /// Reads a regular file off the main actor and verifies its content before returning.
    static func prepare(url: URL) async throws -> (attachment: InvoiceAttachment, bytes: Data) {
        try await Task.detached(priority: .userInitiated) {
            // Retain access to a file selected from another app for the duration of the read.
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            // Reject non-regular files and sizes already known to exceed the limit.
            let maximumSize = InvoiceAttachment.maximumSize
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw InvoiceAttachment.AttachmentError.invalidFile
            }
            if let fileSize = values.fileSize, fileSize > maximumSize {
                throw InvoiceAttachment.AttachmentError.tooLarge
            }

            // Read at most one byte beyond the limit so a changing file cannot cause an unbounded read.
            let handle = try FileHandle(forReadingFrom: url)
            defer {
                try? handle.close()
            }
            var bytes = Data()
            while bytes.count <= maximumSize {
                let remaining = maximumSize + 1 - bytes.count
                let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
                if chunk.isEmpty {
                    break
                }
                bytes.append(chunk)
            }

            return try prepare(name: url.lastPathComponent, bytes: bytes)
        }.value
    }

    /// Creates attachment metadata from bytes already read into memory.
    static func prepare(name: String, bytes: Data) throws -> (attachment: InvoiceAttachment, bytes: Data) {
        // Apply the same bounds to files of unknown size and directly supplied bytes.
        guard bytes.count <= InvoiceAttachment.maximumSize else {
            throw InvoiceAttachment.AttachmentError.tooLarge
        }

        // Match the API's filename normalization and reject path placeholders.
        let originalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bytes.isEmpty, !originalName.isEmpty, originalName != ".", originalName != "..",
              originalName.unicodeScalars.count <= 200 else {
            throw InvoiceAttachment.AttachmentError.invalidFile
        }

        // Identify the format from the contents and record the digest for future reads.
        let mimeType = try detectType(bytes)
        let digest = Data(SHA256.hash(data: bytes))
        let attachment = InvoiceAttachment(
            id: UUID(),
            name: originalName,
            mimeType: mimeType,
            size: bytes.count,
            digest: digest
        )
        guard attachment.isValid else {
            throw InvoiceAttachment.AttachmentError.invalidFile
        }

        return (attachment, bytes)
    }

    /// Identifies a supported document or image from its header bytes.
    private static func detectType(_ bytes: Data) throws -> String {
        let header = Array(bytes.prefix(512))

        // Match fixed signatures before parsing container-specific headers.
        for signature in signatures {
            if header.starts(with: signature.bytes) {
                return signature.mimeType
            }
        }

        // WebP identifies its format and image chunk within the RIFF header.
        if header.count >= 14 {
            let container = String(bytes: header[0..<4], encoding: .ascii)
            let imageType = String(bytes: header[8..<14], encoding: .ascii)
            if container == "RIFF", imageType == "WEBPVP" {
                return "image/webp"
            }
        }

        // HEIC, HEIF, and AVIF advertise their image type through the file type box.
        if let mimeType = imageFileType(in: header) {
            return mimeType
        }

        throw InvoiceAttachment.AttachmentError.unsupportedType
    }

    /// Reads the brand fields in an ISO base media file type box.
    private static func imageFileType(in header: [UInt8]) -> String? {
        // A file type box needs a size, a type, a major brand, and a minor version.
        let majorBrandOffset = 8
        let minorVersionOffset = 12
        let brandWidth = 4
        let minimumBoxSize = minorVersionOffset + brandWidth
        guard header.count >= minimumBoxSize else {
            return nil
        }
        let boxType = String(bytes: header[brandWidth..<majorBrandOffset], encoding: .ascii)
        guard boxType == "ftyp" else {
            return nil
        }

        // Decode the big-endian box length and stay within the bytes that were read.
        var declaredSize = 0
        for byte in header.prefix(4) {
            declaredSize = (declaredSize << 8) | Int(byte)
        }
        let bytesInBox = min(declaredSize, header.count)
        let lastBrandOffset = bytesInBox - brandWidth
        guard lastBrandOffset >= majorBrandOffset else {
            return nil
        }

        // Read the major and compatible brands, skipping the intervening version field.
        var genericType: String?
        let brandOffsets = stride(from: majorBrandOffset, through: lastBrandOffset, by: brandWidth)
        for offset in brandOffsets {
            if offset == minorVersionOffset {
                continue
            }

            // A specific codec brand takes precedence over a generic HEIF brand.
            let brandBytes = header[offset..<(offset + brandWidth)]
            let brand = String(bytes: brandBytes, encoding: .ascii)
            switch brand {
            case "heic", "heix", "hevc", "hevx":
                return "image/heic"
            case "mif1", "msf1":
                genericType = "image/heif"
            case "avif", "avis":
                return "image/avif"
            default:
                break
            }
        }

        return genericType
    }
}
