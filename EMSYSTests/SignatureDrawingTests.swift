import ImageIO
import XCTest
@testable import EMSYS

@MainActor
final class SignatureDrawingTests: XCTestCase {
    func testDrawingRoundTripsAndExportsBoundedPNG() async throws {
        let drawing = SignatureDrawing(strokes: [[
            .init(x: 0.1, y: 0.2), .init(x: 0.6, y: 0.7), .init(x: 0.9, y: 0.3)
        ]])
        let restored = try JSONDecoder().decode(SignatureDrawing.self, from: JSONEncoder().encode(drawing))
        XCTAssertEqual(restored, drawing)
        let output = try await restored.pngData()
        XCTAssertLessThanOrEqual(output.count, 2 * 1024 * 1024)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1024)
        XCTAssertEqual(image.height, 384)
        let pixels = try XCTUnwrap(image.dataProvider?.data)
        let bytes = pixels as Data
        XCTAssertTrue(bytes.contains(0), "The exported image must contain dark ink")
    }

    func testEmptyInvalidCoordinatesAndOversizedImagesAreRejected() async {
        await assertRejected(SignatureDrawing())
        let invalid = SignatureDrawing(strokes: [[.init(x: .nan, y: 0.5)]])
        await assertRejected(invalid)
        let drawing = SignatureDrawing(strokes: [[.init(x: 0.5, y: 0.5)]])
        await assertRejected(drawing, width: 4096, height: 4096)
        await assertRejected(drawing, width: -1, height: 100)
    }

    private func assertRejected(_ drawing: SignatureDrawing, width: Int = 1024, height: Int = 384) async {
        do {
            _ = try await drawing.pngData(width: width, height: height)
            XCTFail("Expected invalid signature export to fail")
        } catch {
            XCTAssertTrue(error is SignatureDrawing.DrawingError)
        }
    }
}
