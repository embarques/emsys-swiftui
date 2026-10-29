import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Normalized coordinates keep a signature independent of screen dimensions.
/// Persist this drawing with its pending business operation before uploading.
nonisolated struct SignatureDrawing: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
    }

    enum DrawingError: Error {
        case empty
        case invalidDrawing
        case renderingFailed
    }

    var strokes: [[Point]] = []

    var isEmpty: Bool { strokes.allSatisfy(\.isEmpty) }

    func pngData(width: Int = 1024, height: Int = 384) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try renderPNG(width: width, height: height)
        }.value
    }

    private func renderPNG(width: Int, height: Int) throws -> Data {
        guard !isEmpty else { throw DrawingError.empty }
        guard (1...4096).contains(width), (1...4096).contains(height),
              width * height <= 4_000_000,
              strokes.count <= 1_000,
              strokes.reduce(0, { $0 + $1.count }) <= 100_000,
              strokes.joined().allSatisfy({
                  $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
              }) else { throw DrawingError.invalidDrawing }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw DrawingError.renderingFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        let lineWidth = max(2, CGFloat(width) / 512)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            try Task.checkCancellation()
            guard let first = stroke.first else { continue }
            let origin = CGPoint(x: first.x * Double(width), y: first.y * Double(height))
            if stroke.count == 1 {
                context.fillEllipse(in: CGRect(
                    x: origin.x - lineWidth / 2, y: origin.y - lineWidth / 2,
                    width: lineWidth, height: lineWidth
                ))
            } else {
                context.beginPath()
                context.move(to: origin)
                for point in stroke.dropFirst() {
                    context.addLine(to: CGPoint(x: point.x * Double(width), y: point.y * Double(height)))
                }
                context.strokePath()
            }
        }
        guard let image = context.makeImage() else { throw DrawingError.renderingFailed }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw DrawingError.renderingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 2 * 1024 * 1024 else {
            throw DrawingError.renderingFailed
        }
        return output as Data
    }
}
