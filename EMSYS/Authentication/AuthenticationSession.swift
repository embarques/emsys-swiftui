import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Observation

@MainActor
@Observable
final class AuthenticationSession {
    enum Phase: Equatable {
        case restoring
        case signedOut
        case signedIn
        case unavailable
    }

    private(set) var phase: Phase = .restoring
    private(set) var user: AuthenticatedUser?
    private(set) var permissions: UserPermissions?
    private(set) var issue: AuthenticationIssue?
    private(set) var isSigningIn = false
    private(set) var isRestoredOffline = false
    private(set) var permissionsSyncedAt: Date?
    private(set) var isSyncingPermissions = false
    private(set) var permissionsSyncIssue: String?
    private(set) var configurationIssue: AuthenticationConfigurationIssue?
    private(set) var didRecheckConfiguration = false

    @ObservationIgnored private var auth: Auth?
    @ObservationIgnored private var profileDatabase: Firestore?
    @ObservationIgnored private var listener: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var restoration: Task<Void, Never>?
    @ObservationIgnored private var companyID: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var authorizedSessions: AuthorizedSessionStore?
    @ObservationIgnored private var refreshPermissionsOnRestore = false

    @ObservationIgnored private let configurationProvider: () -> FirebaseOptions?

    init(configurationProvider: (() -> FirebaseOptions?)? = nil) {
        self.configurationProvider = configurationProvider ?? {
            guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") else { return nil }
            return FirebaseOptions(contentsOfFile: path)
        }
    }

    var canSignOut: Bool { auth != nil }

    var contextID: UUID { generation }

    var canViewInvoices: Bool {
        phase == .signedIn && permissions?.contains("canViewInvoice", resourceType: "invoice") == true
    }

    var canViewPickups: Bool {
        phase == .signedIn && AppDestination.pickups.isAccessible(with: permissions)
    }

    var canUpdatePickups: Bool {
        canViewPickups && ["canUpdatePickup", "canUpdateAssignedAppointments"].contains {
            permissions?.contains($0, resourceType: "pickup") == true
        }
    }

