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

    static let defaultWidth = 1024
    static let defaultHeight = 384
    static let aspectRatio = Double(defaultWidth) / Double(defaultHeight)

    var strokes: [[Point]] = []

    /// Indicates whether any strokes contain ink.
    var isEmpty: Bool { strokes.allSatisfy(\.isEmpty) }

    /// Checks the maximum point and stroke counts and each normalized coordinate.
    var hasValidStrokes: Bool {
        // Bound the renderer and platform drawing before examining the points.
        guard strokes.count <= 1_000 else {
            return false
        }
        var pointCount = 0
        for stroke in strokes {
            pointCount += stroke.count
            guard pointCount <= 100_000 else {
                return false
            }
            for point in stroke {
                guard point.x.isFinite, point.y.isFinite,
                      (0...1).contains(point.x), (0...1).contains(point.y) else {
                    return false
                }
            }
        }
        return true
    }

    /// Renders a compressed PNG off the main actor.
    func pngData(width: Int = SignatureDrawing.defaultWidth, height: Int = SignatureDrawing.defaultHeight) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try renderPNG(width: width, height: height)
        }.value
    }

    /// Rasterizes validated strokes and returns the bounded PNG bytes.
    private func renderPNG(width: Int, height: Int) throws -> Data {
        guard !isEmpty else {
            throw DrawingError.empty
        }

        // Bound output dimensions before allocating the bitmap.
        guard (1...4096).contains(width), (1...4096).contains(height),
              width * height <= 4_000_000, hasValidStrokes else {
            throw DrawingError.invalidDrawing
        }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DrawingError.renderingFailed
        }
        // Draw onto white paper and convert top-left ink coordinates to Core Graphics.
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
        // A tap produces a dot. Longer gestures use round-capped strokes.
        for stroke in strokes {
            try Task.checkCancellation()
            guard let first = stroke.first else {
                continue
            }
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
        guard let image = context.makeImage() else {
            throw DrawingError.renderingFailed
        }
        // Keep the upload payload bounded after PNG compression.
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
