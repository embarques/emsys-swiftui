# Required verification before the next feature

Run `./scripts/verify.sh` from the repository root (or invoke it by absolute path).
The script stops at the first failure, returns a nonzero exit status and prints
its full log directory. Fix the failure and rerun; do not proceed to a new feature
with unresolved errors. Focused tests may be used while fixing a failure, but the
full gate must pass before advancing.

## Checks

The gate first exercises Xcode Cloud Firebase provisioning with synthetic
configuration, including retries and invalid/missing inputs. No real Firebase
values are used in those checks. See [Xcode Cloud delivery](xcode-cloud.md) for
the separate signed cloud archive and TestFlight acceptance steps.

1. Resolve the checked-in Package.resolved versions in the normal Xcode workspace.
   No temporary DerivedData path, dependency upgrades or cache resets are used.
2. Discover actual eligible simulator destinations. Both iPhone and iPad must be
   available; missing runtimes fail explicitly rather than silently skipping tests.
3. Build and run the complete XCTest suite on macOS, iPhone and iPad.
4. Compile for the physical iPhone SDK (generic iOS destination), without signing
   or deploying. This verifies a separate build graph from the simulators.
5. Validate that the built iPhone app identifier matches its packaged Firebase
   client. Configuration credentials are never printed.
6. Build Release for macOS and iOS Simulator.
7. Fail on compiler warnings in application or test sources after each build.
8. Check whitespace/conflict artifacts with git diff --check.

Signing is disabled only on these local command invocations. The script never
changes the team, bundle ID, deployment targets or saved signing settings. Test
startup skips Firebase/network bootstrap; tests use injected URL fixtures and
private temporary databases, not production business writes. Logs are kept in a
unique system temporary directory; no secrets or Firebase plist are copied.

## Regression coverage

Existing tests cover preference/localization persistence, transport authentication
and tenant/session boundaries, offline authorization snapshot validation, scoped
SQLite persistence and migrations, invoice outbox atomicity/recovery/conflicts,
synchronization coalescing/cancellation, private PDF download validation and saved
document recovery. Draft tests add unfinished text round-trip, stale-window save
and delete protection, explicit save-as-copy recovery, session/user/tenant/API
scope, date-only behavior, invalid state rejection and indexed metadata pagination.

Add tests for each changed behavior and its relevant failure path. Never remove
or weaken checks to make a failure disappear. A new migration must preserve the
existing database; do not erase user storage or silently drop pending work.

Invoice creation recovery also covers decoded server acknowledgements with an
invalid invoice identity or an identity that differs from the confirmed initial
payment. These submissions move to the existing review state without blocking
unrelated creations. Reopening SQLite and explicitly retrying preserves the
original request bytes and payment receipt; a confirmed payment is not posted
again. Transport failures still leave work pending for retry. This is fixture
coverage of the native recovery path, not live server idempotency acceptance.

Pickup invoice models retain the access scope under which they were opened.
Refreshing company-wide creation down to assigned-pickup creation makes an open
unrestricted draft list/editor unavailable; it cannot save or delete drafts under
the narrower grant. Saved work remains intact in SQLite. An assigned-only screen
stays restricted after a grant upgrade. Tests exercise these transitions with real
local draft models and reopening persistence, plus rejection of foreign-user,
foreign-company, and inactive refreshed authorization snapshots. Permission
restoration still uses the established device copy; no per-screen permission
fetch or additional API authorization rule is introduced. Live permission refresh
and the resulting native lock presentation require signed-account acceptance.

## Native Xcode and UI acceptance

After dependency/project changes, build the actual open EMSYS.xcodeproj in Xcode
and confirm the issue navigator no longer contains the previous package/compiler
errors. Use the owner's current workspace, not only an independent build cache.
For visible changes, verify the relevant native interaction and error state when
access is available. Record what was actually exercised and any remaining checks.

Unit/fixture passes do not establish live Firebase sign-in, signed Keychain
restoration, real connectivity transitions, physical printing, accessibility or
all production workflows. Those require their own explicit acceptance evidence.
Keep their status pending until verified. The application must not expose test-only
login bypasses or production fixture screens to make visual checks easier.

## Installing a simulator build for live authentication

The gate deliberately disables signing and proves compilation/tests only. Never
install its unsigned product as a live Firebase sign-in build. It can open the
sign-in screen while Keychain reads/writes fail with FIRAuthErrorDomain 17995 and
SecItemCopyMatching -34018 (missing entitlement), even with correct credentials.
After the gate finishes, build the normal Debug simulator destination with the
project's saved signing settings and no CODE_SIGNING_ALLOWED override. Check the
resulting signature/entitlements before installing. Do not change the owner's
team, bundle ID, Firebase client, or saved signing configuration to do this.
Unsigned physical-SDK compilation does not establish device provisioning.