    func pickupAccess() async throws -> (client: APIClient, store: PickupStore) {
        guard canViewPickups, let apiBaseURL, let userID = auth?.currentUser?.uid, let companyID else {
            throw AuthenticationIssue.authorization
        }
        let sessionID = generation
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AuthenticationIssue.configuration
        }
        let store = try await PickupStore.open(directory: directory.appending(path: "EMSYS/Pickups", directoryHint: .isDirectory),
            userID: userID, companyID: companyID, apiEnvironment: apiBaseURL.absoluteString)
        guard generation == sessionID, canViewPickups else { throw APIClientError.sessionChanged }
        let client = try APIClient(baseURL: apiBaseURL) { [weak self] forceRefresh in
            guard let self, self.generation == sessionID, self.canViewPickups else { throw APIClientError.sessionChanged }
            return try await self.credentials(forceRefresh: forceRefresh)
        }
        return (client, store)
    }

    var canCreateInvoices: Bool {
        canViewInvoices && permissions?.contains("canCreateInvoice", resourceType: "invoice") == true
    }

    var canPrintInvoices: Bool {
        canViewInvoices && permissions?.contains("canPrintInvoice", resourceType: "invoice") == true
    }

    var canViewCustomers: Bool {
        phase == .signedIn && permissions?.contains("canViewCustomer", resourceType: "customer") == true
    }

    var canViewContainers: Bool {
        phase == .signedIn && permissions?.contains("canViewContainer", resourceType: "container") == true
    }

    var canReviewInvoicePolicies: Bool {
        phase == .signedIn && (permissions?.contains("canCreateInvoice", resourceType: "invoice") == true
            || permissions?.contains("canViewInvoicePolicy", resourceType: "invoice_policy") == true)
    }

    var canUpdateInvoices: Bool {
        canViewInvoices && permissions?.contains("canUpdateInvoice", resourceType: "invoice") == true
    }

    func invoiceAccess() async throws -> (client: APIClient, store: InvoiceStore) {
        guard canViewInvoices, let apiBaseURL,
              let userID = auth?.currentUser?.uid, let companyID else {
            throw AuthenticationIssue.authorization
        }
        // Opening already-authorized local records must not require a token
        // refresh. The API client obtains fresh credentials only for requests.
        let sessionID = generation
        guard let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { throw AuthenticationIssue.configuration }
        let store = try await InvoiceStore.open(
            directory: supportDirectory.appending(path: "EMSYS/Invoices", directoryHint: .isDirectory),
            userID: userID, companyID: companyID, apiEnvironment: apiBaseURL.absoluteString
        )
        guard sessionID == generation, canViewInvoices else { throw APIClientError.sessionChanged }
        let client = try APIClient(baseURL: apiBaseURL) { [weak self] forceRefresh in
            guard let self, self.canViewInvoices, self.generation == sessionID else {
                throw APIClientError.sessionChanged
            }
            return try await self.credentials(forceRefresh: forceRefresh)
        }
        return (client, store)
    }

    // The existing portal's configured API root. No browser proxy is needed by
    // native clients. A separate environment can supply EMSYSAPIBaseURL in Info.
    private var apiBaseURL: URL? {
        URL(string: Bundle.main.object(forInfoDictionaryKey: "EMSYSAPIBaseURL") as? String
            ?? APIConfiguration.defaultRoot)
    }

    func start() {
        guard auth == nil else { return }
        configurationIssue = nil
        didRecheckConfiguration = false
        guard let options = configurationProvider() else {
            failConfiguration(.missing)
            return
        }
        guard options.bundleID == Bundle.main.bundleIdentifier else {
            failConfiguration(.identityMismatch)
            return
        }
        guard let projectID = options.projectID, !projectID.isEmpty,
              let bundleID = Bundle.main.bundleIdentifier,
              let apiBaseURL, apiBaseURL.scheme == "https", apiBaseURL.host != nil else {
            failConfiguration(.incomplete)
            return
        }
        if let configured = FirebaseApp.app() {
            guard configured.options.googleAppID == options.googleAppID,
                  configured.options.projectID == projectID,
                  configured.options.bundleID == bundleID else {
                failConfiguration(.identityMismatch)
                return
            }
        } else {
            FirebaseApp.configure(options: options)
        }
        authorizedSessions = AuthorizedSessionStore(
            bundleID: bundleID, projectID: projectID, apiURL: apiBaseURL
        )
        let profileDatabase = Firestore.firestore()
        let profileSettings = profileDatabase.settings
        // This optional profile resolves tenant context only. Avoid persisting
        // the full Firestore document or historical profile fields on disk.
        profileSettings.cacheSettings = MemoryCacheSettings()
        profileDatabase.settings = profileSettings
        self.profileDatabase = profileDatabase
        let auth = Auth.auth()
        self.auth = auth
        // The SDK persists/restores its session securely. The app never saves a
        // password, refresh token or ID token in preferences or its database.
        listener = auth.addStateDidChangeListener { [weak self] _, firebaseUser in
            Task { @MainActor [weak self] in
                self?.restore(firebaseUser)
            }
        }
    }

    func signIn(email: String, password: String) async {
        guard let auth, !isSigningIn else { return }
        issue = nil
        isSigningIn = true
        refreshPermissionsOnRestore = true
        defer { isSigningIn = false }
        do {
            _ = try await auth.signIn(
                withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            // The auth observer performs tenant and API authorization bootstrap.
        } catch {
            issue = .signIn
            refreshPermissionsOnRestore = false
        }
    }

    func retry() {
        guard let auth else {
            start()
            didRecheckConfiguration = configurationIssue != nil
            return
        }
        restore(auth.currentUser)
    }

    func syncPermissions() async {
        guard phase == .signedIn, let auth, !isSyncingPermissions else { return }
        let context = generation
        isSyncingPermissions = true
        permissionsSyncIssue = nil
        defer { if generation == context { isSyncingPermissions = false } }
        restore(auth.currentUser, preservingAuthorizedContext: true, refreshPermissions: true)
        await restoration?.value
        guard generation == context, phase == .signedIn else { return }
        if issue != nil { permissionsSyncIssue = "permissions.syncError" }
    }

    func signOut() {
        guard let auth else {
            phase = .unavailable
            issue = .configuration
            return
        }
        restoration?.cancel()
        generation = UUID()
        let requestGeneration = generation
        let userID = auth.currentUser?.uid
        refreshPermissionsOnRestore = false
        clearAuthorization()
        phase = .restoring
        restoration = Task {
            do {
                if let userID { try await authorizedSessions?.remove(userID: userID) }
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                try auth.signOut()
                phase = .signedOut
                issue = nil
            } catch {
                guard generation == requestGeneration else { return }
                // Hide business content and allow retry if secure deletion fails.
                phase = .unavailable
                issue = .signOut
            }
        }
    }

    func credentials(forceRefresh: Bool) async throws -> APICredentials {
        guard let auth, let firebaseUser = auth.currentUser, let companyID else {
            throw APIClientError.missingCredentials
        }
        let requestGeneration = generation
        let result = try await firebaseUser.getIDTokenResult(forcingRefresh: forceRefresh)
        guard generation == requestGeneration, auth.currentUser?.uid == firebaseUser.uid else {
            throw APIClientError.sessionChanged
        }
        // A refreshed tenant claim cannot silently change the context of work
        // already in flight. Require a new authorization bootstrap instead.
        if let claimedCompany = Self.nonempty(result.claims["companyId"] as? String),
           claimedCompany != companyID {
            clearAuthorization()
            phase = .unavailable
            issue = .company
            do {
                try await authorizedSessions?.remove(userID: firebaseUser.uid)
            } catch {
                guard generation == requestGeneration else { throw APIClientError.sessionChanged }
                do {
                    try auth.signOut()
                } catch {
                    issue = .signOut
                }
            }
            throw APIClientError.sessionChanged
        }
        return APICredentials(
            sessionID: requestGeneration, userID: firebaseUser.uid,
            companyID: companyID, idToken: result.token
        )
    }

    private func restore(_ firebaseUser: FirebaseAuth.User?, preservingAuthorizedContext: Bool = false,
                         refreshPermissions: Bool = false) {
        guard auth?.currentUser?.uid == firebaseUser?.uid else { return }
        let mustRefresh = refreshPermissions || refreshPermissionsOnRestore
        if phase == .signedIn, user?.uid == firebaseUser?.uid, !mustRefresh { return }
        let keepsContext = preservingAuthorizedContext && phase == .signedIn
            && user?.uid == firebaseUser?.uid && companyID != nil
        let previousCompanyID = companyID
        restoration?.cancel()
        if !keepsContext {
            generation = UUID()
            clearAuthorization()
        }
        issue = nil
        guard let firebaseUser else { phase = .signedOut; return }
        if !keepsContext { phase = .restoring }
        let requestGeneration = generation
        restoration = Task { [weak self] in
            guard let self else { return }
            do {
                guard let authorizedSessions else { throw AuthenticationIssue.configuration }
                let loaded = try await AuthorizedSessionLoader.load(userID: firebaseUser.uid,
                    companyID: keepsContext ? previousCompanyID : nil, refreshPermissions: mustRefresh,
                    cached: { try await authorizedSessions.load(userID: firebaseUser.uid, companyID: previousCompanyID) },
                    refreshed: {
                        try await self.refreshedAuthorization(for: firebaseUser, requestGeneration: requestGeneration,
                            keepsContext: keepsContext, previousCompanyID: previousCompanyID)
                    })
                try Task.checkCancellation()
                guard generation == requestGeneration, auth?.currentUser?.uid == firebaseUser.uid else { return }
                companyID = loaded.snapshot.companyID
                user = loaded.snapshot.user
                permissions = loaded.snapshot.permissions
                permissionsSyncedAt = loaded.snapshot.permissionsSyncedAt
                isRestoredOffline = loaded.usedCache
                if !loaded.usedCache { refreshPermissionsOnRestore = false }
                phase = .signedIn
            } catch is CancellationError {
                return
            } catch {
                guard generation == requestGeneration, !Task.isCancelled else { return }
                if keepsContext, !Self.invalidatesAuthorization(error), companyID == previousCompanyID {
                    // A failed manual refresh preserves the last verified grants
                    // and any open work unless authorization was revoked.
                    issue = .connection
                    return
                }
                if Self.permitsOfflineRestoration(error), let authorizedSessions {
                    do {
                        if let saved = try await authorizedSessions.load(
                            userID: firebaseUser.uid, companyID: companyID
                        ) {
                            try Task.checkCancellation()
                            guard generation == requestGeneration,
                                  auth?.currentUser?.uid == firebaseUser.uid else { return }
                            companyID = saved.companyID
                            user = saved.user
                            permissions = saved.permissions
                            permissionsSyncedAt = saved.permissionsSyncedAt
                            isRestoredOffline = true
                            phase = .signedIn
                            return
                        }
                    } catch {
                        // Missing, unreadable or obsolete snapshots never grant access.
                    }
                } else if let authorizedSessions {
                    do {
                        try await authorizedSessions.remove(userID: firebaseUser.uid)
                    } catch {
                        // Also end the SDK session if a revoked context cannot
                        // be removed, so it cannot be restored as offline access.
                        guard generation == requestGeneration else { return }
                        do {
                            try auth?.signOut()
                        } catch {
                            clearAuthorization()
                            phase = .unavailable
                            issue = .signOut
                            return
                        }
                    }
                }
                guard generation == requestGeneration else { return }
                clearAuthorization()
                phase = .unavailable
                if let knownIssue = error as? AuthenticationIssue {
                    issue = knownIssue
                } else if let apiError = error as? APIClientError,
                          apiError == .httpStatus(403) || apiError == .httpStatus(401) {
                    issue = .authorization
                } else {
                    issue = .connection
                }
            }
        }
    }

    private func refreshedAuthorization(for firebaseUser: FirebaseAuth.User, requestGeneration: UUID,
                                        keepsContext: Bool, previousCompanyID: String?) async throws -> AuthorizedSessionSnapshot {
        let token = try await firebaseUser.getIDTokenResult(forcingRefresh: true)
        var resolvedCompany = Self.nonempty(token.claims["companyId"] as? String)
        if resolvedCompany == nil {
            guard let profileDatabase else { throw AuthenticationIssue.configuration }
            let company = try await CompanyProfileLookup.read { completion in
                profileDatabase.collection("users").document(firebaseUser.uid)
                    .getDocument(source: .server) { snapshot, error in
                        completion(snapshot?.data()?["companyId"] as? String, error)
                    }
            }
            resolvedCompany = Self.nonempty(company)
        }
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw APIClientError.sessionChanged }
        guard let resolvedCompany else { throw AuthenticationIssue.company }
        if keepsContext && resolvedCompany != previousCompanyID { throw AuthenticationIssue.company }
        companyID = resolvedCompany
        guard let apiBaseURL else { throw AuthenticationIssue.configuration }
        let client = try APIClient(baseURL: apiBaseURL) { [weak self] forceRefresh in
            guard let self else { throw APIClientError.missingCredentials }
            return try await self.credentials(forceRefresh: forceRefresh)
        }
        let profile = try await client.get("users/current", as: AuthenticatedUser.self)
        guard profile.uid == firebaseUser.uid, profile.active else {
            throw AuthenticationIssue.authorization
        }
        let grants = try await client.get("users/permissions", as: UserPermissions.self)
        guard let authorizedSessions else { throw AuthenticationIssue.configuration }
        let snapshot = AuthorizedSessionSnapshot(companyID: resolvedCompany, user: profile, permissions: grants)
        try Task.checkCancellation()
        guard generation == requestGeneration, auth?.currentUser?.uid == firebaseUser.uid else { throw APIClientError.sessionChanged }
        try await authorizedSessions.save(snapshot)
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw APIClientError.sessionChanged }
        return snapshot
    }

    private func failConfiguration(_ reason: AuthenticationConfigurationIssue) {
        clearAuthorization()
        configurationIssue = reason
        phase = .unavailable
        issue = .configuration
    }

    private func clearAuthorization() {
        user = nil
        permissions = nil
        companyID = nil
        isRestoredOffline = false
        permissionsSyncedAt = nil
        isSyncingPermissions = false
        permissionsSyncIssue = nil
    }

    static func invalidatesAuthorization(_ error: Error) -> Bool {
        if let issue = error as? AuthenticationIssue {
            return issue == .authorization || issue == .company
        }
        if let apiError = error as? APIClientError {
            // Both authorization endpoints return 404 when the tenant user
            // or its permission record no longer exists.
            return apiError == .httpStatus(401) || apiError == .httpStatus(403)
                || apiError == .httpStatus(404) || apiError == .sessionChanged
        }
        let error = error as NSError
        guard error.domain == AuthErrorDomain else { return false }
        return [AuthErrorCode.userDisabled, .userNotFound, .invalidUserToken, .userTokenExpired]
            .contains { $0.rawValue == error.code }
    }

    static func permitsOfflineRestoration(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == AuthErrorDomain {
            return error.code == AuthErrorCode.networkError.rawValue
        }
        guard error.domain == NSURLErrorDomain else { return false }
        return [URLError.notConnectedToInternet, .networkConnectionLost, .timedOut,
                .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains {
            $0.rawValue == error.code
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
