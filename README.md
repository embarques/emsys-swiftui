# EMSYS for Apple platforms

Native SwiftUI application for iPhone, iPad, and macOS. Product requirements
and milestone approval rules are in `AGENTS.md` and `EMSYS-MOBILE-SPEC.md`.
Naming, organization, and readability conventions are in [Code conventions](docs/code-conventions.md).

## Milestone 1 foundation

- `App`: scene composition and shared preferences.
- `Navigation`: typed destinations; `AppRootView` owns navigation per window.
- `Preferences`: observable device preferences, persisted in UserDefaults.
- `Features/Home`: welcome screen.
- `Features/Settings`: language and appearance controls.
- `Appearance/AppStyle.swift`: shared colors, fonts, spacing, and layout dimensions.
- `Resources`: Dominican Spanish (`es-DO`) and English String Catalog.
- `EMSYSTests`: preference recovery/persistence and bundled localization tests.

The first launch uses Dominican Spanish and System appearance. Preferences apply
immediately and work offline. The split navigation collapses to a navigation
stack on compact screens; larger windows show a sidebar and detail. macOS also
provides a native Settings scene and its standard keyboard shortcut.

The native iPhone/iPad launch screen and the welcome screen use the legacy ship
artwork. The iOS-only launch settings are in `Configuration/iOS-Info.plist`.
Startup has no artificial delay; macOS opens the application window directly.

Firebase authentication, GRDB invoice storage and initial offline description editing are implemented incrementally.
See [Implementation progress](docs/implementation-progress.md) for current status,
validation evidence, pending approvals and continuation instructions. The app
verifies the Firebase session, tenant profile and API permissions before exposing
business content. Downloaded invoice pages and details are persisted separately
for each user, company and API environment. Description edits use a transactional
outbox, conditional uploads and explicit conflict review. The new API routes are
in review PR #328 and are not deployed; queued work is preserved when unavailable.
Native semantic colors are the initial accessible baseline; final branded colors
require a separate visual review against EMSYS references. The app icon uses the
legacy `emsysApp` artwork, with sizes supplied for iOS and macOS.

## Authentication configuration

Place the registered Apple client's `GoogleService-Info.plist` in
`EMSYS/Resources`. Git ignores this file and environment-specific filename
variants. The plist must match the existing Apple bundle identifier. Never copy a
Firebase Admin service-account key into an Apple application.

The native client uses the current portal's HTTPS API root. An
`EMSYSAPIBaseURL` Info value can override it for a separate environment. Local
tests use injected URL loading fixtures and temporary databases, without live
accounts or production writes. macOS Firebase authentication requires Keychain
Sharing; its approved macOS capability is configured. Signed runtime validation
remains pending.

Dependencies are pinned through Swift Package Manager: Firebase Apple SDK
13.1.1 (Auth and Firestore) and GRDB 7.11.1. No Analytics product was added.

The main window shows a localized offline banner. Signed-in invoice users can
select Sync now; invoice downloads also refresh when a network connection returns
while the app is active. See [Synchronization status](docs/synchronization-status.md)
for the implemented upload/download scope and remaining offline workflow work.

## Verification

Run `./scripts/verify.sh` after each code/dependency change and before the next
feature. It uses the normal Xcode workspace, resolves pinned dependencies, runs
Mac/iPhone/iPad tests, builds both Release targets and stops on errors or our
compiler warnings. Logs are saved in a unique temporary directory. See
[Required verification](docs/verification.md) for coverage and UI acceptance.

When changing the verification scripts, also run
`python3 -m unittest discover -s scripts/tests -v` to check that the gate rejects
our compiler warnings and stops before builds/tests when package resolution fails.

See [Mobile validation results](docs/mobile-validation.md) for completed checks
and remaining acceptance items.

Open `EMSYS.xcodeproj` and select the shared `EMSYS` scheme. Build and run on
macOS, an iPhone simulator, and an iPad simulator. Run the test action for the
complete regression suite. Existing minimum OS versions are iOS/iPadOS 27.0 and macOS 26.6.

Manual acceptance checks:

1. Open Settings; verify first-launch Spanish and System appearance.
2. Switch languages; verify sidebar, detail, settings, and appearance labels.
3. Select each appearance, including System; verify system changes are followed.
4. Relaunch; verify preferences persist without a network connection.
5. Open two Mac windows; verify shared preferences and independent navigation.
6. Resize windows and iPad multitasking layouts; verify all destinations remain reachable.
7. Check large accessibility text, VoiceOver labels, contrast, and keyboard focus.

Build commands may use `CODE_SIGNING_ALLOWED=NO` for local compilation checks
without altering the project's saved signing settings. Distribution and physical
device signing must be verified separately.
