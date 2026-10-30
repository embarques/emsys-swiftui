import FirebaseAuth
import XCTest
#if os(iOS)
import SwiftUI
import UIKit
#endif
@testable import EMSYS

@MainActor
final class PermissionCachingTests: XCTestCase {
    func testRestorationUsesSavedGrantsWithoutFetchingPermissions() async throws {
        var requests = 0
        let saved = snapshot(grant: "canViewAssignedAppointments")
        let result = try await AuthorizedSessionLoader.load(userID: "driver", companyID: "company",
            refreshPermissions: false, cached: { saved }, refreshed: {
                requests += 1
                return self.snapshot(grant: "canViewPickup")
            })
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(result.usedCache)
        XCTAssertTrue(result.snapshot.permissions.contains("canViewAssignedAppointments", resourceType: "pickup"))
        XCTAssertFalse(result.snapshot.permissions.contains("canViewPickup", resourceType: "pickup"))
    }

    func testLoginAndManualRefreshBypassCachedGrants() async throws {
        var cachedReads = 0
        var requests = 0
        let updatedAt = Date(timeIntervalSince1970: 1234)
        let result = try await AuthorizedSessionLoader.load(userID: "driver", companyID: "company",
            refreshPermissions: true, cached: {
                cachedReads += 1
                return self.snapshot(grant: "canViewPickup")
            }, refreshed: {
                requests += 1
                return self.snapshot(grant: "canViewAssignedAppointments", syncedAt: updatedAt)
            })
        XCTAssertEqual(cachedReads, 0)
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(result.usedCache)
        XCTAssertEqual(result.snapshot.permissionsSyncedAt, updatedAt)
        XCTAssertFalse(result.snapshot.permissions.contains("canViewPickup", resourceType: "pickup"))
    }

    func testForeignAndMissingCopiesRequireFreshAuthorization() async throws {
        for cached in [nil, snapshot(userID: "other"), snapshot(companyID: "other")] {
            var requests = 0
            let result = try await AuthorizedSessionLoader.load(userID: "driver", companyID: "company",
                refreshPermissions: false, cached: { cached }, refreshed: {
                    requests += 1
                    return self.snapshot()
                })
            XCTAssertFalse(result.usedCache)
            XCTAssertEqual(requests, 1)
        }
    }

    func testForeignOrInactiveRefreshedIdentityCannotReplaceAuthorizedContext() async throws {
        var inactive = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot())) as? [String: Any])
        var profile = try XCTUnwrap(inactive["user"] as? [String: Any])
        profile["active"] = false
        inactive["user"] = profile
        let inactiveSnapshot = try JSONDecoder().decode(AuthorizedSessionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: inactive))
        for foreign in [snapshot(userID: "other"), snapshot(companyID: "other"), inactiveSnapshot] {
            do {
                _ = try await AuthorizedSessionLoader.load(userID: "driver", companyID: "company",
                    refreshPermissions: true, cached: { self.snapshot() }, refreshed: { foreign })
                XCTFail("Invalid refreshed scope must not grant access")
            } catch AuthenticationIssue.authorization { }
        }
    }

    func testRefreshErrorsDoNotClaimSuccessOrFallBackToOldGrants() async throws {
        let failures: [Error] = [URLError(.notConnectedToInternet), APIClientError.httpStatus(403)]
        for error in failures {
            do {
                _ = try await AuthorizedSessionLoader.load(userID: "driver", companyID: "company",
                    refreshPermissions: true, cached: { self.snapshot() }, refreshed: { throw error })
                XCTFail("A failed refresh must not be presented as success")
            } catch { }
        }
        XCTAssertFalse(AuthenticationSession.invalidatesAuthorization(URLError(.notConnectedToInternet)))
        XCTAssertFalse(AuthenticationSession.invalidatesAuthorization(APIClientError.httpStatus(500)))
        XCTAssertTrue(AuthenticationSession.invalidatesAuthorization(APIClientError.httpStatus(401)))
        XCTAssertTrue(AuthenticationSession.invalidatesAuthorization(APIClientError.httpStatus(403)))
        XCTAssertTrue(AuthenticationSession.invalidatesAuthorization(APIClientError.httpStatus(404)))
        XCTAssertFalse(AuthenticationSession.invalidatesAuthorization(
            NSError(domain: AuthErrorDomain, code: AuthErrorCode.internalError.rawValue)))
        XCTAssertTrue(AuthenticationSession.invalidatesAuthorization(
            NSError(domain: AuthErrorDomain, code: AuthErrorCode.userDisabled.rawValue)))
        XCTAssertTrue(AuthenticationSession.invalidatesAuthorization(AuthenticationIssue.company))
        XCTAssertTrue(AuthenticationSession.invalidatesAuthorization(AuthenticationIssue.authorization))
    }

    func testSnapshotKeepsGrantsAndTimestampAndReadsOlderDeviceCopies() throws {
        let saved = snapshot()
        let encoded = try JSONEncoder().encode(saved)
        let restored = try JSONDecoder().decode(AuthorizedSessionSnapshot.self, from: encoded)
        XCTAssertEqual(restored.permissionsSyncedAt, saved.permissionsSyncedAt)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "permissionsSyncedAt")
        let old = try JSONDecoder().decode(AuthorizedSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.permissionsSyncedAt)
        XCTAssertTrue(old.matches(userID: "driver", companyID: "company"))
    }

    #if os(iOS)
    func testNativeProfilePermissionControlsRenderInSpanish() async throws {
        let host = UIHostingController(rootView: NavigationStack {
            Form {
                Section("navigation.account") {
                    Text(verbatim: "Conductor de prueba").font(.headline)
                    LabeledContent("permissions.role", value: "Conductor")
                    PermissionSyncControls(isSyncing: false, syncedAt: Date(timeIntervalSince1970: 1793102400),
                        issue: "permissions.syncError", isOnline: false, sync: { })
                }
            }
            .navigationTitle("permissions.profile")
        }.environment(\.locale, Locale(identifier: "es-DO")))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try XCTUnwrap(image.pngData()).write(to: FileManager.default.temporaryDirectory.appending(path: "emsys-permissions-\(device).png"))
    }
    #endif

    private func snapshot(userID: String = "driver", companyID: String = "company",
                          grant: String = "canViewAssignedAppointments", syncedAt: Date = .now) -> AuthorizedSessionSnapshot {
        AuthorizedSessionSnapshot(companyID: companyID,
            user: .init(uid: userID, name: "Driver", email: nil, active: true),
            permissions: .init(role: .init(id: 1, name: "Driver"),
                permissions: [.init(name: grant, resourceType: "pickup")]), permissionsSyncedAt: syncedAt)
    }
}
