import Foundation
import ImageIO

/// Uses the same field names and base64 representation in SQLite and the API.
nonisolated struct InvoiceSenderSignature: Codable, Equatable, Sendable {
    let signerName: String
    let data: String
    let contentType: String

    var pngData: Data? {
        guard contentType == "image/png",
              data.utf8.count <= 2_796_204, let bytes = Data(base64Encoded: data), bytes.count <= 2 * 1024 * 1024,
              bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 4_194_304 else { return nil }
        return bytes
    }

    var isValid: Bool {
        !signerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pngData != nil
    }
}
