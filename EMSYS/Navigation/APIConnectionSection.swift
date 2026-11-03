import SwiftUI

@MainActor
struct APIConnectionSection: View {
    @State private var model: APIHealthCheckModel
    @State private var checkTask: Task<Void, Never>?

    init(model: APIHealthCheckModel? = nil) {
        _model = State(initialValue: model ?? APIHealthCheckModel())
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                Text("apiHealth.server").font(.caption).foregroundStyle(.secondary)
                if let url = model.baseURL {
                    Text(verbatim: url.absoluteString).font(.callout).textSelection(.enabled)
                } else { Text("apiHealth.status.invalidConfiguration") }
            }
            Button {
                checkTask = Task { await model.check() }
            } label: {
                HStack {
                    Label("apiHealth.test", systemImage: "network")
                    Spacer()
                    if model.status == .checking { ProgressView().controlSize(.small) }
                }
            }
            .disabled(model.status == .checking)
            .accessibilityIdentifier("api-health-test")
            Label(LocalizedStringKey(model.status.title), systemImage: statusSymbol)
                .foregroundStyle(model.status == .healthy ? .green : .primary)
                .accessibilityIdentifier("api-health-result")
            if let status = model.httpStatus {
                LabeledContent("apiHealth.httpStatus", value: String(status)).font(.caption)
            }
            if let checkedAt = model.checkedAt {
                LabeledContent("apiHealth.checkedAt") { Text(checkedAt, format: .dateTime) }.font(.caption)
            }
        } header: {
            Text("apiHealth.title")
        } footer: {
            Text("apiHealth.explanation")
        }
        .onDisappear { checkTask?.cancel() }
    }

    private var statusSymbol: String {
        switch model.status {
        case .idle, .checking: "network"
        case .healthy: "checkmark.circle.fill"
        default: "exclamationmark.triangle"
        }
    }
}
