import Foundation

nonisolated enum IncomeJournalKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case sale = "SALES"
    case expense = "EXPENSE"

    var id: Self { self }
    var title: String { self == .sale ? "income.otherIncome" : "income.expenses" }
    var entryTitle: String { self == .sale ? "income.newIncome" : "income.newExpense" }
    var saveTitle: String { self == .sale ? "income.saveIncome" : "income.saveExpense" }
    var icon: String { self == .sale ? "shippingbox" : "arrow.up.right.circle" }

    func allowsFunding(_ method: IncomePaymentMethod) -> Bool {
        self == .expense || method != .creditCard
    }

    func requiresFunding(_ method: IncomePaymentMethod) -> Bool {
        if self == .expense { return method != .cash }
        return method == .deposit || method == .zelle || method == .debitCard || method == .wire
    }
}

nonisolated enum IncomePaymentMethod: String, CaseIterable, Identifiable, Sendable {
    case cash = "CASH", check = "CHECK", deposit = "DEPOSIT", zelle = "ZELLE"
    case creditCard = "CREDIT-CARD", debitCard = "DEBIT-CARD", wire = "WIRE"

    var id: Self { self }
    var title: String { "invoicePayment.method.\(rawValue)" }

    var lookupID: UInt16 {
        if let invoiceMethod = InvoiceDraftPayment.Method(rawValue: rawValue) { return invoiceMethod.lookupID }
        return self == .debitCard ? 6 : 7
    }

    var symbol: String {
        if let invoiceMethod = InvoiceDraftPayment.Method(rawValue: rawValue) { return invoiceMethod.symbol }
        return self == .debitCard ? "creditcard" : "arrow.left.arrow.right"
    }
}

nonisolated struct IncomeAccount: Codable, Identifiable, Sendable {
    let id: UInt32
    let name: String?
    let displayName: String?
    let type: String
    let nonPosting: Bool?
    let branch: AuthenticatedUser.Branch?
    let branchAccount: Bool?
    let parentAccount: Reference?

    struct Reference: Codable, Sendable {
        let id: UInt32
        let name: String
        let type: String?
    }

    var title: String { [displayName, name].compactMap { $0 }.first { !$0.isEmpty } ?? String(id) }
    var reference: Reference { .init(id: id, name: name ?? title, type: type) }

    func belongsToBranch(_ branchID: UInt16) -> Bool {
        branch?.id == nil ? branchAccount != true : branch?.id == branchID
    }

    func isFunding(for method: IncomePaymentMethod, in accounts: [Self]) -> Bool {
        guard nonPosting != true else { return false }
        guard method == .cash else { return type == "BANK" }
        guard type == "ASSET" else { return false }
        // The API only accepts cash on hand or a posting descendant of that account.
        if id == 1 { return true }
        var parent = parentAccount?.id
        for _ in 0..<32 {
            guard let parentID = parent else { return false }
            if parentID == 1 { return true }
            parent = accounts.first { $0.id == parentID }?.parentAccount?.id
        }
        return false
    }
}

nonisolated struct IncomeJournal: Codable, Identifiable, Sendable {
    struct Line: Codable, Sendable {
        let name: String?
        let type: String?
        let debit: Decimal?
        let credit: Decimal?
    }

    struct Statement: Codable, Sendable { let id: UInt32 }

    let id: String
    let transactionType: IncomeJournalKind
    let transactionAmount: Decimal
    let transactionStatus: String?
    let currency: String?
    let description: String?
    let accounts: [Line]?
    let incomeStatement: Statement?

    var isActive: Bool {
        transactionStatus == nil || transactionStatus == "" || transactionStatus == "ACTIVE"
    }

    var amount: Decimal {
        guard transactionType == .expense else { return transactionAmount }
        let expenses = accounts?.filter { $0.type == "EXPENSE" } ?? []
        return expenses.isEmpty ? transactionAmount : expenses.reduce(0) { $0 + ($1.debit ?? 0) }
    }

    var accountName: String? {
        accounts?.first { transactionType == .expense ? $0.type == "EXPENSE" : ($0.credit ?? 0) > 0 }?.name
    }
}

nonisolated struct IncomeJournalRequest: Codable, Sendable {
    struct Method: Codable, Sendable { let id: UInt16; let name: String }

    struct Entry: Codable, Sendable {
        let transactionType: IncomeJournalKind
        let amount: Decimal
        let description: String?
        let incomeStatementId: UInt32
        let account: IncomeAccount.Reference
        let paymentMethod: Method
        let paymentAccount: IncomeAccount.Reference?
        let sourceAccount: IncomeAccount.Reference?
        let paymentReference: String?
    }

    let requestId: String
    let entry: Entry
}

nonisolated struct IncomePeriod: Codable, Sendable {
    let branchID: UInt16
    let day: InvoiceDate
    let statement: InvoiceIncomeStatement?
    var journals: [IncomeJournal]
    var accounts: [IncomeAccount]

    let timeZone: String
    let currentStatementID: UInt32?

    var currency: String? { statement?.currency }

    var isCurrent: Bool {
        guard let zone = TimeZone(identifier: timeZone), let statement, statement.id == currentStatementID,
              statement.isOpen, currency?.count == 3 else { return false }
        var calendar = InvoiceDate.calendar
        calendar.timeZone = zone
        return day == InvoiceDate(date: .now, calendar: calendar)
    }
}

nonisolated struct PendingIncomeJournal: Codable, Identifiable, Sendable {
    let id: UUID
    let branchID: UInt16
    let day: InvoiceDate
    let timeZone: String
    let currency: String
    let request: IncomeJournalRequest
    let body: Data
    var reviewReason: String?
    var requiresReview: Bool { reviewReason != nil }
}

nonisolated struct IncomeJournalDraft: Sendable {
    let kind: IncomeJournalKind
    var amount = ""
    var description = ""
    var method: IncomePaymentMethod = .cash
    var accountID: UInt32?
    var fundingID: UInt32?
    var paymentReference = ""

    var decimalAmount: Decimal? {
        let normalized = amount.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: #"^[0-9]+(\.[0-9]{0,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        return value
    }

    func categoryAllows(_ account: IncomeAccount) -> Bool {
        account.nonPosting != true && account.type == (kind == .sale ? "REVENUE" : "EXPENSE")
    }

    func request(id: UUID, statement: InvoiceIncomeStatement, accounts: [IncomeAccount]) -> IncomeJournalRequest? {
        guard let decimalAmount, let account = accounts.first(where: {
            $0.id == accountID && categoryAllows($0)
        }) else { return nil }
        let funding = accounts.first { $0.id == fundingID }
        let eligibleFunding = funding.flatMap { kind.allowsFunding(method) && $0.isFunding(for: method, in: accounts) ? $0 : nil }
        guard !kind.requiresFunding(method) || eligibleFunding != nil,
              fundingID == nil || eligibleFunding != nil else { return nil }
        let reference = paymentReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind != .expense || method != .check || !reference.isEmpty else { return nil }
        return .init(requestId: id.uuidString.lowercased(), entry: .init(
            transactionType: kind, amount: decimalAmount, description: description.isEmpty ? nil : description,
            incomeStatementId: statement.id, account: account.reference,
            paymentMethod: .init(id: method.lookupID, name: method.rawValue),
            paymentAccount: kind == .sale ? eligibleFunding?.reference : nil,
            sourceAccount: kind == .expense ? eligibleFunding?.reference : nil,
            paymentReference: reference.isEmpty ? nil : reference))
    }
}
