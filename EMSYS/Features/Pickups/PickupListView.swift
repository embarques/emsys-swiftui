import SwiftUI

struct PickupListView: View {
    @Environment(AuthenticationSession.self) private var session
    @Environment(NetworkConnection.self) private var connection
    @State private var model: PickupListModel?
    @State private var query = PickupListQuery()
    @State private var issue: String?
    @State private var refreshVersion = 0

    private var online: Bool { connection.status != .unavailable }

    var body: some View {
        List {
            Section {
                Picker("pickups.status", selection: $query.status) {
                    ForEach(PickupListQuery.Status.allCases) { status in
                        Text(LocalizedStringKey(status.title)).tag(status)
                    }
                }
                .pickerStyle(.segmented)
                if model?.isShowingDownloaded == true {
                    Label("pickups.downloaded", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
                }
                if let issue = model?.issue ?? issue {
                    Label(LocalizedStringKey(issue), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("auth.retry") { retry() }
                }
            }
            if let model {
                ForEach(model.pickups) { pickup in
                    NavigationLink {
                        PickupDetailView(model: model.detail(pickup, canUpdate: { session.canUpdatePickups }),
                            createInvoice: session.canCreateInvoices ? { pickup, receiverID in
                                try await session.pickupInvoiceEditor(pickup, receiverID: receiverID)
                            } : nil)
                            .onDisappear { refreshVersion += 1 }
                    } label: { PickupRowView(pickup: pickup) }
                }
                if model.isLoading { ProgressView().frame(maxWidth: .infinity) }
                if model.hasMore, online {
                    Button("pickups.loadMore") { Task { await model.loadMore() } }
                        .disabled(model.isLoading)
                }
                if model.pickups.isEmpty, !model.isLoading, model.issue == nil {
                    ContentUnavailableView("pickups.empty", systemImage: "shippingbox",
                        description: Text(online ? "pickups.emptyHint" : "pickups.offlineEmpty"))
                }
            } else if issue == nil { ProgressView().frame(maxWidth: .infinity) }
        }
        .navigationTitle("navigation.pickups")
        .searchable(text: $query.text, prompt: "pickups.search")
        .toolbar {
            Button { retry() } label: { Label("sync.now", systemImage: "arrow.clockwise") }
                .disabled(model?.isLoading == true)
        }
        .refreshable { await model?.load(query: query, online: online) }
        .task(id: session.contextID) { await prepare() }
        .task(id: Request(query: query, online: online, refreshVersion: refreshVersion)) {
            do {
                if !query.text.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
                try Task.checkCancellation()
                await model?.load(query: query, online: online)
            } catch { }
        }
    }

    private struct Request: Equatable {
        let query: PickupListQuery
        let online: Bool
        let refreshVersion: Int
    }

    private func retry() {
        if model == nil { Task { await prepare() } }
        else { refreshVersion += 1 }
    }

    private func prepare() async {
        model = nil
        issue = nil
        let contextID = session.contextID
        do {
            let access = try await session.pickupAccess()
            guard session.contextID == contextID, session.canViewPickups, !Task.isCancelled else { return }
            let prepared = PickupListModel(client: access.client, store: access.store) {
                session.contextID == contextID && session.canViewPickups
            }
            model = prepared
            await prepared.load(query: query, online: online)
        } catch {
            if session.contextID == contextID, !Task.isCancelled { issue = "pickups.storageError" }
        }
    }
}
