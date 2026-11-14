import SwiftUI

struct PickupListView: View {
    @Environment(AuthenticationSession.self) private var session
    @Environment(NetworkConnection.self) private var connection
    @Environment(SynchronizationState.self) private var synchronization
    @State private var model: PickupListModel?
    @State private var query = PickupListQuery()
    @State private var issue: String?
    @State private var refreshVersion = 0
    @State private var invoiceNumbers: [UInt32: [String]] = [:]
    @State private var invoiceNumbersContext: UUID?
    @State private var invoiceDrafts: InvoiceDraftListModel?
    @State private var showsMap = false
    @State private var mapModel = PickupMapModel(pickups: [])

    private var online: Bool { connection.status != .unavailable }

    private var canReadInvoiceNumbers: Bool {
        session.canViewInvoices || session.canCreateAssignedPickupInvoices
    }

    private var invoiceNumberRequest: InvoiceNumberRequest {
        InvoiceNumberRequest(context: session.contextID, pickupIDs: model?.pickups.map(\.id) ?? [],
            hasAccess: canReadInvoiceNumbers,
            refreshVersion: refreshVersion, lastSync: synchronization.lastFinishedAt)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("pickups.view", selection: $showsMap) {
                Label("pickups.list", systemImage: "list.bullet").tag(false)
                Label("pickups.map", systemImage: "map").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            if showsMap {
                VStack(alignment: .leading, spacing: 8) { pickupFilters }
                    .padding(.horizontal).padding(.bottom, 8)
                if let model {
                    PickupMapView(model: mapModel, isLoading: model.isLoading,
                        hasMore: model.hasMore && online, loadMore: { Task { await model.loadMore() } }) {
                            pickupDetail($0, model: model)
                        }
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else { pickupList }
        }
        .navigationTitle("navigation.pickups")
        .searchable(text: $query.text, prompt: "pickups.search")
        .sheet(item: $invoiceDrafts) { InvoiceDraftListView(model: $0) }
        .toolbar {
            if session.canCreatePickupInvoices {
                Button {
                    Task {
                        do { invoiceDrafts = try await session.pickupInvoiceDrafts() }
                        catch { issue = "drafts.loadError" }
                    }
                } label: { Label("drafts.title", systemImage: "doc.badge.plus") }
            }
            Button { retry() } label: { Label("sync.now", systemImage: "arrow.clockwise") }
                .disabled(model?.isLoading == true)
        }
        .refreshable { await model?.load(query: query, online: online) }
        .onChange(of: model?.pickups) { mapModel.update(model?.pickups ?? []) }
        .task(id: session.contextID) { await prepare() }
        .task(id: invoiceNumberRequest) { await loadInvoiceNumbers(invoiceNumberRequest) }
        .task(id: Request(query: query, online: online, refreshVersion: refreshVersion)) {
            do {
                if !query.text.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
                try Task.checkCancellation()
                await model?.load(query: query, online: online)
            } catch { }
        }
    }

    @ViewBuilder
    private var pickupFilters: some View {
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

    private var pickupList: some View {
        List {
            Section { pickupFilters }
            if let model {
                ForEach(model.pickups) { pickup in
                    NavigationLink {
                        pickupDetail(pickup, model: model)
                    } label: {
                        PickupRowView(pickup: pickup, invoiceNumbers: canReadInvoiceNumbers && invoiceNumbersContext == session.contextID
                            ? invoiceNumbers[pickup.id, default: []] : [])
                    }
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
    }

    private func pickupDetail(_ pickup: Pickup, model: PickupListModel) -> some View {
        PickupDetailView(model: model.detail(pickup, canUpdate: { session.canUpdatePickups }),
            createInvoice: session.canCreatePickupInvoices ? { pickup, receiverID in
                try await session.pickupInvoiceEditor(pickup, receiverID: receiverID)
            } : nil,
            prepareInvoices: session.canCreatePickupInvoices ? { try await session.pickupInvoices(pickup.id) } : nil)
            .onDisappear { refreshVersion += 1 }
    }

    private struct InvoiceNumberRequest: Equatable {
        let context: UUID
        let pickupIDs: [UInt32]
        let hasAccess: Bool
        let refreshVersion: Int
        let lastSync: Date?
    }

    private func loadInvoiceNumbers(_ request: InvoiceNumberRequest) async {
        guard request.hasAccess, !request.pickupIDs.isEmpty else {
            invoiceNumbers = [:]
            return
        }
        do {
            let access = try await session.invoiceAccess(allowAssignedCreation: true)
            let links = try await access.store.pickupInvoiceLinks(pickupIDs: request.pickupIDs)
            guard !Task.isCancelled, request == invoiceNumberRequest else { return }
            invoiceNumbers = links.mapValues { links in
                var seen = Set<String>()
                return links.compactMap(\.number).filter { seen.insert($0).inserted }
            }
            invoiceNumbersContext = request.context
        } catch {
            guard !Task.isCancelled, request == invoiceNumberRequest else { return }
            invoiceNumbers = [:]
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
        invoiceNumbers = [:]
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
