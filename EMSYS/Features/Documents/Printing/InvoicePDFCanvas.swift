import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A small vector canvas using the API's standard PDF fonts, millimetres and
/// cell baseline. No HTML, web view, remote PDF or printer-dependent layout.
nonisolated struct InvoicePDFCanvas {
    static let scale = 72.0 / 25.4
    enum ImageName: String, CaseIterable { case logo = "Logo", senderSignature = "SenderSignature" }
    private struct ImageAsset {
        let object: String
        let width: Int
        let height: Int
    }
    private var images: [ImageName: ImageAsset] = [:]
    var pages: [String] = []

    /// Prepares a PDF-compatible raster for the company logo or sender signature.
    mutating func addImage(_ bytes: Data, named name: ImageName = .logo) throws {
        // Bound encoded data and raster dimensions before allocating the bitmap.
        guard bytes.count <= 2 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw InvoicePDFRenderer.RenderError.missingAssets
        }
        // Flatten transparent pixels onto a white page before encoding JPEG.
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        let encoded = NSMutableData()
        guard let raster = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw InvoicePDFRenderer.RenderError.missingAssets
        }
        let flattened = name == .senderSignature ? croppedSignature(raster, in: context) : raster
        CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw InvoicePDFRenderer.RenderError.missingAssets
        }
        let hex = (encoded as Data).map { String(format: "%02X", $0) }.joined() + ">"
        let object = "<< /Type /XObject /Subtype /Image /Width \(flattened.width) /Height \(flattened.height) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter [/ASCIIHexDecode /DCTDecode] /Length \(hex.utf8.count) >>\nstream\n\(hex)\nendstream"
        images[name] = ImageAsset(object: object, width: flattened.width, height: flattened.height)
    }

    /// Trims blank margins from a signature while retaining a small border.
    private func croppedSignature(_ image: CGImage, in context: CGContext) -> CGImage {
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return image
        }
        var left = image.width
        var right = -1
        var top = image.height
        var bottom = -1
        // Locate the ink in the same four-byte pixels used to create the bitmap.
        for y in 0..<image.height {
            let rowStart = bytes + y * context.bytesPerRow
            for x in 0..<image.width {
                let pixel = rowStart + x * 4
                if pixel[0] < 250 || pixel[1] < 250 || pixel[2] < 250 {
                    left = min(left, x)
                    right = max(right, x)
                    top = min(top, y)
                    bottom = max(bottom, y)
                }
            }
        }
        // An empty scan has no crop rectangle.
        guard right >= left else {
            return image
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let ink = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        return image.cropping(to: ink.insetBy(dx: -2, dy: -2).intersection(bounds)) ?? image
    }

    /// Places a prepared raster inside the requested invoice rectangle.
    mutating func image(x: Double, y: Double, width: Double, height: Double,
                        named name: ImageName = .logo, preserveAspectRatio: Bool = false, alignBottom: Bool = false) {
        guard let asset = images[name] else {
            return
        }
        var drawingX = x
        var drawingY = y
        var drawingWidth = width
        var drawingHeight = height

        // Fit within the requested rectangle and preserve bottom alignment for signatures.
        if preserveAspectRatio {
            let scale = min(width / Double(asset.width), height / Double(asset.height))
            let fittedWidth = Double(asset.width) * scale
            let fittedHeight = Double(asset.height) * scale
            drawingX += (width - fittedWidth) / 2
            let remainingHeight = height - fittedHeight
            drawingY += alignBottom ? remainingHeight : remainingHeight / 2
            drawingWidth = fittedWidth
            drawingHeight = fittedHeight
        }

        // PDF coordinates start at the bottom-left, unlike the invoice layout.
        let pdfX = number(drawingX * Self.scale)
        let pdfY = number((279.4 - drawingY - drawingHeight) * Self.scale)
        let pdfWidth = number(drawingWidth * Self.scale)
        let pdfHeight = number(drawingHeight * Self.scale)
        content += "q \(pdfWidth) 0 0 \(pdfHeight) \(pdfX) \(pdfY) cm /\(name.rawValue) Do Q\n"
    }
    var content = "0 G 0 g 0.57 w\n"

    /// Encodes text using the character set of the standard PDF fonts.
    static func bytes(_ text: String) -> [UInt8] {
        Array(text.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data())
    }

    /// Measures encoded text using the selected font metrics.
    static func width(_ text: String, font: InvoicePDFFont, size: Double) -> Double {
        Double(bytes(text).reduce(0) { $0 + font.widths[Int($1)] }) * size / 1000 / scale
    }

    /// Wraps text to the same cell width and margins as the print layout.
    static func lines(_ text: String, width: Double, font: InvoicePDFFont, size: Double) -> [String] {
        var bytes = bytes(text.replacingOccurrences(of: "\r", with: ""))
        // The print layout ignores trailing newlines.
        while bytes.last == 10 {
            bytes.removeLast()
        }
        let maximum = Int(ceil((width - 2) * 1000 / (size / scale)))
        var result: [String] = []
        var separator: Int?
        var index = 0
        var start = 0
        var length = 0

        // Track the most recent separator so a whole word can move to the next line.
        while index < bytes.count {
            let byte = bytes[index]
            length += font.widths[Int(byte)]
            if byte == 32 || byte == 9 || byte == 10 {
                separator = index
            }
            if byte == 10 || length > maximum {
                let end: Int
                if let separator {
                    end = separator
                    index = separator + 1
                } else {
                    // Ensure a single oversized character still advances the scan.
                    if index == start {
                        index += 1
                    }
                    end = index
                }
                result.append(String(data: Data(bytes[start..<end]), encoding: .windowsCP1252) ?? "")
                separator = nil
                start = index
                length = 0
            } else {
                index += 1
            }
        }
        if index != start {
            result.append(String(data: Data(bytes[start..<index]), encoding: .windowsCP1252) ?? "")
        }
        return result
    }

    /// Draws a text cell with the requested horizontal alignment.
    mutating func cell(_ text: String, x: Double, y: Double, width: Double, height: Double,
                       font: InvoicePDFFont = .regular, size: Double = 10, align: String = "L") {
        let measured = Self.width(text, font: font, size: size)
        let offset: Double
        switch align {
        case "C":
            offset = (width - measured) / 2
        case "R":
            offset = width - 1 - measured
        default:
            offset = 1
        }
        let baseline = 279.4 - y - height / 2 - 0.3 * size / Self.scale
        // Hex strings prevent PDF syntax injection and retain WinAnsi accents.
        let encoded = Self.bytes(text).map { String(format: "%02X", $0) }.joined()
        content += "BT /F\(font.rawValue + 1) \(number(size)) Tf \(number((x + offset) * Self.scale)) \(number(baseline * Self.scale)) Td <\(encoded)> Tj ET\n"
    }

    /// Draws a straight stroke in invoice coordinates.
    mutating func line(_ x: Double, _ y: Double, _ endX: Double, _ endY: Double) {
        content += "\(number(x * Self.scale)) \(number((279.4 - y) * Self.scale)) m \(number(endX * Self.scale)) \(number((279.4 - endY) * Self.scale)) l S\n"
    }

    /// Draws a shaded cell in invoice coordinates.
    mutating func rectangle(x: Double, y: Double, width: Double, height: Double) {
        content += "q 0.941 g \(number(x * Self.scale)) \(number((279.4 - y) * Self.scale)) \(number(width * Self.scale)) \(number(-height * Self.scale)) re B Q\n"
    }

    /// Saves the current drawing commands and starts a blank page.
    mutating func finishPage() {
        // Restore the default stroke and fill for the next page.
        pages.append(content)
        content = "0 G 0 g 0.57 w\n"
    }

    /// Serializes the page tree, resources, and cross-reference table.
    func pdf() -> Data {
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", ""]
        for font in InvoicePDFFont.allCases {
            objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /\(font.name) /Encoding /WinAnsiEncoding >>")
        }
        var imageReferences: [String] = []
        for name in ImageName.allCases {
            guard let asset = images[name] else {
                continue
            }
            let imageID = objects.count + 1
            objects.append(asset.object)
            imageReferences.append("/\(name.rawValue) \(imageID) 0 R")
        }
        let imageResource = imageReferences.isEmpty ? "" : "/XObject << \(imageReferences.joined(separator: " ")) >>"
        var references: [String] = []
        let resources = InvoicePDFFont.allCases.map { "/F\($0.rawValue + 1) \($0.rawValue + 3) 0 R" }.joined(separator: " ")
        for page in pages {
            let pageID = objects.count + 1
            references.append("\(pageID) 0 R")
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << \(resources) >> \(imageResource) >> /Contents \(pageID + 1) 0 R >>")
            objects.append("<< /Length \(page.utf8.count) >>\nstream\n\(page)endstream")
        }
        objects[1] = "<< /Type /Pages /Count \(pages.count) /Kids [\(references.joined(separator: " "))] >>"
        var output = Data("%PDF-1.4\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(output.count)
            output.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = output.count
        output.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        // PDF readers use the byte offsets to locate the objects.
        for offset in offsets.dropFirst() {
            let entry = String(format: "%010d 00000 n \n", offset)
            output.append(Data(entry.utf8))
        }
        output.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return output
    }

    /// Formats coordinates with the decimal syntax required by PDF.
    private func number(_ value: Double) -> String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) }
}
