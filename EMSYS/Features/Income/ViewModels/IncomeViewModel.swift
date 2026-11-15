import Foundation
import Observation

@MainActor
@Observable
final class IncomeViewModel {
    private(set) var period: IncomePeriod?
    private(set) var pending: [PendingIncomeJournal] = []
    private(set) var day = InvoiceDate(date: .now)
    private(set) var isLoading = false
    private(set) var issue: String?
    private(set) var isShowingDownloaded = false
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private let repository: IncomeRepository
    @ObservationIgnored private let branchID: UInt16
    @ObservationIgnored private let isAuthorized: () -> Bool
    @ObservationIgnored private let mayCreate: () -> Bool

    /// Creates the screen state for a single authenticated branch.
    init(repository: IncomeRepository, branchID: UInt16, isAuthorized: @escaping () -> Bool, mayCreate: @escaping () -> Bool) {
        self.repository = repository
        self.branchID = branchID
        self.isAuthorized = isAuthorized
        self.mayCreate = mayCreate
    }

    /// Indicates whether the screen has permission and a current period with accounts.
    var canCreate: Bool {
        isAuthorized() && mayCreate() && period?.isCurrent == true && !accounts.isEmpty
    }
    /// Provides the accounts downloaded with the selected period.
    var accounts: [IncomeAccount] { period?.accounts ?? [] }
    /// Provides the server currency for the selected closeout.
    var currency: String? { period?.currency }
    /// Exposes posted entries that are still active.
    var journals: [IncomeJournal] { period?.journals.filter(\.isActive) ?? [] }

    /// Adds the posted entries for one transaction direction.
    func total(_ kind: IncomeJournalKind) -> Decimal {
        period?.total(kind) ?? .zero
    }

    /// Loads cached activity first and refreshes the selected day if online.
    func load(selectedDay: InvoiceDate?, online: Bool) async {
        // Keep each refresh tied to the selected date and current session.
        let id = UUID()
        loadID = id
        isLoading = true
        issue = nil
        defer {
            if loadID == id {
                isLoading = false
            }
        }
        guard isAuthorized() else {
            return
        }
        do {
            // Use the branch calendar when the user has not selected a specific day.
            let cachedDay: InvoiceDate
            if let selectedDay {
                cachedDay = selectedDay
            } else {
                cachedDay = try await repository.localBusinessDay(branchID: branchID)
            }
            try await showLocal(day: cachedDay, id: id)

            // Stop before the network request when offline or superseded.
            guard online, loadID == id, isAuthorized(), !Task.isCancelled else {
                return
            }
            // Use the refreshed period only while this selection is still current.
            let downloaded = try await repository.refreshActivity(branchID: branchID,
                selectedDay: selectedDay, mayCreate: mayCreate)
            try await showLocal(day: downloaded.day, id: id)
            if loadID == id, isAuthorized(), !Task.isCancelled {
                isShowingDownloaded = false
                if !downloaded.accountsDownloaded {
                    issue = "income.accountsError"
                }
            }
        } catch {
            // Keep local data on ordinary refresh errors, and clear it after denial.
            guard loadID == id, isAuthorized(), !Task.isCancelled else {
                return
            }
            if case APIClientError.httpStatus(let status) = error, status == 401 || status == 403 {
                period = nil
                pending = []
            }
            issue = "income.loadError"
        }
    }

    /// Publishes the local snapshot when the requesting screen is still current.
    private func showLocal(day: InvoiceDate, id: UUID) async throws {
        let activity = try await repository.localActivity(branchID: branchID, day: day)

        // A selection or session change can occur while SQLite is being read.
        guard loadID == id, isAuthorized(), !Task.isCancelled else {
            return
        }
        self.day = day
        period = activity.period
        pending = activity.pending
        isShowingDownloaded = activity.period != nil
    }

    /// Checks the visible form before enabling its Save button.
    func canSave(_ draft: IncomeJournalDraft) -> Bool {
        // The current statement and accounts determine whether the amount can be posted.
        guard canCreate, let statement = period?.statement else {
            return false
        }
        return draft.request(id: UUID(), statement: statement, accounts: accounts) != nil
    }

    /// Queues the entry against the closeout that was open when the form appeared.
    func save(_ draft: IncomeJournalDraft, for originalStatementID: UInt32) async throws {
        // A form kept open across a closeout change cannot post against a different one.
        guard canCreate, let period, period.statement?.id == originalStatementID else {
            throw APIClientError.invalidResponse
        }
        let operation = try await repository.enqueue(draft, for: period)

        // Show the queued item only after the repository has durably saved it.
        if isAuthorized(), day == period.day {
            pending.append(operation)
        }
    }
}
