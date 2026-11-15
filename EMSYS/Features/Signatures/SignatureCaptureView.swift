import SwiftUI

struct SignatureCaptureView: View {
    @Binding var drawing: SignatureDrawing
    @State private var currentStroke: [SignatureDrawing.Point] = []

    /// Presents the drawing surface and its signing guide.
    var body: some View {
        captureSurface
            .background(Color(white: 0.96))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.gray.opacity(0.5)))
            .overlay(alignment: .bottom) {
                VStack(spacing: 6) {
                    SignatureGuideLine()
                        .stroke(.black.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5]))
                        .frame(height: 1)
                    Text("signature.signAbove")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .accessibilityHint("signature.instructions")
            .onChange(of: drawing.isEmpty) {
                // A cleared draft must also clear any in-progress pointer gesture.
                if drawing.isEmpty {
                    currentStroke = []
                }
            }
            .onDisappear { currentStroke = [] }
    }

    /// Uses native ink on iOS and pointer drawing on macOS.
    @ViewBuilder
    private var captureSurface: some View {
        #if os(iOS)
        NativeSignatureCaptureView(drawing: $drawing)
            .accessibilityLabel("signature.canvas")
            .accessibilityValue(drawing.isEmpty ? Text("signature.empty") : Text("signature.captured"))
        #else
        GeometryReader { geometry in
            Canvas { context, size in
                // Include the unfinished gesture so pointer input redraws immediately.
                for stroke in drawing.strokes + [currentStroke] {
                    guard let first = stroke.first else {
                        continue
                    }
                    let start = CGPoint(x: first.x * size.width, y: first.y * size.height)
                    if stroke.count == 1 {
                        context.fill(Path(ellipseIn: CGRect(
                            x: start.x - 1, y: start.y - 1, width: 2, height: 2
                        )), with: .color(.black))
                    } else {
                        var path = Path()
                        path.move(to: start)
                        for point in stroke.dropFirst() {
                            path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                        }
                        context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .background(Color(white: 0.96))
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Stop recording before exceeding the limits of persisted signatures.
                    let savedPointCount = drawing.strokes.reduce(0) { count, stroke in
                        count + stroke.count
                    }
                    guard currentStroke.count < 20_000, drawing.strokes.count < 1_000,
                          savedPointCount + currentStroke.count < 100_000 else {
                        return
                    }
                    currentStroke.append(point(value.location, in: geometry.size))
                }
                .onEnded { _ in
                    // Commit only a gesture that provided at least one valid point.
                    if !currentStroke.isEmpty {
                        drawing.strokes.append(currentStroke)
                    }
                    currentStroke = []
                }
            )
            .onChange(of: geometry.size) {
                if !currentStroke.isEmpty {
                    drawing.strokes.append(currentStroke)
                    currentStroke = []
                }
            }
            .accessibilityElement()
            .accessibilityLabel("signature.canvas")
            .accessibilityValue(drawing.isEmpty ? Text("signature.empty") : Text("signature.captured"))
        }
        #endif
    }

    /// Normalizes a pointer location to the bounds of the drawing.
    private func point(_ location: CGPoint, in size: CGSize) -> SignatureDrawing.Point {
        SignatureDrawing.Point(
            x: min(1, max(0, location.x / max(1, size.width))),
            y: min(1, max(0, location.y / max(1, size.height)))
        )
    }
}

private struct SignatureGuideLine: Shape {
    /// Draws the horizontal guide inside the supplied rectangle.
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
