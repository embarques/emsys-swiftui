import SwiftUI

struct IncomeCategoryPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var search = ""
    let accounts: [IncomeAccount]
    let kind: IncomeJournalKind
    let selectedID: UInt32?
    let select: (UInt32) -> Void

    private var matchingAccounts: [IncomeAccount] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return accounts.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if accounts.count > 8 { grid.searchable(text: $search) }
                else { grid }
            }
            .navigationTitle("income.selectCategory")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("documents.close") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 400)
        #endif
    }

    private var grid: some View {
        ScrollView {
            if matchingAccounts.isEmpty {
                ContentUnavailableView("income.noCategories", systemImage: "square.grid.2x2")
            } else {
                let columns = [GridItem(dynamicTypeSize.isAccessibilitySize ? .flexible() : .adaptive(minimum: 105),
                                        spacing: 10, alignment: .top)]
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(matchingAccounts) { account in
                        tile(account)
                    }
                }
                .padding()
            }
        }
    }

    private func tile(_ account: IncomeAccount) -> some View {
        let isSelected = account.id == selectedID
        return Button { select(account.id) } label: {
            VStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : kind.icon)
                    .font(.title2)
                    .foregroundStyle(AppStyle.Colors.accent)
                    .accessibilityHidden(true)
                Text(verbatim: account.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(AppStyle.Colors.accent.opacity(isSelected ? 0.15 : 0.06), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(AppStyle.Colors.accent.opacity(isSelected ? 1 : 0.2))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
