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

    func testSignatureCanvasFitsPortraitAndCompactLandscapeWithoutFooterCrowding() {
        let portrait = CGSize(width: 390, height: 650)
        let landscape = CGSize(width: 760, height: 250)
        let portraitHeight = InvoiceSenderSignatureView.canvasHeight(
            in: portrait, compact: false, padding: 24, accessibility: false)
        let landscapeHeight = InvoiceSenderSignatureView.canvasHeight(
            in: landscape, compact: true, padding: 12, accessibility: false)
        XCTAssertGreaterThan(portraitHeight, 200)
        XCTAssertGreaterThanOrEqual(landscapeHeight, 150)
        XCTAssertLessThanOrEqual(landscapeHeight + 90, landscape.height)
        let accessibleHeight = InvoiceSenderSignatureView.canvasHeight(
            in: CGSize(width: 600, height: 650), compact: false, padding: 24, accessibility: true)
        XCTAssertGreaterThanOrEqual(accessibleHeight, 100)
        XCTAssertLessThanOrEqual(accessibleHeight + 300, 650)
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
    func testNativeCaptureAndPreviewRenderInSpanishAcrossAppearances() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "signature-fixture", companyID: "company")
        let model = InvoiceDraftEditorModel(store: store, isAuthorized: { true })
        model.content.senderName = "María García Hernández"
        model.content.senderCustomer = InvoiceCustomer(id: "68f800000000000000000001", name: model.content.senderName,
            customerType: 1, active: true, phones: nil, addresses: nil)
        let drawing = SignatureDrawing(strokes: [[
            .init(x: 0.16, y: 0.64), .init(x: 0.22, y: 0.20), .init(x: 0.26, y: 0.60),
            .init(x: 0.34, y: 0.28), .init(x: 0.35, y: 0.57), .init(x: 0.46, y: 0.46),
            .init(x: 0.55, y: 0.55), .init(x: 0.69, y: 0.34), .init(x: 0.76, y: 0.57)
        ]])
        let host = UIHostingController(rootView: AnyView(ZStack {
            Color(red: 1, green: 0, blue: 1).ignoresSafeArea()
            VStack {
                ForEach(0..<20) { _ in
                    Text("INVOICE POLICY AND CREATE CONTROLS MUST STAY BEHIND THE POPUP")
                        .font(.title.bold()).foregroundStyle(.green)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: .constant(true)) {
                InvoiceSenderSignatureView(model: model, drawing: drawing)
            }
            .environment(\.locale, Locale(identifier: "es-DO"))))
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
            XCTAssertNotNil(host.presentedViewController?.sheetPresentationController,
                "Signature capture must use a native sheet instead of a full-screen cover")
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let presented = try XCTUnwrap(host.presentedViewController)
            let sample = presented.view.convert(
                CGPoint(x: 4, y: presented.view.bounds.midY), to: window)
            assertOpaqueSignatureSurface(image, at: sample)
            let appearance = dark ? "dark" : "light"
            try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory
                .appending(path: "emsys-sender-signature-\(device)-\(appearance).png"))
        }
        host.dismiss(animated: false)
        let landscapeHost = UIHostingController(rootView: AnyView(
            InvoiceSenderSignatureView(model: model, drawing: drawing)
                .environment(\.locale, Locale(identifier: "es-DO"))))
        landscapeHost.safeAreaRegions = []
        let landscapeWindow = UIWindow(windowScene: scene)
        landscapeWindow.frame = CGRect(x: 0, y: 0, width: 760, height: 300)
        landscapeWindow.rootViewController = landscapeHost
        landscapeWindow.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(300))
        landscapeWindow.layoutIfNeeded()
        let landscape = UIGraphicsImageRenderer(bounds: landscapeWindow.bounds).image { _ in
            landscapeWindow.drawHierarchy(in: landscapeWindow.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(landscape.pngData()).write(to: FileManager.default.temporaryDirectory
            .appending(path: "emsys-sender-signature-\(device)-landscape.png"))
        landscapeWindow.isHidden = true
        window.makeKeyAndVisible()
        XCTAssertNil(model.currentSenderSignature, "Rotation/layout must not apply a signature")
        // Previewing a saved image must never apply a replacement to the draft.
        let png = try await drawing.pngData()
        host.rootView = AnyView(ScrollView {
            InvoiceSignaturePreview(png: png, signerName: model.content.senderName,
                capturedAt: Date(timeIntervalSince1970: 1_793_858_400), edit: {})
                .padding(24)
        }.environment(\.locale, Locale(identifier: "es-DO")))
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            host.traitOverrides.preferredContentSizeCategory = dark ? .accessibilityLarge : .large
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let appearance = dark ? "dark" : "light"
            try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory
                .appending(path: "emsys-signature-preview-\(device)-\(appearance).png"))
        }
        XCTAssertNil(model.currentSenderSignature, "Viewing or dismissing a drawing must not confirm it")
        XCTAssertEqual(drawing.strokes.count, 1)
    }

    private func assertOpaqueSignatureSurface(_ image: UIImage, at point: CGPoint,
                                             file: StaticString = #filePath, line: UInt = #line) {
        guard let source = image.cgImage else {
            XCTFail("Missing rendered popup image", file: file, line: line)
            return
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        let rendered = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            let x = floor(point.x * image.scale)
            let y = floor(point.y * image.scale)
            context.translateBy(x: -x, y: -(CGFloat(source.height) - y - 1))
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            return true
        }
        XCTAssertTrue(rendered, file: file, line: line)
        // A neutral opaque surface must not inherit the magenta invoice underlay.
        XCTAssertLessThan(abs(Int(pixel[0]) - Int(pixel[1])), 12, file: file, line: line)
        XCTAssertLessThan(abs(Int(pixel[2]) - Int(pixel[1])), 12, file: file, line: line)
    }
}
#endif

#if os(macOS)
import AppKit
import SwiftUI

extension SignatureDrawingTests {
    func testMacSignatureCaptureAndPreviewRenderWithSavedSignerMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "signature-fixture", companyID: "company")
        let model = InvoiceDraftEditorModel(store: store, isAuthorized: { true })
        model.content.senderName = "María García Hernández"
        model.content.senderCustomer = InvoiceCustomer(id: "68f800000000000000000001", name: model.content.senderName,
            customerType: 1, active: true, phones: nil, addresses: nil)
        let drawing = SignatureDrawing(strokes: [[.init(x: 0.15, y: 0.6), .init(x: 0.3, y: 0.2), .init(x: 0.4, y: 0.7), .init(x: 0.8, y: 0.4)]])
        try await captureMacSignature(AnyView(InvoiceSenderSignatureView(model: model, drawing: drawing)),
            name: "capture", dark: false)
        let png = try await drawing.pngData()
        for dark in [false, true] {
            try await captureMacSignature(AnyView(InvoiceSignaturePreview(png: png, signerName: model.content.senderName,
                capturedAt: Date(timeIntervalSince1970: 1_793_858_400), edit: {})
                .padding(24)), name: dark ? "preview-dark" : "preview-light", dark: dark)
        }
        XCTAssertNil(model.currentSenderSignature)
    }

    private func captureMacSignature(_ view: AnyView, name: String, dark: Bool) async throws {
        let host = NSHostingView(rootView: view
            .environment(\.locale, Locale(identifier: "es-DO"))
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: 800, height: 720, alignment: .top)
            .background(.background))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 720),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appending(path: "emsys-signature-mac-\(name).png"))
    }
}
#endif
