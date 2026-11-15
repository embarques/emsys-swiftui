import Foundation
import XCTest
#if os(iOS)
import SwiftUI
import UIKit
#endif
@testable import EMSYS

@MainActor
final class IncomeJournalTests: XCTestCase {
    func testSaleAndExpenseEncodeTheirOwnFundingReference() throws {
        let accounts = try accounts()
        let statement = try statement()
        var sale = IncomeJournalDraft(kind: .sale)
        sale.amount = "150,25"
        sale.description = "Venta de cajas"
        sale.method = .deposit
        sale.accountID = 4
        XCTAssertNil(sale.request(id: UUID(), statement: statement, accounts: accounts))
        sale.fundingID = 7
        let income = try XCTUnwrap(sale.request(id: UUID(), statement: statement, accounts: accounts))
        XCTAssertEqual(income.entry.amount, Decimal(string: "150.25"))
        XCTAssertEqual(income.entry.transactionType, .sale)
        XCTAssertEqual(income.entry.paymentAccount?.id, 7)
        XCTAssertNil(income.entry.sourceAccount)

        var expense = IncomeJournalDraft(kind: .expense)
        expense.amount = "55"
        expense.accountID = 5
        expense.method = .check
        expense.fundingID = 7
        XCTAssertNil(expense.request(id: UUID(), statement: statement, accounts: accounts))
        expense.paymentReference = "00042"
        let outgoing = try XCTUnwrap(expense.request(id: UUID(), statement: statement, accounts: accounts))
        XCTAssertEqual(outgoing.entry.transactionType, .expense)
        XCTAssertEqual(outgoing.entry.sourceAccount?.id, 7)
        XCTAssertEqual(outgoing.entry.paymentReference, "00042")
        XCTAssertNil(outgoing.entry.paymentAccount)
        expense.amount = "55.001"
        XCTAssertNil(expense.decimalAmount)
    }

    func testOfflineEntrySurvivesReopenAndConfirmationUpdatesPostedTotalsOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await IncomeStore.open(directory: directory, userID: "fixture", companyID: "fixture")
        let period = try period()
        let revision = try await store.revision()
        let stored = try await store.save(period, ifUnchangedSince: revision)
        XCTAssertTrue(stored)

        let id = UUID()
        var draft = IncomeJournalDraft(kind: .sale)
        draft.amount = "150"
        draft.accountID = 4
        let request = try XCTUnwrap(draft.request(id: id, statement: statement(), accounts: accounts()))
        let operation = PendingIncomeJournal(id: id, branchID: period.branchID, day: period.day,
            timeZone: period.timeZone, currency: "USD", request: request, body: try JSONEncoder().encode(request))
        try await store.enqueue(operation)

        let reopened = try await IncomeStore.open(directory: directory, userID: "fixture", companyID: "fixture")
        let savedOutbox = try await reopened.outbox()
        XCTAssertEqual(savedOutbox.first?.body, operation.body)
        let unposted = try await reopened.period(branchID: period.branchID, day: period.day)
        XCTAssertEqual(unposted?.journals.count, 0)
        let staleRevision = try await reopened.revision()

        let wrongReceipt = try journal(statementID: 99)
        do {
            try await reopened.confirm(operation, receipt: wrongReceipt)
            XCTFail("A receipt from another closeout cannot confirm the queue entry")
        } catch IncomeStore.StoreError.invalidReceipt { }

        let receipt = try journal(statementID: 7)
        try await reopened.confirm(operation, receipt: receipt)
        try await reopened.confirm(operation, receipt: receipt)
        let confirmed = try await reopened.period(branchID: period.branchID, day: period.day)
        XCTAssertEqual(confirmed?.journals.map(\.amount), [150])
        let remaining = try await reopened.outbox()
        XCTAssertTrue(remaining.isEmpty)
        let staleSaved = try await reopened.save(period, ifUnchangedSince: staleRevision)
        XCTAssertFalse(staleSaved)

