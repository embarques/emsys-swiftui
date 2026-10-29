# Native authentication — implementation and limits

The current portal is the authentication reference. The legacy Apple auth model
must not be copied. See `api-mobile-contracts.md` for exact local source paths.

## Implemented

- Native Firebase email/password sign-in with password content type and no
  password persistence by application code. Submitted password state is cleared.
- Firebase SDK-owned secure session persistence and initial restoration listener.
- Online token verification and company claim resolution, with server-read
  Firestore `users/{uid}.companyId` fallback when the claim is absent.
  Optional Firestore profile reads use a memory cache, avoiding disk persistence
  of the full profile document and historical fields.
- API `/users/current` validation against the Firebase UID and active flag;
  `/users/permissions` refresh on explicit sign-in, missing device authorization,
  and the profile permission-sync action. Established sessions restore the
  previously verified device copy without a permission/profile API request.
- Tenant and user scoped request credentials, one token refresh after 401, no
  refresh for 403, and an explicit generation ID to reject responses belonging
  to a previous session, even when the same user signs in again.
- Ephemeral API requests without disk response cache, cookies or redirects.
  Relative resource paths prevent accidental credential forwarding to arbitrary
  URLs. API server authorization remains authoritative.
- Logout cancels restoration and hides protected content immediately. A secure
  storage failure is reported rather than treated as successful sign-out.
- Spanish and English sign-in, progress, error and retry messages. Device
  language and appearance settings remain accessible before authentication.

## Configuration and validation boundaries

The owner-supplied ignored Firebase plist matches this app's bundle registration
and the portal project. Configuration is loaded only when present and matching.
Swift Package Manager pins Firebase 13.1.1. Its native SDK owns tokens; application
preferences and GRDB never store credentials. A separate Keychain item stores only the last API-verified user, tenant and grants for offline restoration. The default API root was verified
against the local portal configuration, not guessed from the legacy app.

Firebase documents that macOS authentication requires Keychain Sharing:
<https://firebase.google.com/docs/auth/ios/start>. The owner approved that
capability. The macOS-only entitlement and Xcode capability are configured.
Existing signing identity, team and bundle identifier have not been changed. An unsigned compilation/test pass does not
verify secure session persistence in a properly signed Mac app.

The owner rejected an arbitrary client-defined offline access lifetime. The API
remains authoritative for permissions and checks every synchronized request. No
72-hour cutoff is implemented. Startup restores a valid device snapshot for the
Firebase SDK's persisted user without first attempting a permission API request.
The snapshot is scoped to Firebase project, API root and UID, and retains the
last verified tenant. Explicit sign-in refreshes the profile and permissions;
missing or invalid device copies require fresh authorization. A changed tenant
claim detected during credential renewal invalidates the old context before
business requests proceed. During an authorized session, opening saved records
does not request a Firebase token. Network operations continue to use SDK-managed
credentials and server authorization.

Live login/logout, real token expiration, Firestore rules, Keychain restoration,
and user-facing layout have not been verified with a development account. The Mac
was locked during attempted UI inspection. Unit tests exercise transport behavior
with deterministic local responses, without production account requests.

The optional Firestore company-profile lookup now has a five-second application
deadline matching the portal. Late SDK callbacks are ignored after the request
has completed, and SDK errors are preserved. Tests use injected callbacks and
do not contact Firebase. Cancellation of the SDK's underlying network operation
is not assumed; the session-generation check still prevents obsolete restoration.

## Durable offline context

`AuthorizedSessionStore` performs Keychain work on an actor, using a device-only
After First Unlock item. It stores no tokens or passwords. Version, active-user,
UID and tenant checks reject incompatible snapshots. Saving the verified snapshot
is required before completing online bootstrap; a Keychain error remains a
recoverable configuration failure. Logout removes the snapshot before SDK logout
and never reports success if secure deletion fails. A refreshed tenant claim
invalidates the old context. No SQLite records are deleted during these actions.

Reconnect, foreground and ordinary data synchronization do not refetch permissions.
More → account exposes Sync permissions, the role and last successful update time;
the desktop sidebar's Profile action opens the same account section. Manual refresh
uses the existing `/users/current` and `/users/permissions` endpoints, is serialized
across windows, and preserves the active session identity/open work. New grants
are published only after secure persistence succeeds. Transient server, network,
SDK or storage failures keep the previous copy and show a retryable error.
Confirmed authorization/account/tenant rejection removes cached access; 404 from
these user endpoints means the tenant user or permission record is unavailable.
The timestamp is optional for backward compatibility and never acts as an expiry.

Keychain persistence and Firebase SDK restoration have not been tested end to end
with a live account or properly signed app. Deterministic tests cover snapshot
round-trip, scope/active/version rejection, cache-only startup, explicit-refresh
bypass, failed refresh/revocation handling and legacy timestamp compatibility.
Native light-mode control fixtures were inspected on iPhone/iPad; live profile
interaction, physical devices, dark appearance and large text remain unverified.
