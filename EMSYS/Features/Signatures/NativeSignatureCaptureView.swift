#if os(iOS)
import PencilKit
import SwiftUI

/// Uses the legacy app's native ink input while retaining the current offline format.
struct NativeSignatureCaptureView: UIViewRepresentable {
    @Binding var drawing: SignatureDrawing

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    func makeUIView(context: Context) -> SignatureInkCanvas {
        let canvas = SignatureInkCanvas()
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 2)
        canvas.isScrollEnabled = false
        canvas.backgroundColor = UIColor(white: 0.96, alpha: 1)
        canvas.overrideUserInterfaceStyle = .light
        canvas.replaceDrawing(SignatureInk.nativeDrawing(drawing, in: canvas.drawingSize))
        return canvas
    }

    func updateUIView(_ canvas: SignatureInkCanvas, context: Context) {
        context.coordinator.drawing = $drawing
        if drawing != context.coordinator.lastPublished {
            context.coordinator.lastPublished = drawing
            canvas.replaceDrawing(SignatureInk.nativeDrawing(drawing, in: canvas.drawingSize))
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var drawing: Binding<SignatureDrawing>
        var lastPublished: SignatureDrawing
        private var isUsingTool = false

        init(drawing: Binding<SignatureDrawing>) {
            self.drawing = drawing
            lastPublished = drawing.wrappedValue
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isUsingTool = true
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isUsingTool = false
            publishDrawing(from: canvasView)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // PencilKit can commit the final stroke after the tool-end callback.
            guard !isUsingTool, let canvas = canvasView as? SignatureInkCanvas,
                  !canvas.isReplacingDrawing else { return }
            publishDrawing(from: canvasView)
        }

        private func publishDrawing(from canvasView: PKCanvasView) {
            guard let canvas = canvasView as? SignatureInkCanvas else { return }
            guard let captured = SignatureInk.capture(canvas.drawing, in: canvas.drawingSize) else {
                canvas.replaceDrawing(SignatureInk.nativeDrawing(lastPublished, in: canvas.drawingSize))
                return
            }
            guard captured != lastPublished else { return }
            lastPublished = captured
            drawing.wrappedValue = captured
        }
    }
}

final class SignatureInkCanvas: PKCanvasView {
    private(set) var drawingSize = CGSize(
        width: CGFloat(SignatureDrawing.defaultWidth), height: CGFloat(SignatureDrawing.defaultHeight))

    private(set) var isReplacingDrawing = false

    func replaceDrawing(_ replacement: PKDrawing) {
        isReplacingDrawing = true
        drawing = replacement
        isReplacingDrawing = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let nextSize = bounds.size
        guard nextSize.width > 0, nextSize.height > 0, nextSize != drawingSize else { return }
        // Resize existing ink with its paper instead of clearing or clipping it on rotation.
        replaceDrawing(drawing.transformed(using: CGAffineTransform(
            scaleX: nextSize.width / drawingSize.width,
            y: nextSize.height / drawingSize.height)))
        drawingSize = nextSize
        contentSize = nextSize
    }
}

enum SignatureInk {
    static func capture(_ native: PKDrawing, in size: CGSize) -> SignatureDrawing? {
        guard size.width > 0, size.height > 0, native.strokes.count <= 1_000 else { return nil }
        var result = SignatureDrawing()
        var count = 0
        for stroke in native.strokes {
            var points: [SignatureDrawing.Point] = []
            for sample in stroke.path.interpolatedPoints(by: .distance(1)) {
                let location = sample.location.applying(stroke.transform)
                count += 1
                guard count <= 100_000, points.count < 20_000,
                      location.x.isFinite, location.y.isFinite else { return nil }
                points.append(.init(
                    x: min(1, max(0, location.x / size.width)),
                    y: min(1, max(0, location.y / size.height))))
            }
            if !points.isEmpty { result.strokes.append(points) }
        }
        return result
    }

    static func nativeDrawing(_ drawing: SignatureDrawing, in size: CGSize) -> PKDrawing {
        guard size.width > 0, size.height > 0, drawing.strokes.count <= 1_000,
              drawing.strokes.reduce(0, { $0 + $1.count }) <= 100_000,
              drawing.strokes.joined().allSatisfy({
                  $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
              }) else { return PKDrawing() }
        let strokes = drawing.strokes.compactMap { points -> PKStroke? in
            guard !points.isEmpty else { return nil }
            let controls = points.enumerated().map { index, point in
                PKStrokePoint(
                    location: CGPoint(x: point.x * size.width, y: point.y * size.height),
                    timeOffset: Double(index) / 120, size: CGSize(width: 2, height: 2),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black),
                path: PKStrokePath(controlPoints: controls, creationDate: .distantPast))
        }
        return PKDrawing(strokes: strokes)
    }
}
#endif
