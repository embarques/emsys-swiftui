import Foundation

@MainActor
struct IncomeJournalService {
    struct CloseoutContext: Decodable {
        let today: String
        let serverTimezone: String
        let current: InvoiceIncomeStatement?
        let latest: InvoiceIncomeStatement?

        func matches(_ operation: PendingIncomeJournal) -> Bool {
            today == operation.day.apiValue && serverTimezone == operation.timeZone
                && current?.id == operation.request.entry.incomeStatementId
                && current?.branch?.id == operation.branchID && current?.currency == operation.currency
        }
    }

    private struct JournalSearch: Encodable {
        struct Filter: Encodable {
            let field: String
            let `operator`: String
            let value: Value
        }
        enum Value: Encodable {
            case id(UInt32), kinds([String])
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .id(let id): try container.encode(id)
                case .kinds(let kinds): try container.encode(kinds)
                }
            }
        }
        struct Sort: Encodable { let field: String; let direction = "desc" }
        let page: Int
        let limit: Int
        let `operator` = "and"
        let sort = [Sort(field: "date"), Sort(field: "id")]
        let filters: [Filter]
    }

    enum UploadError: Error { case attentionRequired }
    let client: APIClient
    let store: IncomeStore

    func context(branchID: UInt16) async throws -> CloseoutContext {
        try await client.get("income-statements/context",
            queryItems: [.init(name: "branchId", value: String(branchID))], as: CloseoutContext.self)
    }

    func download(branchID: UInt16, day: InvoiceDate, context: CloseoutContext, canCreate: Bool) async throws -> Bool {
        let revision = try await store.revision()
        let cached = try await store.period(branchID: branchID, day: day)
        let statement: InvoiceIncomeStatement?
        if day.apiValue == context.today {
            statement = context.current ?? context.latest.flatMap { $0.matches(branchID: branchID, day: day) ? $0 : nil }
        } else {
            let rows = try await client.post("income-statements/search",
                body: InvoiceIncomeStatementQuery(branchID: branchID, day: day), as: [InvoiceIncomeStatement].self)
            statement = rows.first
        }
        if let statement, !statement.matches(branchID: branchID, day: day) { throw APIClientError.invalidResponse }
        let journals = if let statement { try await journals(statementID: statement.id) } else { [IncomeJournal]() }
        var accounts = cached?.accounts ?? []
        var accountsDownloaded = true
        if canCreate, statement?.id == context.current?.id, statement != nil {
            do {
                accounts = try await downloadAccounts(branchID: branchID)
            } catch is CancellationError {
                throw CancellationError()
            } catch APIClientError.sessionChanged {
                throw APIClientError.sessionChanged
            } catch {
                accountsDownloaded = false
                if !AuthenticationSession.permitsOfflineRestoration(error) { accounts = [] }
            }
        }
        try Task.checkCancellation()
        let period = IncomePeriod(branchID: branchID, day: day, statement: statement, journals: journals,
            accounts: accounts, timeZone: context.serverTimezone, currentStatementID: context.current?.id)
        _ = try await store.save(period, ifUnchangedSince: revision)
        return accountsDownloaded
    }

    private func journals(statementID: UInt32) async throws -> [IncomeJournal] {
        let filters: [JournalSearch.Filter] = [
            .init(field: "incomeStatement.id", operator: "eq", value: .id(statementID)),
            .init(field: "transactionType", operator: "in", value: .kinds(IncomeJournalKind.allCases.map(\.rawValue)))
        ]
        var all: [IncomeJournal] = []
        var seen = Set<String>()
        for page in 1...100 {
            let rows = try await client.post("journals/search",
                body: JournalSearch(page: page, limit: 40, filters: filters), as: [IncomeJournal].self)
            guard rows.count <= 40, rows.allSatisfy({
                $0.incomeStatement?.id == statementID && InvoiceWriteDocument.isObjectID($0.id) && seen.insert($0.id).inserted
            }) else { throw APIClientError.invalidResponse }
            all.append(contentsOf: rows)
            if rows.count < 40 { return all.filter(\.isActive) }
        }
        throw APIClientError.invalidResponse
    }

    private func downloadAccounts(branchID: UInt16) async throws -> [IncomeAccount] {
        var all: [IncomeAccount] = []
        var seen = Set<UInt32>()
        for page in 1...100 {
            let rows = try await client.get("chart-accounts", queryItems: [
                .init(name: "page", value: String(page)), .init(name: "limit", value: "40"),
                .init(name: "sort", value: "id:asc")
            ], as: [IncomeAccount].self)
            guard rows.count <= 40, rows.allSatisfy({ $0.id > 0 && seen.insert($0.id).inserted }) else {
                throw APIClientError.invalidResponse
            }
            all.append(contentsOf: rows)
            if rows.count < 40 { return all.filter { $0.belongsToBranch(branchID) } }
        }
        throw APIClientError.invalidResponse
    }

    func upload(branchID: UInt16, isAuthorized: () -> Bool) async throws {
        let pending = try await store.outbox()
        guard !pending.isEmpty else { return }
        var needsReview = pending.contains(where: \.requiresReview)
        for operation in pending where !operation.requiresReview {
            try Task.checkCancellation()
            guard isAuthorized() else { throw APIClientError.sessionChanged }
            guard operation.branchID == branchID else {
                try await store.flagForReview(operation, reason: "income.periodChanged")
                needsReview = true
                continue
            }
            let closeout = try await context(branchID: branchID)
            guard closeout.matches(operation) else {
                try await store.flagForReview(operation, reason: "income.periodChanged")
                needsReview = true
                continue
            }
            do {
                guard isAuthorized() else { throw APIClientError.sessionChanged }
                let receipt = try await client.post("journals/sync", encodedBody: operation.body,
                    capturesServerFailure: true, as: IncomeJournal.self)
                try Task.checkCancellation()
                try await store.confirm(operation, receipt: receipt)
            } catch let failure as APIServerFailure where [400, 409, 422].contains(failure.status) {
                try await store.flagForReview(operation, reason: failure.code == "CLOSEOUT_REQUIRED"
                    ? "income.periodChanged" : "income.rejected")
                needsReview = true
            } catch IncomeStore.StoreError.invalidReceipt {
                try await store.flagForReview(operation, reason: "income.receiptMismatch")
                needsReview = true
            }
        }
        if needsReview { throw UploadError.attentionRequired }
    }
}
