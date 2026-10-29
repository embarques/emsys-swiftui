import Foundation

/// Exact policy text downloaded for local review. A saved draft snapshot is not
/// evidence of agreement, a signature, or acceptance of an invoice by the server.
nonisolated struct InvoicePolicy: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let title: String
    let body: String
    let sortOrder: Int
    let active: Bool
    let updatedAt: String?

    static func validate(_ policies: [InvoicePolicy]) -> Bool {
        policies.count <= 1_000 && Set(policies.map(\.id)).count == policies.count
            && policies.allSatisfy {
                $0.id > 0 && $0.id <= 9_007_199_254_740_991 && $0.active
                    && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }
}
