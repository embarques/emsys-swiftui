import XCTest
@testable import EMSYS

@MainActor
final class InvoiceAssignmentTests: XCTestCase {
    func testLegacyEmployeeWithoutActiveFlagIsExcludedWithoutRejectingEntireList() throws {
        let employees = try JSONDecoder().decode([InvoicePickupEmployee].self, from: Data(
            #"[{"id":1,"name":"Inactive legacy employee"},{"id":2,"name":"Active employee","active":true}]"#.utf8))
        XCTAssertFalse(employees[0].isEligible)
        XCTAssertEqual(employees.filter(\.isEligible).map(\.id), [2])
    }

    func testDraftKeepsTheDatedRouteAndReusableCrewIdentitiesSeparateAfterReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let editor = InvoiceDraftEditorModel(store: store, client: try makeClient(), canViewAssignments: { _ in true }, isAuthorized: { true })
        let route = route(1)
        editor.setPickupSource(.route)
        editor.selectPickupRoute(route)
        let saved = try await store.saveDraft(id: UUID(), content: editor.content, expectedRevision: nil)
        let reopened = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let restored = try await reopened.draft(id: saved.id)
        XCTAssertEqual(restored?.content.pickupRoute?.id, route.id)
        XCTAssertEqual(restored?.content.pickupRoute?.route?.id, route.route?.id)
        XCTAssertNotEqual(restored?.content.pickupRoute?.id, restored?.content.pickupRoute?.route?.id)
        editor.setPickupSource(.office)
        XCTAssertNil(editor.content.pickupRoute)
        editor.selectPickupEmployee(employee(2))
        XCTAssertEqual(editor.content.pickupEmployee?.id, 2)
        editor.setPickupSource(.warehouse)
        XCTAssertNil(editor.content.pickupEmployee)
        editor.setPickupSource(nil)
        XCTAssertNil(editor.content.pickupSource)
    }

    func testEmployeeSourceRulesAndQueryFallbackMatchThePortal() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let warehouse = employee(1, name: "Warehouse Person", department: "warehouse", branchID: 10)
        let office = employee(2, name: "Office Person", branchID: 20)
        try await store.savePickupEmployees([warehouse, office])
        try await store.savePickupBranches([
            InvoicePickupBranch(id: 10, name: "Warehouse", code: "NY", type: "warehouse"),
            InvoicePickupBranch(id: 20, name: "Office", code: "NY", type: "office")
        ])
        let model = InvoiceAssignmentPickerModel(source: .warehouse, client: try makeClient(), store: store,
            isAuthorized: { true }, canViewBranches: { true })
        await model.load(online: false)
        XCTAssertEqual(model.matchingEmployees.map(\.id), [1])
        model.query = "Office"
        XCTAssertEqual(model.matchingEmployees.map(\.id), [2], "The portal falls back within the search result when no preferred role matches")
        let deliveryEmployee = InvoicePickupEmployee(id: 3, name: "Delivery", title: nil, department: nil,
            active: true, branch: .init(id: 30, name: "Delivery", code: " rd ", type: nil))
        XCTAssertFalse(deliveryEmployee.isEligible)
        let inactive = InvoicePickupEmployee(id: 4, name: "Inactive", title: nil, department: nil, active: false, branch: nil)
        XCTAssertFalse(inactive.isEligible)
        let officeModel = InvoiceAssignmentPickerModel(source: .office, client: try makeClient(), store: store,
            isAuthorized: { true }, canViewBranches: { true })
        await officeModel.load(online: false)
        XCTAssertEqual(officeModel.matchingEmployees.map(\.id), [2])
    }

