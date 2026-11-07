import XCTest
@testable import EMSYS

@MainActor
final class InvoiceDraftPaymentTests: XCTestCase {
    func testPaymentMethodIdentitiesMatchTheAPICatalog() {
        XCTAssertEqual(InvoiceDraftPayment.Method.cash.lookupID, 1)
        XCTAssertEqual(InvoiceDraftPayment.Method.check.lookupID, 2)
        XCTAssertEqual(InvoiceDraftPayment.Method.deposit.lookupID, 3)
        XCTAssertEqual(InvoiceDraftPayment.Method.zelle.lookupID, 4)
        XCTAssertEqual(InvoiceDraftPayment.Method.creditCard.lookupID, 5)
    }

    func testSelectingTheCurrentMethodPreservesDetailsAndChangingItClearsIncompatibleFields() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        var authorized = true
        let model = InvoiceDraftEditorModel(store: store, financialPermission: { _ in authorized }, isAuthorized: { true })
        model.setPaymentMode(.record)
        model.setPaymentMethod(.check)
        model.content.payment?.amount = "12.50"
        model.content.payment?.bankAccount = .init(id: 1, name: "Bank", displayName: nil, type: "BANK")
        model.content.payment?.checkNumber = "CHECK-1"
        model.content.payment?.description = "Initial payment"
        let payment = model.content.payment
        model.setPaymentMethod(.check)
        XCTAssertEqual(model.content.payment, payment)
        authorized = false
        model.setPaymentMethod(.cash)
        XCTAssertEqual(model.content.payment, payment)
        authorized = true
        model.setPaymentMethod(.cash)
        XCTAssertNil(model.content.payment?.bankAccount)
        XCTAssertEqual(model.content.payment?.checkNumber, "")
        XCTAssertEqual(model.content.payment?.amount, "12.50")
        XCTAssertEqual(model.content.payment?.description, "Initial payment")
        model.setPaymentMode(.skip)
        XCTAssertEqual(model.content.payment?.totals(subtotal: 20)?.balance, 20)
        model.setPaymentMode(.record)
        XCTAssertEqual(model.content.payment?.totals(subtotal: 20)?.balance, 7.5)
    }

    func testSkipNeverCountsAnUnsubmittedPaymentAndAmountsCannotOverpay() {
        var payment = InvoiceDraftPayment(mode: .skip)
        payment.amount = "99"
        payment.discount = "2.125"
        XCTAssertEqual(payment.totals(subtotal: 10)?.payment, 0)
        XCTAssertEqual(payment.totals(subtotal: 10)?.discount, 2.13)
        XCTAssertEqual(payment.totals(subtotal: 10)?.balance, 7.87)
        payment.mode = .record
        XCTAssertNil(payment.totals(subtotal: 10))
        for invalid in ["-0.001", "-1", "nan", "inf", "unfinished"] {
            payment.amount = invalid
            XCTAssertNil(payment.totals(subtotal: 10))
        }
        payment.amount = "1"
        payment.discount = "-0.001"
        XCTAssertNil(payment.totals(subtotal: 10))
    }

    func testMethodSpecificRequirementsAndZeroPaymentFollowPortalRules() {
        var payment = InvoiceDraftPayment(mode: .record)
        payment.amount = "0"
        XCTAssertNil(payment.validationIssue(subtotal: 20))
        payment.amount = "10"
        XCTAssertEqual(payment.validationIssue(subtotal: 20), "invoicePayment.methodRequired")
        payment.method = .check
        XCTAssertEqual(payment.validationIssue(subtotal: 20), "invoicePayment.bankRequired")
        payment.bankAccount = .init(id: 1, name: "Fixture Bank", displayName: nil, type: "BANK")
        XCTAssertEqual(payment.validationIssue(subtotal: 20), "invoicePayment.checkRequired")
        payment.checkNumber = "TEST-CHECK-1"
        XCTAssertNil(payment.validationIssue(subtotal: 20))
        payment.method = .cash
        payment.bankAccount = nil
        payment.checkNumber = ""
        XCTAssertNil(payment.validationIssue(subtotal: 20))
    }

    func testDraftAndBankReferencesSurviveReopenAndInvalidCatalogRollsBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let account = InvoiceBankAccount(id: 1, name: "Fixture Bank", displayName: "Test Bank", type: "BANK")
        try await store.saveInvoiceBankAccounts([account])
        do {
            try await store.saveInvoiceBankAccounts([.init(id: 2, name: "Expense", displayName: nil, type: "EXPENSE")])
            XCTFail("Non-bank accounts must not replace the catalog")
        } catch InvoiceStore.StoreError.invalidPageContents { }
        var content = InvoiceDraft.Content()
        content.payment = InvoiceDraftPayment(mode: .record)
        content.payment?.amount = "12.50"
        content.payment?.method = .zelle
        content.payment?.bankAccount = account
        content.payment?.externalReference = "TEST-REF"
        let saved = try await store.saveDraft(id: UUID(), content: content, expectedRevision: nil)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let draft = try await reopened.draft(id: saved.id)
        let accounts = try await reopened.invoiceBankAccounts()
        XCTAssertEqual(draft?.content.payment, content.payment)
        XCTAssertEqual(accounts, [account])
        let other = try await InvoiceStore.open(directory: directory, userID: "other-user", companyID: "company")
        let otherAccounts = try await other.invoiceBankAccounts()
        XCTAssertTrue(otherAccounts.isEmpty)
    }

    func testDefaultsApplyToNewAndLegacyDraftsAndPreserveSavedChoices() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let list = InvoiceDraftListModel(store: store, defaultPaymentRegion: "NY",
            financialPermission: { $0 == .recordPayment }, isAuthorized: { true })
        let new = list.editor()
        XCTAssertEqual(new.content.payment?.mode, .record)
        XCTAssertEqual(new.content.payment?.method, .cash)
        XCTAssertEqual(new.content.paymentRegion, "NY")
        XCTAssertFalse(new.hasChanges)

        let legacy = try await store.saveDraft(id: UUID(), content: InvoiceDraft.Content(), expectedRevision: nil)
        let restored = list.editor(draftID: legacy.id)
        await restored.load()
        XCTAssertEqual(restored.content.payment?.mode, .record)
        XCTAssertEqual(restored.content.payment?.method, .cash)
        XCTAssertEqual(restored.content.paymentRegion, "NY")
        XCTAssertFalse(restored.hasChanges)

        restored.setPaymentMethod(.check)
        restored.content.payment?.amount = "12,50"
        XCTAssertEqual(restored.content.payment?.totals(subtotal: 20)?.payment, 12.5)
        restored.setPaymentMode(.skip)
        restored.content.paymentRegion = "RD"
        await restored.save()
        let reopened = list.editor(draftID: legacy.id)
        await reopened.load()
        XCTAssertEqual(reopened.content.payment?.mode, .skip)
        XCTAssertEqual(reopened.content.payment?.method, .check)
        XCTAssertEqual(reopened.content.payment?.amount, "12,50")
        XCTAssertEqual(reopened.content.paymentRegion, "RD")
    }

    func testPermissionsSeparatePaymentRecordingAndDiscounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let denied = InvoiceDraftEditorModel(store: store, isAuthorized: { true })
        denied.setPaymentMode(.record)
        XCTAssertEqual(denied.content.payment?.mode, .skip)
        XCTAssertNil(denied.content.payment?.method)
        denied.setPaymentMode(.skip)
        XCTAssertEqual(denied.content.payment?.mode, .skip)
        let model = InvoiceDraftEditorModel(store: store, financialPermission: { permission in
            switch permission { case .recordPayment: true; default: false }
        }, isAuthorized: { true })
        model.content.items = [.init(name: "Box", unitPrice: "20")]
        model.setPaymentMode(.record)
        model.content.payment?.amount = "5"
        model.content.payment?.discount = "2"
        model.setPaymentMethod(.cash)
        XCTAssertEqual(model.validationIssue(for: .payment), "invoicePayment.discountPermissionRequired")
        model.content.payment?.discount = "0"
        XCTAssertEqual(model.paymentTotals?.balance, 15)
    }
}
