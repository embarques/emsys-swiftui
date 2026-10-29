import XCTest
@testable import EMSYS

@MainActor
final class InvoiceDraftConfirmationTests: XCTestCase {
    func testReviewIsBoundToContentButNotWizardPosition() throws {
        var content = InvoiceDraft.Content()
        content.senderName = "Test Sender"
        let confirmation = InvoiceDraftConfirmation(contextHash: try InvoiceDraftConfirmation.contextHash(for: content),
            policiesAgreed: true, skipSignature: true)
        content.confirmation = confirmation
        content.wizardStep = .review
        XCTAssertTrue(confirmation.matches(content))
        content.wizardStep = .customers
        XCTAssertTrue(confirmation.matches(content))
        content.senderName = "Changed Sender"
        XCTAssertFalse(confirmation.matches(content))
        content.senderName = "Test Sender"
        content.items[0].quantity = "2"
        XCTAssertFalse(confirmation.matches(content))
    }

    func testCapturedPNGSurvivesReopenAndChangesRequireNewConfirmation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let model = InvoiceDraftEditorModel(store: store, isAuthorized: { true })
        model.content.senderCustomer = InvoiceCustomer(id: "68f800000000000000000001", name: "Sender", customerType: 1,
            active: true, phones: nil, addresses: nil)
        model.content.senderName = "Sender"
        model.content.policies = []
        model.setPoliciesAgreed(true)
        let drawing = SignatureDrawing(strokes: [[.init(x: 0.1, y: 0.1), .init(x: 0.8, y: 0.8)]])
        let captured = await model.captureSignature(drawing)
        XCTAssertTrue(captured)
        let png = try XCTUnwrap(model.currentSenderSignature?.pngData)
        await model.save()
        let summaries = try await store.draftSummaries()
        let restored = InvoiceDraftEditorModel(draftID: try XCTUnwrap(summaries.first?.id), store: store, isAuthorized: { true })
        await restored.load()
        XCTAssertEqual(restored.currentSenderSignature?.pngData, png)
        XCTAssertEqual(restored.currentConfirmation?.policiesAgreed, true)
        restored.content.items[0].total = "15"
        XCTAssertNil(restored.currentConfirmation)
        restored.setSkipSignature(false)
        XCTAssertNil(restored.currentSenderSignature?.pngData)
        XCTAssertEqual(restored.currentConfirmation?.policiesAgreed, false)
    }

    func testLegacySignatureUpgradesToAPIFieldsWithoutLosingReviewOrDraftData() async throws {
        var content = InvoiceDraft.Content()
        content.senderName = "Legacy Sender"
        content.items[0].name = "Original merchandise"
        content.policies = []
        let png = try await SignatureDrawing(strokes: [[.init(x: 0.1, y: 0.2), .init(x: 0.8, y: 0.7)]]).pngData()
        content.confirmation = InvoiceDraftConfirmation(contextHash: try InvoiceDraftConfirmation.contextHash(for: content),
            policiesAgreed: true, skipSignature: false)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [String: Any])
        var confirmation = try XCTUnwrap(legacy["confirmation"] as? [String: Any])
        confirmation["signaturePNG"] = png.base64EncodedString()
        legacy["confirmation"] = confirmation
        let restored = try JSONDecoder().decode(InvoiceDraft.Content.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.senderSignature?.signerName, "Legacy Sender")
        XCTAssertEqual(restored.senderSignature?.data, png.base64EncodedString())
        XCTAssertEqual(restored.senderSignature?.contentType, "image/png")
        XCTAssertEqual(restored.senderSignature?.pngData, png)
        XCTAssertEqual(restored.confirmation?.matches(restored), true)
        XCTAssertEqual(restored.confirmation?.policiesAgreed, true)
        XCTAssertEqual(restored.items, content.items)
        let upgraded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        XCTAssertNil((upgraded["confirmation"] as? [String: Any])?["signaturePNG"])
        XCTAssertEqual((upgraded["senderSignature"] as? [String: Any])?["data"] as? String, png.base64EncodedString())
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let saved = try await store.saveDraft(id: UUID(), content: restored, expectedRevision: nil)
        let reopened = try await store.draft(id: saved.id)
        XCTAssertEqual(reopened?.content.senderSignature, restored.senderSignature)
        XCTAssertEqual(reopened?.content.confirmation?.matches(restored), true)
        legacy["senderName"] = ""
        let incomplete = try JSONDecoder().decode(InvoiceDraft.Content.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(incomplete.senderSignature?.pngData, png)
        XCTAssertEqual(incomplete.senderSignature?.isValid, false)
        XCTAssertEqual(incomplete.confirmation?.matches(incomplete), false)
        let incompleteDraft = try await store.saveDraft(id: UUID(), content: incomplete, expectedRevision: nil)
        let incompleteRestored = try await store.draft(id: incompleteDraft.id)
        XCTAssertEqual(incompleteRestored?.content.senderSignature?.pngData, png)
    }

    func testInvalidImagesAndUnknownPoliciesCannotBeConfirmed() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let model = InvoiceDraftEditorModel(store: store, isAuthorized: { true })
        model.setPoliciesAgreed(true)
        XCTAssertNil(model.currentConfirmation)
        let invalid = InvoiceDraftConfirmation(contextHash: Data(repeating: 0, count: 32), policiesAgreed: true,
            skipSignature: false)
        let signature = InvoiceSenderSignature(signerName: "Sender", data: Data("not an image".utf8).base64EncodedString(), contentType: "image/png")
        XCTAssertFalse(signature.isValid)
        model.content.confirmation = invalid
        model.content.senderSignature = signature
        await model.save()
        XCTAssertFalse(model.didSave)
        XCTAssertNotNil(model.issue)
    }
}
