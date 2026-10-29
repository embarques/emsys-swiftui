import SwiftUI

struct SignatureCaptureView: View {
    @Binding var drawing: SignatureDrawing
    @State private var currentStroke: [SignatureDrawing.Point] = []

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            Text("signature.instructions")
            GeometryReader { geometry in
                Canvas { context, size in
                    for stroke in drawing.strokes + [currentStroke] {
                        guard let first = stroke.first else { continue }
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
                .background(.white)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard currentStroke.count < 20_000, drawing.strokes.count < 1_000,
                              drawing.strokes.reduce(0, { $0 + $1.count }) + currentStroke.count < 100_000 else { return }
                        currentStroke.append(point(value.location, in: geometry.size))
                    }
                    .onEnded { _ in
                        if !currentStroke.isEmpty { drawing.strokes.append(currentStroke) }
                        currentStroke = []
                    }
                )
                .accessibilityElement()
                .accessibilityLabel("signature.canvas")
                .accessibilityValue(drawing.isEmpty ? Text("signature.empty") : Text("signature.captured"))
            }
            .frame(minHeight: 180, idealHeight: 250, maxHeight: 400)
            .clipShape(RoundedRectangle(cornerRadius: AppStyle.Layout.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: AppStyle.Layout.cornerRadius).stroke(.gray))
            Button("signature.clear", role: .destructive) {
                drawing = SignatureDrawing()
                currentStroke = []
            }
            .disabled(drawing.isEmpty && currentStroke.isEmpty)
        }
        .onDisappear { currentStroke = [] }
    }

    private func point(_ location: CGPoint, in size: CGSize) -> SignatureDrawing.Point {
        SignatureDrawing.Point(
            x: min(1, max(0, location.x / max(1, size.width))),
            y: min(1, max(0, location.y / max(1, size.height)))
        )
    }
}
