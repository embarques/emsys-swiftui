# Mobile validation — Milestone 1

Reviewed on October 24, 2026, using the iPhone 17 simulator with iOS 27.0 and
iPad Pro 11-inch (M5) simulator with iPadOS 27.0.

No application-code changes were needed during this review.

## Verified interactions

| Check | Result |
| --- | --- |
| iPhone navigation | Inicio and Ajustes reachable through the compact navigation menu; back navigation works. |
| iPhone rotation | Settings remains usable in portrait and landscape. |
| iPad navigation | Sidebar and detail remain visible and usable in portrait and landscape. |
| Languages | Español and English update settings labels and navigation titles immediately on both devices. |
| Appearance overrides | Light and Dark selections visually verified on iPhone. |
| System appearance | On iPad, keeping the app on System follows device Light/Dark changes in both directions. |
| Native launch artwork | Centered ship artwork observed during fresh launches on both devices, followed by the welcome screen. |
| Preference restoration | iPhone returns in Spanish and its saved Light appearance after termination and relaunch. |
| Largest accessibility text size | iPhone settings labels and values grow; rows expand vertically, controls remain reachable, and explanatory text scrolls fully into view. |
| Accessibility information | Settings exposes named selectors with their current values; welcome content exposes readable text without a duplicate logo announcement. |
| VoiceOver focus | On iPad, the language selector receives a visible VoiceOver focus outline and can be activated through its accessibility action. |
| Keyboard navigation | With simulated keyboard input on iPad, Down moves sidebar selection from Inicio to Ajustes and updates the detail screen. |

The temporary text-size, language, appearance, VoiceOver, keyboard-capture, and
orientation changes were restored after testing. Pointer simulation was also
returned after the resize attempts.

## Automated verification

The current build's three tests passed on the iPad simulator with zero failures:

- Bundled translations resolve in both supported languages.
- Preference defaults and persistence remain correct.
- Unknown stored preference values recover to the defaults.

Earlier macOS and iPhone test runs and Debug/Release build results are recorded
in the Milestone 1 review. This pass did not add another test target or alter
signing, identifiers, deployment targets, or other project configuration.

## Remaining acceptance checks

- Narrow iPad app windows and multitasking: attempts to resize the app using
  touch and pointer simulation did not change its window size. This result is
  unverified, not a demonstrated application failure. Confirm on an iPad or a
  simulator setup that responds to the window-resize controls.
- VoiceOver spoken output, reading order across every screen, and physical
  assistive gestures still require a human accessibility pass. Focus and
  accessibility activation checks alone do not constitute a full audit.
- Physical-device startup, input, and distribution signing remain unverified.

Milestone acceptance remains with the project owner. No later milestone was
started during this review.

## October 24 evening normal-workspace verification

The owner's open Xcode workspace initially reported missing GRDB, FirebaseAuth,
FirebaseFirestore and the FirebaseAuth module. Restored its checkouts using the
existing Package.resolved versions and resolved its native package graph. Fixed
four own-source actor-isolation warnings and the test warnings exposed by the
new gate. No dependency upgrades or saved project/signing/identity changes.

`./scripts/verify.sh` now passes in normal Xcode DerivedData: 55 tests on each of
Mac/iPhone/iPad, both Release builds and clean own-source compiler diagnostics.
The open Xcode project also reported a successful 22.7-second build at 9:14 PM,
with “No issues”; its issue navigator was empty with no filtering. Four verifier
infrastructure checks passed. See docs/verification.md and implementation-progress.md
for commands, evidence paths and still-pending live/UI/device acceptance.
