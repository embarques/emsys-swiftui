import Foundation

nonisolated struct LocalInvoiceListEntry: Identifiable, Sendable {
    let id: String
    let draftID: UUID
    let number: String?
    let senderName: String
    let receiverName: String
    let date: String
    let container: String?
    let state: PendingInvoiceCreation.State
    let invoice: Invoice?
    var canDelete = false

    func matches(_ query: InvoiceListQuery) -> Bool {
        let text = query.normalizedText
        return (text.isEmpty || [number, senderName, receiverName, container].compactMap { $0 }
            .contains { $0.localizedStandardContains(text) })
            && (query.startDate.isEmpty || date >= query.startDate)
            && (query.endDate.isEmpty || date <= query.endDate)
            && (query.container.isEmpty || container?.localizedStandardContains(query.container) == true)
    }
}
