import SwiftUI
import XCTest
@testable import EMSYS

@MainActor
final class InvoiceCreationTests: XCTestCase {
    func testTotalsUseRoundedLinesAndExplicitOverrides() throws {
        let first = InvoiceDraft.Item(name: "Box", quantity: "3", unitPrice: "0.335", labelCount: "2")
        let second = InvoiceDraft.Item(name: "Bag", quantity: "2", unitPrice: "5", total: "7.125")
        let amounts = try InvoiceDraftAmounts(items: [first, second])
        XCTAssertEqual(try XCTUnwrap(amounts.lineTotals[first.id]), 1.01, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(amounts.lineTotals[second.id]), 7.13, accuracy: 0.001)
        XCTAssertEqual(amounts.subtotal, 8.14, accuracy: 0.001)
    }

    func testInvalidFinancialInputNeverProducesPreviewTotals() throws {
        for item in [
            InvoiceDraft.Item(name: "", unitPrice: "1"),
            InvoiceDraft.Item(name: "Box", quantity: "0", unitPrice: "1"),
            InvoiceDraft.Item(name: "Box", quantity: "nan", unitPrice: "1"),
            InvoiceDraft.Item(name: "Box", unitPrice: "-1"),
            InvoiceDraft.Item(name: "Box", unitPrice: "1", labelCount: "256"),
            InvoiceDraft.Item(name: "Box", unitPrice: "1", total: "unfinished"),
            InvoiceDraft.Item(name: "Box", quantity: "1e300", unitPrice: "1e300")
        ] { XCTAssertThrowsError(try InvoiceDraftAmounts(items: [item])) }
    }

    func testAutomaticLabelsRequireWholeByteSizedQuantityAndTrimmedExplicitLabelsWork() throws {
        XCTAssertThrowsError(try InvoiceDraftAmounts(items: [.init(name: "Box", quantity: "1.5", unitPrice: "2")]))
        XCTAssertThrowsError(try InvoiceDraftAmounts(items: [.init(name: "Box", quantity: "256", unitPrice: "2")]))
        let totals = try InvoiceDraftAmounts(items: [.init(name: "Box", quantity: " 1.5 ", unitPrice: " 2 ", labelCount: " 1 ")])
        XCTAssertEqual(totals.subtotal, 3)
    }

    func testRemovingABoundItemPreservesOtherRowsAndTheLastRowCanBeRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let model = InvoiceDraftEditorModel(store: store, isAuthorized: { true })
        let first = InvoiceDraft.Item(name: "First box", quantity: "2", unitPrice: "10")
        let second = InvoiceDraft.Item(name: "Second box", quantity: "unfinished", unitPrice: "5")
        model.content.items = [first, second]
        let boundRow = Binding(get: { model.content.items[0] }, set: { model.content.items[0] = $0 })
        // Resolve the same bound row used by the form before the mutation. The
        // previous view read it from inside removeAll and trapped at runtime.
        model.removeItem(id: boundRow.wrappedValue.id)
        XCTAssertEqual(model.content.items, [second])
        model.removeItem(id: first.id)
        XCTAssertEqual(model.content.items, [second])
        model.removeItem(id: second.id)
        XCTAssertTrue(model.content.items.isEmpty)
        XCTAssertNotNil(model.validationIssue(for: .items))
        let saved = try await store.saveDraft(id: UUID(), content: model.content, expectedRevision: nil)
        let restored = try await store.draft(id: saved.id)
        XCTAssertEqual(restored?.content.items, [])
    }

    func testPaymentLocationsUseScopedCachedBranchCodesOffline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        try await store.savePickupBranches([
            .init(id: 1, name: "New York", code: "NY", type: "office"),
            .init(id: 2, name: "Other New York", code: "NY", type: "office"),
            .init(id: 3, name: "Unnamed region", code: nil, type: "warehouse"),
            .init(id: 4, name: "Dominican Republic", code: "RD", type: "office")
        ])
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.test/v1"))) { _ in
            XCTFail("Offline selection must not request credentials")
            throw APIClientError.missingCredentials
        }
        let model = InvoiceDraftEditorModel(store: store, client: client,
            canViewAssignments: { _ in true }, isAuthorized: { true })
        await model.loadPaymentLocations(online: false)
        XCTAssertEqual(model.paymentLocations.compactMap(\.code), ["NY", "RD"])
        XCTAssertNil(model.content.paymentReview)
        let denied = InvoiceDraftEditorModel(store: store, client: client, isAuthorized: { true })
        await denied.loadPaymentLocations(online: false)
        XCTAssertTrue(denied.paymentLocations.isEmpty)
    }

    func testWizardRequiresCurrentStepAndRestoresDraftPosition() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let model = InvoiceDraftEditorModel(store: store, isAuthorized: { true })
        model.continueCreation()
        XCTAssertEqual(model.step, .customers)
        XCTAssertNil(model.stepIssue)
        XCTAssertNil(model.content.container)
        XCTAssertNil(model.content.pickupSource)
        model.content.wizardStep = .items
        model.content.items = [InvoiceDraft.Item(name: "Box", quantity: "2", unitPrice: "10")]
        model.continueCreation()
        XCTAssertEqual(model.step, .payment)
        model.continueCreation()
        XCTAssertEqual(model.step, .payment)
        XCTAssertNotNil(model.stepIssue)
        model.goBack()
        XCTAssertEqual(model.step, .items)
        XCTAssertNil(model.stepIssue)
        await model.save()
        let drafts = try await store.draftSummaries()
        let restored = InvoiceDraftEditorModel(draftID: try XCTUnwrap(drafts.first?.id), store: store, isAuthorized: { true })
        await restored.load()
        XCTAssertEqual(restored.step, .items)
        XCTAssertEqual(restored.content.items, model.content.items)
    }
}