    func testLaterDownloadFailurePreservesCachedAssignmentsAndUsesTheActualRouteEndpoint() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let previous = route(99)
        try await store.savePickupRoutes([previous])
        AssignmentProtocol.responses = [(200, try envelope((1...40).map { route($0) })), (500, Data())]
        AssignmentProtocol.requests = []
        let model = InvoiceAssignmentPickerModel(source: .route, client: try makeClient(), store: store,
            isAuthorized: { true }, canViewBranches: { false })
        await model.load(online: true)
        XCTAssertEqual(model.routes, [previous])
        XCTAssertEqual(model.issue, "pickupAssignment.loadError")
        let saved = try await store.pickupRoutes()
        XCTAssertEqual(saved, [previous])
        let request = try XCTUnwrap(AssignmentProtocol.requests.last)
        XCTAssertEqual(request.url?.path, "/v1/vehicle-routes")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "field" })?.value, "routeType")
        XCTAssertEqual(query?.first(where: { $0.name == "value" })?.value, "pickup")
        XCTAssertEqual(query?.first(where: { $0.name == "page" })?.value, "2")
    }

    func testMixedAssignmentsAndInvalidCatalogCannotOverwriteSavedWork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        let selected = route(1)
        try await store.savePickupRoutes([selected])
        do {
            try await store.savePickupRoutes([selected, selected])
            XCTFail("Duplicate route identities must be rejected atomically")
        } catch InvoiceStore.StoreError.invalidPageContents { }
        let cached = try await store.pickupRoutes()
        XCTAssertEqual(cached, [selected])
        var content = InvoiceDraft.Content()
        content.pickupSource = .route
        content.pickupRoute = selected
        let saved = try await store.saveDraft(id: UUID(), content: content, expectedRevision: nil)
        content.pickupEmployee = employee(1)
        do {
            _ = try await store.saveDraft(id: saved.id, content: content, expectedRevision: saved.revision)
            XCTFail("Route and employee assignments cannot silently coexist")
        } catch InvoiceStore.StoreError.invalidDraft { }
        let restored = try await store.draft(id: saved.id)
        XCTAssertEqual(restored?.content, saved.content)
    }

    func testCachedAssignmentsRemainScopedAndRevocationStopsSelection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        try await store.savePickupRoutes([route(1)])
        for (user, company, environment) in [
            ("other", "company", APIConfiguration.defaultRoot),
            ("user", "other", APIConfiguration.defaultRoot),
            ("user", "company", "https://other.example.test/v1")
        ] {
            let other = try await InvoiceStore.open(directory: directory, userID: user, companyID: company, apiEnvironment: environment)
            let saved = try await other.pickupRoutes()
            XCTAssertNil(saved)
        }
        let editor = InvoiceDraftEditorModel(store: store, client: try makeClient(), canViewAssignments: { _ in false }, isAuthorized: { true })
        editor.setPickupSource(.route)
        XCTAssertFalse(editor.canChooseAssignment)
        XCTAssertNil(editor.assignmentPicker())
        editor.selectPickupRoute(route(1))
        XCTAssertNil(editor.content.pickupRoute)
    }

    func testEmployeeDownloadDoesNotRequireBranchPermissionOrStoreFinancialFields() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await InvoiceStore.open(directory: directory, userID: "user", companyID: "company")
        AssignmentProtocol.responses = [(200, Data(#"{"success":true,"data":[{"id":1,"name":"Office Person","department":"office","active":true,"loanAmountOwed":1234,"phones":[{"number":"5550100"}]}]}"#.utf8))]
        AssignmentProtocol.requests = []
        let model = InvoiceAssignmentPickerModel(source: .office, client: try makeClient(), store: store,
            isAuthorized: { true }, canViewBranches: { false })
        await model.load(online: true)
        XCTAssertEqual(model.matchingEmployees.map(\.id), [1])
        XCTAssertNil(model.issue)
        XCTAssertEqual(AssignmentProtocol.requests.count, 1)
        XCTAssertEqual(AssignmentProtocol.requests.first?.url?.path, "/v1/employees")
        let saved = try await store.pickupEmployees()
        XCTAssertEqual(saved?.map(\.id), [1])
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(saved?.first))) as? [String: Any]
        XCTAssertNil(encoded?["loanAmountOwed"])
        XCTAssertNil(encoded?["phones"])
    }

    private func route(_ index: Int) -> InvoicePickupRoute {
        InvoicePickupRoute(id: String(format: "%024x", index), name: "2026-10-25 Pickup \(index)", date: "2026-10-25T00:00:00Z",
            dayOfWeek: nil, branch: .init(id: 10, name: "Test", code: "NY", type: nil),
            route: .init(id: "000000000000000000001000", name: "Reusable Crew"), routeType: "pickup", type: nil)
    }

    private func employee(_ id: UInt16, name: String = "Office Person", department: String = "office", branchID: UInt16 = 20) -> InvoicePickupEmployee {
        InvoicePickupEmployee(id: id, name: name, title: nil, department: department, active: true,
            branch: .init(id: branchID, name: "Test Branch", code: "NY", type: nil))
    }

    private func envelope<Item: Encodable>(_ items: [Item]) throws -> Data {
        return try JSONEncoder().encode(AssignmentEnvelope(data: items))
    }

    private func makeClient() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssignmentProtocol.self]
        let contextID = UUID()
        return try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.test/v1")), session: URLSession(configuration: configuration)) { _ in
            APICredentials(sessionID: contextID, userID: "user", companyID: "company", idToken: "test-token")
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "assignment-tests-\(UUID())", directoryHint: .isDirectory)
    }
}

private final class AssignmentProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        guard !Self.responses.isEmpty, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: Self.responses[0].0, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (_, data) = Self.responses.removeFirst()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private struct AssignmentEnvelope<Value: Encodable>: Encodable {
    let success = true
    let data: [Value]
}
