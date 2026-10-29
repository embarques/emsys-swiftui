import SwiftUI

struct AppRootView: View {
    @Environment(AuthenticationSession.self) private var session
    @Environment(NetworkConnection.self) private var connection
    @Environment(SynchronizationState.self) private var synchronization
    @Environment(\.scenePhase) private var scenePhase
    // Each window keeps its own navigation while sharing application preferences.
    @State private var selectedDestination: AppDestination? = .invoices
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if session.phase == .signedIn {
                applicationNavigation.id(session.contextID)
            } else {
                NavigationStack {
                    accountContent
                        .toolbar {
                            NavigationLink { SettingsView() } label: {
                                Label(AppDestination.settings.title, systemImage: AppDestination.settings.systemImageName)
                            }
                        }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ConnectionStatusView() }
        .onChange(of: session.phase) {
            selectedDestination = .invoices
            compactColumn = .sidebar
            synchronization.useSession(session.contextID)
        }
        .onChange(of: synchronization.requestedUploadVersion) {
            // Queue a follow-up without canceling an upload already in flight.
            Task { await synchronize(includesDownloads: false) }
        }
        .task(id: automaticSyncTrigger) {
            guard connection.status == .available, (session.canViewInvoices || session.canViewPickups),
                  scenePhase == .active else { return }
            await synchronize()
        }
    }

    private struct AutomaticSyncTrigger: Equatable {
        let sessionID: UUID
        let isAuthorized: Bool
        let connection: NetworkConnection.Status
        let isActive: Bool
    }

    private var automaticSyncTrigger: AutomaticSyncTrigger {
        AutomaticSyncTrigger(
            sessionID: session.contextID, isAuthorized: session.canViewInvoices || session.canViewPickups,
            connection: connection.status, isActive: scenePhase == .active
        )
    }

    private func synchronize(includesDownloads: Bool = true) async {
        guard (session.canViewInvoices || session.canViewPickups), connection.status != .unavailable, scenePhase == .active else { return }
        let sessionID = session.contextID
        synchronization.useSession(sessionID)
        let requestedUploadVersion = synchronization.requestedUploadVersion
        let previousSuccess = synchronization.lastSucceededAt
        let previousDownload = synchronization.lastDownloadedAt
        while true {
            if synchronization.isRunning { await synchronization.waitForCurrentRun() }
            guard !Task.isCancelled, session.contextID == sessionID, (session.canViewInvoices || session.canViewPickups),
                  connection.status != .unavailable, scenePhase == .active else { return }
            let fulfilled = includesDownloads
                ? synchronization.lastDownloadedAt != previousDownload
                : synchronization.lastSucceededAt != previousSuccess
            if fulfilled,
               synchronization.completedUploadVersion >= requestedUploadVersion { return }
            let started = await synchronization.synchronize(includesDownloads: includesDownloads) {
                var failure: Error?
                do {
                    if session.canViewInvoices {
                        let access = try await session.invoiceAccess()
                        if includesDownloads {
                            try await InvoiceSynchronizer(client: access.client, store: access.store).synchronize()
                        } else {
                            try await InvoiceMutationUploader(client: access.client, store: access.store).synchronize()
                        }
                    } else if session.canCreateAssignedPickupInvoices {
                        let access = try await session.invoiceAccess(allowAssignedCreation: true)
                        try await InvoiceCreationUploader(client: access.client, store: access.store, assignedOnly: true).synchronize()
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { failure = error }
                guard session.contextID == sessionID else { throw APIClientError.sessionChanged }
                do {
                    if session.canViewPickups && session.canUpdatePickups {
                        let access = try await session.pickupAccess()
                        try await PickupCompletionUploader(client: access.client, store: access.store,
                            isAuthorized: { session.contextID == sessionID && session.canUpdatePickups }).synchronize()
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { failure = failure ?? error }
                do {
                    if includesDownloads, session.canCreateAssignedPickupInvoices {
                        let access = try await session.invoiceAccess(allowAssignedCreation: true)
                        try await AssignedInvoicePreparation(client: access.client, store: access.store,
                            isAuthorized: { session.contextID == sessionID && session.canCreateAssignedPickupInvoices }).download()
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { failure = failure ?? error }
                if let failure { throw failure }

            }
            if started { return }
        }
    }

    @ViewBuilder
    private var applicationNavigation: some View {
        #if os(iOS)
        AppTabNavigationView(selection: Binding(
            get: { selectedDestination ?? .invoices }, set: { selectedDestination = $0 }
        )) { destination in
            destinationContent(destination)
        }
        #else
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            AppNavigationView(selection: $selectedDestination)
                .navigationSplitViewColumnWidth(min: AppStyle.Layout.minimumSidebarWidth, ideal: AppStyle.Layout.idealSidebarWidth)
        } detail: {
            NavigationStack {
                destinationContent(selectedDestination ?? .invoices)
            }
            .id(selectedDestination)
        }
        .toolbar {
            if session.canViewInvoices {
                Button { Task { await synchronizeFromNavigation() } } label: {
                    Label("sync.now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(synchronization.isRunning || connection.status == .unavailable)
            }
        }
        #endif
    }

    @ViewBuilder
    private func destinationContent(_ destination: AppDestination) -> some View {
        switch destination {
        case .home: HomeView()
        case .settings: SettingsView()
        case .more: AppMoreView(synchronize: synchronizeFromNavigation)
        case .invoices:
            if session.canViewInvoices { InvoiceListView() }
            else { UnavailableDestinationView(destination: destination, isAuthorized: false) }
        case .pickups:
            if session.canViewPickups { PickupListView() }
            else { UnavailableDestinationView(destination: destination, isAuthorized: false) }
        case .deliveries, .dailyIncome:
            UnavailableDestinationView(destination: destination, isAuthorized: destination.isAccessible(with: session.permissions))
        }
    }

    private func synchronizeFromNavigation() async {
        await synchronize()
    }

    @ViewBuilder
    private var accountContent: some View {
        switch session.phase {
        case .signedOut:
            SignInView()
        case .restoring:
            VStack(spacing: AppStyle.Spacing.medium) {
                ProgressView("auth.restoring")
                Button("auth.signOut") { session.signOut() }
            }
        case .signedIn:
            HomeView()
                .toolbar {
                    Button("auth.signOut") { session.signOut() }
                }
        case .unavailable:
            ContentUnavailableView {
                Label("auth.unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                if let configurationIssue = session.configurationIssue {
                    VStack(spacing: 12) {
                        Text(LocalizedStringKey(configurationIssue.rawValue))
                        Text("auth.configuration.installationHint")
                        if session.didRecheckConfiguration {
                            Text("auth.configuration.recheckFailed").font(.callout.bold())
                        }
                    }
                } else if let issue = session.issue {
                    Text(LocalizedStringKey(issue.rawValue))
                }
            } actions: {
                if session.configurationIssue != nil {
                    Button("auth.configuration.recheck") { session.retry() }
                } else {
                    Button("auth.retry") { session.retry() }
                }
                if session.canSignOut {
                    Button("auth.signOut") { session.signOut() }
                }
            }
        }
    }
}

#Preview {
    AppRootView()
        .environment(AppPreferences())
        .environment(AuthenticationSession())
        .environment(NetworkConnection())
        .environment(SynchronizationState())
        .environment(\.locale, AppLanguage.dominicanSpanish.locale)
}
