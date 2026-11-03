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

#if os(iOS)
import SwiftUI
import UIKit

extension SignatureDrawingTests {
    func testNativeSenderSignatureShowsOriginalSigningLayoutInSpanish() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "signature-fixture", companyID: "company")
        let model = InvoiceDraftEditorModel(store: store, isAuthorized: { true })
        model.content.senderName = "María García"
        let drawing = SignatureDrawing(strokes: [[
            .init(x: 0.16, y: 0.64), .init(x: 0.22, y: 0.20), .init(x: 0.26, y: 0.60),
            .init(x: 0.34, y: 0.28), .init(x: 0.35, y: 0.57), .init(x: 0.46, y: 0.46),
            .init(x: 0.55, y: 0.55), .init(x: 0.69, y: 0.34), .init(x: 0.76, y: 0.57)
        ]])
        let host = UIHostingController(rootView: InvoiceSenderSignatureView(model: model, drawing: drawing)
            .environment(\.locale, Locale(identifier: "es-DO")))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        for dark in [false, true] {
            if dark {
                window.overrideUserInterfaceStyle = .dark
                host.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
            }
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let appearance = dark ? "dark" : "light"
            try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory
                .appending(path: "emsys-sender-signature-\(device)-\(appearance).png"))
        }
        XCTAssertNil(model.currentSenderSignature, "Viewing or dismissing a drawing must not confirm it")
        XCTAssertEqual(drawing.strokes.count, 1)
    }
}
#endif
