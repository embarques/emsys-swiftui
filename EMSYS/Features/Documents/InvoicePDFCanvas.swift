import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A small vector canvas using the API's standard PDF fonts, millimetres and
/// cell baseline. No HTML, web view, remote PDF or printer-dependent layout.
nonisolated struct InvoicePDFCanvas {
    static let scale = 72.0 / 25.4
    enum ImageName: String, CaseIterable { case logo = "Logo", senderSignature = "SenderSignature" }
    private struct ImageAsset { let object: String; let width: Int; let height: Int }
    private var images: [ImageName: ImageAsset] = [:]
    var pages: [String] = []

    mutating func addImage(_ bytes: Data, named name: ImageName = .logo) throws {
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
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let encoded = NSMutableData()
        guard let flattened = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw InvoicePDFRenderer.RenderError.missingAssets
        }
        CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw InvoicePDFRenderer.RenderError.missingAssets }
        let hex = (encoded as Data).map { String(format: "%02X", $0) }.joined() + ">"
        let object = "<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter [/ASCIIHexDecode /DCTDecode] /Length \(hex.utf8.count) >>\nstream\n\(hex)\nendstream"
        images[name] = ImageAsset(object: object, width: width, height: height)
    }

    mutating func image(x: Double, y: Double, width: Double, height: Double,
                        named name: ImageName = .logo, preserveAspectRatio: Bool = false) {
        guard let asset = images[name] else { return }
        var x = x; var y = y; var width = width; var height = height
        if preserveAspectRatio {
            let scale = min(width / Double(asset.width), height / Double(asset.height))
            let fittedWidth = Double(asset.width) * scale
            let fittedHeight = Double(asset.height) * scale
            x += (width - fittedWidth) / 2
            y += (height - fittedHeight) / 2
            width = fittedWidth
            height = fittedHeight
        }
        content += "q \(number(width * Self.scale)) 0 0 \(number(height * Self.scale)) \(number(x * Self.scale)) \(number((279.4 - y - height) * Self.scale)) cm /\(name.rawValue) Do Q\n"
    }
    var content = "0 G 0 g 0.57 w\n"

    static func bytes(_ text: String) -> [UInt8] {
        Array(text.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data())
    }

    static func width(_ text: String, font: InvoicePDFFont, size: Double) -> Double {
        Double(bytes(text).reduce(0) { $0 + font.widths[Int($1)] }) * size / 1000 / scale
    }

    static func lines(_ text: String, width: Double, font: InvoicePDFFont, size: Double) -> [String] {
        var bytes = bytes(text.replacingOccurrences(of: "\r", with: ""))
        while bytes.last == 10 { bytes.removeLast() }
        let maximum = Int(ceil((width - 2) * 1000 / (size / scale)))
        var result: [String] = []
        var separator: Int?; var index = 0; var start = 0; var length = 0
        while index < bytes.count {
            let byte = bytes[index]
            length += font.widths[Int(byte)]
            if byte == 32 || byte == 9 || byte == 10 { separator = index }
            if byte == 10 || length > maximum {
                let end: Int
                if let separator { end = separator; index = separator + 1 }
                else { if index == start { index += 1 }; end = index }
                result.append(String(data: Data(bytes[start..<end]), encoding: .windowsCP1252) ?? "")
                separator = nil; start = index; length = 0
            } else { index += 1 }
        }
        if index != start { result.append(String(data: Data(bytes[start..<index]), encoding: .windowsCP1252) ?? "") }
        return result
    }

    mutating func cell(_ text: String, x: Double, y: Double, width: Double, height: Double,
                       font: InvoicePDFFont = .regular, size: Double = 10, align: String = "L") {
        let measured = Self.width(text, font: font, size: size)
        let offset = align == "C" ? (width - measured) / 2 : align == "R" ? width - 1 - measured : 1
        let baseline = 279.4 - y - height / 2 - 0.3 * size / Self.scale
        // Hex strings prevent PDF syntax injection and retain WinAnsi accents.
        let encoded = Self.bytes(text).map { String(format: "%02X", $0) }.joined()
        content += "BT /F\(font.rawValue + 1) \(number(size)) Tf \(number((x + offset) * Self.scale)) \(number(baseline * Self.scale)) Td <\(encoded)> Tj ET\n"
    }

    mutating func line(_ x: Double, _ y: Double, _ endX: Double, _ endY: Double) {
        content += "\(number(x * Self.scale)) \(number((279.4 - y) * Self.scale)) m \(number(endX * Self.scale)) \(number((279.4 - endY) * Self.scale)) l S\n"
    }

    mutating func rectangle(x: Double, y: Double, width: Double, height: Double) {
        content += "q 0.941 g \(number(x * Self.scale)) \(number((279.4 - y) * Self.scale)) \(number(width * Self.scale)) \(number(-height * Self.scale)) re B Q\n"
    }

    mutating func finishPage() { pages.append(content); content = "0 G 0 g 0.57 w\n" }

    func pdf() -> Data {
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", ""]
        for font in InvoicePDFFont.allCases {
            objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /\(font.name) /Encoding /WinAnsiEncoding >>")
        }
        var imageReferences: [String] = []
        for name in ImageName.allCases {
            guard let asset = images[name] else { continue }
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
        for offset in offsets.dropFirst() { output.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        output.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return output
    }

    private func number(_ value: Double) -> String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) }
}