        let other = try await IncomeStore.open(directory: directory, userID: "fixture", companyID: "another-tenant")
        let otherPeriod = try await other.period(branchID: period.branchID, day: period.day)
        XCTAssertNil(otherPeriod)
    }

    func testCloseoutMustMatchOriginalDayAndStatement() throws {
        let period = try period()
        let id = UUID()
        var draft = IncomeJournalDraft(kind: .sale)
        draft.amount = "150"
        draft.accountID = 4
        let request = try XCTUnwrap(draft.request(id: id, statement: statement(), accounts: accounts()))
        let operation = PendingIncomeJournal(id: id, branchID: period.branchID, day: period.day,
            timeZone: period.timeZone, currency: "USD", request: request, body: try JSONEncoder().encode(request))
        let current = IncomeJournalService.CloseoutContext(today: period.day.apiValue, serverTimezone: period.timeZone,
            current: period.statement, latest: period.statement)
        XCTAssertTrue(current.matches(operation))
        let closed = IncomeJournalService.CloseoutContext(today: period.day.apiValue, serverTimezone: period.timeZone,
            current: nil, latest: period.statement)
        XCTAssertFalse(closed.matches(operation))
        let next = IncomeJournalService.CloseoutContext(today: "2027-01-01", serverTimezone: period.timeZone,
            current: period.statement, latest: period.statement)
        XCTAssertFalse(next.matches(operation))
    }

    func testUploadPreflightsCloseoutAndRetriesExactBytesAfterLostResponse() async throws {
        let (service, directory, session) = try await fixture()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let period = try period()
        let revision = try await service.store.revision()
        _ = try await service.store.save(period, ifUnchangedSince: revision)
        let id = UUID()
        var draft = IncomeJournalDraft(kind: .sale)
        draft.amount = "150"
        draft.accountID = 4
        let request = try XCTUnwrap(draft.request(id: id, statement: statement(), accounts: accounts()))
        let operation = PendingIncomeJournal(id: id, branchID: period.branchID, day: period.day,
            timeZone: period.timeZone, currency: "USD", request: request, body: try JSONEncoder().encode(request))
        try await service.store.enqueue(operation)

        let context = try envelope(IncomeCloseoutFixture(today: period.day.apiValue, serverTimezone: period.timeZone,
            current: period.statement))
        let receipt = try envelope(journal(statementID: 7))
        IncomeProtocol.stub([.body(context), .connectionLost, .body(context), .body(receipt)])
        do {
            try await service.upload(branchID: 3, isAuthorized: { true })
            XCTFail("A lost response must leave the outbox outstanding")
        } catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        try await service.upload(branchID: 3, isAuthorized: { true })
        XCTAssertEqual(IncomeProtocol.requests().map(\.path), [
            "/v1/income-statements/context", "/v1/journals/sync",
            "/v1/income-statements/context", "/v1/journals/sync"
        ])
        let submitted = try IncomeProtocol.requests().filter { $0.path == "/v1/journals/sync" }.map { try XCTUnwrap($0.body) }
        XCTAssertEqual(submitted, [operation.body, operation.body])

        let secondID = UUID()
        let nextRequest = try XCTUnwrap(draft.request(id: secondID, statement: statement(), accounts: accounts()))
        let next = PendingIncomeJournal(id: secondID, branchID: period.branchID, day: period.day,
            timeZone: period.timeZone, currency: "USD", request: nextRequest, body: try JSONEncoder().encode(nextRequest))
        try await service.store.enqueue(next)
        let closed = try envelope(IncomeCloseoutFixture(today: "2026-11-15", serverTimezone: period.timeZone, current: nil))
        IncomeProtocol.stub([.body(closed)])
        do {
            try await service.upload(branchID: 3, isAuthorized: { true })
            XCTFail("A new business day requires review")
        } catch IncomeJournalService.UploadError.attentionRequired { }
        XCTAssertEqual(IncomeProtocol.requests().map(\.path), ["/v1/income-statements/context"])
        let outbox = try await service.store.outbox()
        XCTAssertEqual(outbox.first?.reviewReason, "income.periodChanged")
        XCTAssertEqual(outbox.first?.body, next.body)
    }

    #if os(iOS)
    func testNativeIncomeEntryFormsRenderAndFocusDecimalFieldOnPhone() async throws {
        let (service, directory, session) = try await fixture()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let day = InvoiceDate(date: .now, calendar: InvoiceDate.calendar)
        let today = InvoiceIncomeStatement(id: 7, businessDate: day.apiValue, date: nil, timezone: "GMT",
            automated: true, branch: .init(id: 3, name: nil, code: nil), currency: "USD", status: "open")
        let expense = try JSONDecoder().decode(IncomeJournal.self, from: Data("""
            {"id":"000000000000000000000456","transactionType":"EXPENSE","transactionAmount":55,
             "transactionStatus":"ACTIVE","currency":"USD","description":"Combustible","incomeStatement":{"id":7}}
            """.utf8))
        let period = IncomePeriod(branchID: 3, day: day, statement: today,
            journals: [try journal(statementID: 7), expense], accounts: try accounts(),
            timeZone: "GMT", currentStatementID: 7)
        let revision = try await service.store.revision()
        _ = try await service.store.save(period, ifUnchangedSince: revision)
        let model = IncomeModel(service: service, branchID: 3, isAuthorized: { true }, mayCreate: { true })
        await model.load(selectedDay: day, online: false)
        XCTAssertTrue(model.canCreate)
        XCTAssertEqual(model.total(.sale) - model.total(.expense), 95)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        defer { window.isHidden = true; previous?.makeKey() }
        let overview = UIHostingController(rootView: NavigationStack {
            IncomeOverviewView(model: model, mayCreate: true, selectedDay: .constant(nil), retry: {}, openEntry: { _, _ in })
                .navigationTitle("navigation.dailyIncome")
        }.environment(\.locale, Locale(identifier: "es-DO")))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = overview
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(400))
        try capture(window, name: "overview")
        for kind in IncomeJournalKind.allCases {
            let host = UIHostingController(rootView: IncomeEntryView(model: model, kind: kind, statementID: 7) { }
                .environment(\.locale, Locale(identifier: "es-DO")))
            window.overrideUserInterfaceStyle = kind == .sale ? .light : .dark
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(500))
            if UIDevice.current.userInterfaceIdiom == .phone {
                let field = try XCTUnwrap(focusedField(in: host.view))
                XCTAssertEqual(field.keyboardType, .decimalPad)
                field.insertText(kind == .sale ? "150" : "55")
            }
            try capture(window, name: kind.rawValue)
            window.endEditing(true)
        }
        let expenseDraft = IncomeJournalDraft(kind: .expense)
        let categories = model.accounts.filter(expenseDraft.categoryAllows)
        XCTAssertEqual(categories.map(\.id), [5])
        let category = UIHostingController(rootView: IncomeCategoryPicker(
            accounts: categories, kind: .expense, selectedID: 5, select: { _ in })
            .environment(\.locale, Locale(identifier: "es-DO")))
        window.rootViewController = category
        try await Task.sleep(for: .milliseconds(400))
        try capture(window, name: "categories")
    }

    private func capture(_ window: UIWindow, name: String) throws {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .phone ? "iphone" : "ipad"
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory
            .appending(path: "emsys-income-\(name)-\(device).png"))
    }

    private func focusedField(in view: UIView) -> UITextField? {
        if view.isFirstResponder, let field = view as? UITextField { return field }
        return view.subviews.lazy.compactMap { self.focusedField(in: $0) }.first
    }
    #endif

    private func fixture() async throws -> (IncomeJournalService, URL, URLSession) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = try await IncomeStore.open(directory: directory, userID: "fixture", companyID: "fixture")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IncomeProtocol.self]
        let session = URLSession(configuration: configuration)
        let context = UUID()
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.test/v1")), session: session) { _ in
            APICredentials(sessionID: context, userID: "fixture", companyID: "fixture", idToken: "fixture-token")
        }
        return (IncomeJournalService(client: client, store: store), directory, session)
    }

    private func envelope<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(IncomeEnvelope(data: value))
    }

    private func accounts() throws -> [IncomeAccount] {
        try JSONDecoder().decode([IncomeAccount].self, from: Data("""
            [{"id":4,"name":"SALES","type":"REVENUE"},{"id":5,"name":"FUEL","type":"EXPENSE"},
             {"id":7,"name":"BANK","type":"BANK"}]
            """.utf8))
    }

    private func statement() throws -> InvoiceIncomeStatement {
        try JSONDecoder().decode(InvoiceIncomeStatement.self, from: Data("""
            {"id":7,"businessDate":"2026-11-14","status":"open","currency":"USD","branch":{"id":3}}
            """.utf8))
    }

    private func period() throws -> IncomePeriod {
        let day = try XCTUnwrap(InvoiceDate(apiValue: "2026-11-14"))
        return try .init(branchID: 3, day: day, statement: statement(), journals: [],
                         accounts: accounts(), timeZone: "America/New_York", currentStatementID: 7)
    }

    private func journal(statementID: UInt32) throws -> IncomeJournal {
        try JSONDecoder().decode(IncomeJournal.self, from: Data("""
            {"id":"000000000000000000000123","transactionType":"SALES","transactionAmount":150,
             "transactionStatus":"ACTIVE","currency":"USD","incomeStatement":{"id":\(statementID)}}
            """.utf8))
    }
}


private nonisolated struct IncomeEnvelope<Value: Encodable>: Encodable {
    let success = true
    let data: Value
}

private nonisolated struct IncomeCloseoutFixture: Encodable {
    let today: String
    let serverTimezone: String
    let current: InvoiceIncomeStatement?
}

private final class IncomeProtocol: URLProtocol {
    enum Response { case body(Data), connectionLost }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var responses: [Response] = []
    private nonisolated(unsafe) static var captured: [(path: String, body: Data?)] = []

    static func stub(_ responses: [Response]) {
        lock.withLock {
            Self.responses = responses
            captured = []
        }
    }

    static func requests() -> [(path: String, body: Data?)] { lock.withLock { captured } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { return data }
                data.append(buffer, count: count)
            }
        }
        let response = Self.lock.withLock {
            Self.captured.append((url.path, body))
            return Self.responses.isEmpty ? nil : Self.responses.removeFirst()
        }
        guard case .body(let data) = response,
              let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
