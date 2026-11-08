#if os(iOS)
import PencilKit
import SwiftUI
import XCTest
@testable import EMSYS

@MainActor
final class NativeSignatureCaptureTests: XCTestCase {
    private let drawing = SignatureDrawing(strokes: [[
        .init(x: 0.1, y: 0.2), .init(x: 0.5, y: 0.8), .init(x: 0.9, y: 0.3)
    ]])

    func testNativeInkPreservesSignatureThroughPaperResizeAndExport() async throws {
        let canvas = SignatureInkCanvas()
        canvas.drawing = SignatureInk.nativeDrawing(drawing, in: canvas.drawingSize)
        canvas.frame = CGRect(x: 0, y: 0, width: 760, height: 180)
        canvas.layoutIfNeeded()
        XCTAssertEqual(canvas.drawingSize, CGSize(width: 760, height: 180))
        let landscape = try XCTUnwrap(SignatureInk.capture(canvas.drawing, in: canvas.drawingSize))
        XCTAssertFalse(landscape.isEmpty)
        XCTAssertEqual(landscape.strokes.first?.first?.x ?? 0, 0.1, accuracy: 0.01)
        canvas.frame = CGRect(x: 0, y: 0, width: 340, height: 240)
        canvas.setNeedsLayout()
        canvas.layoutIfNeeded()
        let portrait = try XCTUnwrap(SignatureInk.capture(canvas.drawing, in: canvas.drawingSize))
        XCTAssertEqual(portrait.strokes.first?.first?.x ?? 0, 0.1, accuracy: 0.01)
        XCTAssertEqual(portrait.strokes.first?.first?.y ?? 0, 0.2, accuracy: 0.01)
        let png = try await portrait.pngData()
        XCTAssertFalse(png.isEmpty)
    }

    func testSingleTapRemainsAVisibleSignatureMark() throws {
        let dot = SignatureDrawing(strokes: [[.init(x: 0.5, y: 0.5)]])
        let size = CGSize(width: 300, height: 200)
        let captured = try XCTUnwrap(SignatureInk.capture(SignatureInk.nativeDrawing(dot, in: size), in: size))
        XCTAssertFalse(captured.isEmpty)
    }

    func testInvalidNativeInkDoesNotReachPencilKit() {
        let invalid = SignatureDrawing(strokes: [[.init(x: .nan, y: 0.5)]])
        XCTAssertTrue(SignatureInk.nativeDrawing(invalid, in: CGSize(width: 300, height: 200)).strokes.isEmpty)
        XCTAssertNil(SignatureInk.capture(PKDrawing(), in: .zero))
    }

    func testStrokeCommittedAfterToolEndsIsIncludedInSavedDrawing() async throws {
        var saved = SignatureDrawing()
        let coordinator = NativeSignatureCaptureView.Coordinator(
            drawing: Binding(get: { saved }, set: { saved = $0 }))
        let canvas = SignatureInkCanvas()
        canvas.drawing = SignatureInk.nativeDrawing(drawing, in: canvas.drawingSize)
        coordinator.canvasViewDidBeginUsingTool(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(saved.strokes.count, 1)

        var completed = drawing
        completed.strokes.append([.init(x: 0.7, y: 0.2), .init(x: 0.7, y: 0.8)])
        canvas.drawing = SignatureInk.nativeDrawing(completed, in: canvas.drawingSize)
        coordinator.canvasViewDrawingDidChange(canvas)

        XCTAssertEqual(saved.strokes.count, 2)
        let finalStroke = try XCTUnwrap(saved.strokes.last)
        XCTAssertEqual(finalStroke.last?.y ?? 0, 0.8, accuracy: 0.01)
        let png = try await saved.pngData()
        XCTAssertFalse(png.isEmpty)
    }

    func testNativeStrokeCommitsToBindingAndClearAllowsRetry() throws {
        var saved = SignatureDrawing()
        let binding = Binding(get: { saved }, set: { saved = $0 })
        let coordinator = NativeSignatureCaptureView.Coordinator(drawing: binding)
        let canvas = SignatureInkCanvas()
        canvas.drawing = SignatureInk.nativeDrawing(drawing, in: canvas.drawingSize)
        coordinator.canvasViewDidEndUsingTool(canvas)
        XCTAssertFalse(saved.isEmpty)
        saved = SignatureDrawing()
        canvas.drawing = SignatureInk.nativeDrawing(saved, in: canvas.drawingSize)
        coordinator.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(saved.isEmpty)
        canvas.drawing = SignatureInk.nativeDrawing(drawing, in: canvas.drawingSize)
        coordinator.canvasViewDidEndUsingTool(canvas)
        XCTAssertFalse(saved.isEmpty)
    }
}
#endif
