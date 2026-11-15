#if os(iOS)
import PencilKit
import SwiftUI

/// Uses the legacy app's native ink input while retaining the current offline format.
struct NativeSignatureCaptureView: UIViewRepresentable {
    @Binding var drawing: SignatureDrawing

    /// Creates the bridge between PencilKit input and the saved drawing.
    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    /// Sets up a signature canvas with the existing draft strokes.
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

    /// Updates the native canvas after SwiftUI changes the draft.
    func updateUIView(_ canvas: SignatureInkCanvas, context: Context) {
        // An external clear or restored draft replaces the native canvas drawing.
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

        /// Keeps the current binding and the last successfully published drawing.
        init(drawing: Binding<SignatureDrawing>) {
            self.drawing = drawing
            lastPublished = drawing.wrappedValue
        }

        /// Marks the gesture as in progress until PencilKit finishes the stroke.
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isUsingTool = true
        }

        /// Publishes normalized ink after the tool ends its gesture.
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isUsingTool = false
            publishDrawing(from: canvasView)
        }

        /// Publishes final changes that arrive after the tool callback.
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // PencilKit can commit the final stroke after the tool-end callback.
            guard !isUsingTool, let canvas = canvasView as? SignatureInkCanvas,
                  !canvas.isReplacingDrawing else {
                return
            }
            publishDrawing(from: canvasView)
        }

        /// Updates the binding with valid new ink or restores the last accepted drawing.
        private func publishDrawing(from canvasView: PKCanvasView) {
            guard let canvas = canvasView as? SignatureInkCanvas else {
                return
            }
            // Restore the last valid drawing if the native input exceeds upload limits.
            guard let captured = SignatureInk.capture(canvas.drawing, in: canvas.drawingSize) else {
                canvas.replaceDrawing(SignatureInk.nativeDrawing(lastPublished, in: canvas.drawingSize))
                return
            }
            guard captured != lastPublished else {
                return
            }
            lastPublished = captured
            drawing.wrappedValue = captured
        }
    }
}

final class SignatureInkCanvas: PKCanvasView {
    private(set) var drawingSize = CGSize(
        width: CGFloat(SignatureDrawing.defaultWidth), height: CGFloat(SignatureDrawing.defaultHeight))

    private(set) var isReplacingDrawing = false

    /// Applies a programmatic drawing without publishing it as new input.
    func replaceDrawing(_ replacement: PKDrawing) {
        isReplacingDrawing = true
        drawing = replacement
        isReplacingDrawing = false
    }

    /// Fits existing ink to the new canvas size when its geometry changes.
    override func layoutSubviews() {
        super.layoutSubviews()
        let nextSize = bounds.size
        guard nextSize.width > 0, nextSize.height > 0, nextSize != drawingSize else {
            return
        }
        // Resize existing ink with its paper instead of clearing or clipping it on rotation.
        replaceDrawing(drawing.transformed(using: CGAffineTransform(
            scaleX: nextSize.width / drawingSize.width,
            y: nextSize.height / drawingSize.height)))
        drawingSize = nextSize
        contentSize = nextSize
    }
}

enum SignatureInk {
    /// Converts PencilKit strokes into normalized points for the offline draft.
    static func capture(_ native: PKDrawing, in size: CGSize) -> SignatureDrawing? {
        guard size.width > 0, size.height > 0, native.strokes.count <= 1_000 else {
            return nil
        }
        var result = SignatureDrawing()
        var count = 0
        // Sample transformed stroke points and keep a consistent point budget.
        for stroke in native.strokes {
            var points: [SignatureDrawing.Point] = []
            for sample in stroke.path.interpolatedPoints(by: .distance(1)) {
                let location = sample.location.applying(stroke.transform)
                count += 1
                guard count <= 100_000, points.count < 20_000,
                      location.x.isFinite, location.y.isFinite else {
                    return nil
                }
                points.append(.init(
                    x: min(1, max(0, location.x / size.width)),
                    y: min(1, max(0, location.y / size.height))))
            }
            if !points.isEmpty {
                result.strokes.append(points)
            }
        }
        return result
    }

    /// Rebuilds PencilKit strokes from validated normalized ink.
    static func nativeDrawing(_ drawing: SignatureDrawing, in size: CGSize) -> PKDrawing {
        // Blank or invalid geometry should never be sent into PencilKit.
        guard size.width > 0, size.height > 0, drawing.hasValidStrokes else {
            return PKDrawing()
        }
        let strokes = drawing.strokes.compactMap { points -> PKStroke? in
            guard !points.isEmpty else {
                return nil
            }
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
