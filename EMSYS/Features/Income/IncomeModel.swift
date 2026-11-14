import Foundation
import Observation

@MainActor
@Observable
final class IncomeModel {
    private(set) var period: IncomePeriod?
    private(set) var pending: [PendingIncomeJournal] = []
    private(set) var day = InvoiceDate(date: .now)
    private(set) var isLoading = false
    private(set) var issue: String?
    private(set) var isShowingDownloaded = false
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private let service: IncomeJournalService
    @ObservationIgnored private let branchID: UInt16
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let mayCreate: () -> Bool

    init(service: IncomeJournalService, branchID: UInt16, isAuthorized: @escaping () -> Bool, mayCreate: @escaping () -> Bool) {
        self.service = service
        self.branchID = branchID
        self.isAuthorized = isAuthorized
        self.mayCreate = mayCreate
    }

    var canCreate: Bool { isAuthorized() && mayCreate() && period?.isCurrent == true && !accounts.isEmpty }
    var accounts: [IncomeAccount] { period?.accounts ?? [] }
    var currency: String? { period?.currency }
    var journals: [IncomeJournal] { period?.journals.filter(\.isActive) ?? [] }

    func total(_ kind: IncomeJournalKind) -> Decimal {
        journals.lazy.filter { $0.transactionType == kind }.reduce(0) { $0 + $1.amount }
    }

    func load(selectedDay: InvoiceDate?, online: Bool) async {
        let id = UUID()
        loadID = id
        isLoading = true
        issue = nil
        defer { if loadID == id { isLoading = false } }
        guard isAuthorized() else { return }
        do {
            let zone = try await service.store.knownTimeZone(branchID: branchID).flatMap(TimeZone.init(identifier:))
            var calendar = InvoiceDate.localCalendar
            if let zone { calendar.timeZone = zone }
            let cachedDay = selectedDay ?? InvoiceDate(date: .now, calendar: calendar)
            try await showLocal(day: cachedDay, id: id)
            guard online, loadID == id, isAuthorized(), !Task.isCancelled else { return }
            let context = try await service.context(branchID: branchID)
            guard let today = InvoiceDate(apiValue: context.today) else { throw APIClientError.invalidResponse }
            let requestedDay = selectedDay ?? today
            let accountsDownloaded = try await service.download(branchID: branchID, day: requestedDay,
                context: context, canCreate: mayCreate())
            try await showLocal(day: requestedDay, id: id)
            if loadID == id, isAuthorized(), !Task.isCancelled {
                isShowingDownloaded = false
                if !accountsDownloaded { issue = "income.accountsError" }
            }
        } catch {
            guard loadID == id, isAuthorized(), !Task.isCancelled else { return }
            if case APIClientError.httpStatus(let status) = error, status == 401 || status == 403 {
                period = nil
                pending = []
            }
            issue = "income.loadError"
        }
    }

    private func showLocal(day: InvoiceDate, id: UUID) async throws {
        let period = try await service.store.period(branchID: branchID, day: day)
        let pending = try await service.store.outbox().filter { $0.branchID == branchID }
        guard loadID == id, isAuthorized(), !Task.isCancelled else { return }
        self.day = day
        self.period = period
        self.pending = pending
        isShowingDownloaded = period != nil
    }

    func canSave(_ draft: IncomeJournalDraft) -> Bool {
        guard canCreate, let statement = period?.statement else { return false }
        return draft.request(id: UUID(), statement: statement, accounts: accounts) != nil
    }

    func save(_ draft: IncomeJournalDraft, for originalStatementID: UInt32) async throws {
        guard canCreate, let period, let statement = period.statement, statement.id == originalStatementID,
              let currency = period.currency else { throw APIClientError.invalidResponse }
        let id = UUID()
        guard let request = draft.request(id: id, statement: statement, accounts: period.accounts) else {
            throw APIClientError.invalidResponse
        }
        let body = try JSONEncoder().encode(request)
        let operation = PendingIncomeJournal(id: id, branchID: branchID, day: period.day, timeZone: period.timeZone,
            currency: currency, request: request, body: body)
        try await service.store.enqueue(operation)
        if isAuthorized(), day == period.day { pending.append(operation) }
    }
}
