import Foundation

@MainActor
struct IncomeRepository {
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
        struct Sort: Encodable {
            let field: String
            let direction = "desc"
        }
        let page: Int
        let limit: Int
        let `operator` = "and"
        let sort = [Sort(field: "date"), Sort(field: "id")]
        let filters: [Filter]
    }

    enum UploadError: Error { case attentionRequired }
    let client: APIClient
    let store: IncomeStore

    /// Returns today's local date using the last known branch timezone.
    func localBusinessDay(branchID: UInt16) async throws -> InvoiceDate {
        // Fall back to the device calendar until the first branch snapshot is downloaded.
        let identifier = try await store.knownTimeZone(branchID: branchID)
        var calendar = InvoiceDate.localCalendar
        if let identifier, let timeZone = TimeZone(identifier: identifier) {
            calendar.timeZone = timeZone
        }
        return InvoiceDate(date: .now, calendar: calendar)
    }

    /// Reads the selected period and outstanding transactions for its branch.
    func localActivity(branchID: UInt16, day: InvoiceDate) async throws -> (period: IncomePeriod?, pending: [PendingIncomeJournal]) {
        try await store.activity(branchID: branchID, day: day)
    }

    /// Refreshes the requested day or uses the server's current business day.
    func refreshActivity(branchID: UInt16, selectedDay: InvoiceDate?,
                         mayCreate: () -> Bool) async throws -> (day: InvoiceDate, accountsDownloaded: Bool) {
        // Interpret the server's closeout date inside the repository.
        let closeout = try await context(branchID: branchID)
        guard let today = InvoiceDate(apiValue: closeout.today) else {
            throw APIClientError.invalidResponse
        }

        let day = selectedDay ?? today
        let accountsDownloaded = try await download(branchID: branchID, day: day,
            context: closeout, canCreate: mayCreate())
        return (day, accountsDownloaded)
    }

    /// Validates and persists an immutable journal request for retry.
    func enqueue(_ draft: IncomeJournalDraft, for period: IncomePeriod) async throws -> PendingIncomeJournal {
        // Bind the request to the original closeout and freeze the request bytes once.
        guard let statement = period.statement, let currency = period.currency else {
            throw APIClientError.invalidResponse
        }
        let id = UUID()
        guard let request = draft.request(id: id, statement: statement, accounts: period.accounts) else {
            throw APIClientError.invalidResponse
        }
        let body = try JSONEncoder().encode(request)
        let operation = PendingIncomeJournal(id: id, branchID: period.branchID, day: period.day,
            timeZone: period.timeZone, currency: currency, request: request, body: body)

        // Ingresos presents the journal as pending only after the outbox write commits.
        try await store.enqueue(operation)
        return operation
    }

    /// Loads the server's closeout dates and open statement for the branch.
    private func context(branchID: UInt16) async throws -> CloseoutContext {
        try await client.get("income-statements/context",
            queryItems: [.init(name: "branchId", value: String(branchID))], as: CloseoutContext.self)
    }

    /// Refreshes a business day and keeps its journal and account data in the local period.
    private func download(branchID: UInt16, day: InvoiceDate, context: CloseoutContext, canCreate: Bool) async throws -> Bool {
        let revision = try await store.revision()
        let cached = try await store.period(branchID: branchID, day: day)
        let statement: InvoiceIncomeStatement?
        // Today's statement is authoritative in the closeout context.
        if day.apiValue == context.today {
            if let current = context.current {
                statement = current
            } else if let latest = context.latest, latest.matches(branchID: branchID, day: day) {
                statement = latest
            } else {
                statement = nil
            }
        } else {
            let rows = try await client.post("income-statements/search",
                body: InvoiceIncomeStatementQuery(branchID: branchID, day: day), as: [InvoiceIncomeStatement].self)
            statement = rows.first
        }
        // An absent statement has no journal page. Refuse one from a different branch or day.
        let entries: [IncomeJournal]
        if let statement {
            guard statement.matches(branchID: branchID, day: day) else {
                throw APIClientError.invalidResponse
            }
            entries = try await journals(statementID: statement.id)
        } else {
            entries = []
        }
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
                // Keep cached accounts only when the failure permits offline restoration.
                if !AuthenticationSession.permitsOfflineRestoration(error) {
                    accounts = []
                }
            }
        }
        // A delayed refresh must not supersede a receipt committed after it started.
        try Task.checkCancellation()
        let period = IncomePeriod(branchID: branchID, day: day, statement: statement, journals: entries,
            accounts: accounts, timeZone: context.serverTimezone, currentStatementID: context.current?.id)
        _ = try await store.save(period, ifUnchangedSince: revision)
        return accountsDownloaded
    }

    /// Downloads active sales and expenses without repeating or mixing statement rows.
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
            // Pagination must never include records from other closeouts or repeat an ID.
            guard rows.count <= 40 else {
                throw APIClientError.invalidResponse
            }
            for row in rows {
                guard row.incomeStatement?.id == statementID,
                      InvoiceWriteDocument.isObjectID(row.id), seen.insert(row.id).inserted else {
                    throw APIClientError.invalidResponse
                }
            }
            all.append(contentsOf: rows)
            if rows.count < 40 {
                return all.filter(\.isActive)
            }
        }
        throw APIClientError.invalidResponse
    }

    /// Downloads eligible chart accounts for this branch across all result pages.
    private func downloadAccounts(branchID: UInt16) async throws -> [IncomeAccount] {
        var all: [IncomeAccount] = []
        var seen = Set<UInt32>()
        for page in 1...100 {
            let rows = try await client.get("chart-accounts", queryItems: [
                .init(name: "page", value: String(page)), .init(name: "limit", value: "40"),
                .init(name: "sort", value: "id:asc")
            ], as: [IncomeAccount].self)
            // Validate the complete response before filtering to branch-specific accounts.
            guard rows.count <= 40 else {
                throw APIClientError.invalidResponse
            }
            for row in rows {
                guard row.id > 0, seen.insert(row.id).inserted else {
                    throw APIClientError.invalidResponse
                }
            }
            all.append(contentsOf: rows)
            if rows.count < 40 {
                return all.filter { $0.belongsToBranch(branchID) }
            }
        }
        throw APIClientError.invalidResponse
    }

    /// Sends frozen outbox requests and preserves entries that need operator review.
    func upload(branchID: UInt16, isAuthorized: () -> Bool) async throws {
        let pending = try await store.outbox()
        guard !pending.isEmpty else {
            return
        }
        var needsReview = pending.contains(where: \.requiresReview)
        for operation in pending where !operation.requiresReview {
            try Task.checkCancellation()
            guard isAuthorized() else {
                throw APIClientError.sessionChanged
            }
            // An entry must stay bound to its original branch and closeout.
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
                // Use the original bytes so a network retry keeps the same mutation identity.
                guard isAuthorized() else {
                    throw APIClientError.sessionChanged
                }
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
        if needsReview {
            throw UploadError.attentionRequired
        }
    }
}
