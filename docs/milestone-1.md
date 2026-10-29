# Milestone 1 implementation review

## Scope

The Apple foundation uses a shared SwiftUI target for iPhone, iPad, and native
macOS. It provides a welcome screen and local settings without business data,
authentication, networking, or database dependencies.

Navigation is typed and window-local. NavigationSplitView supplies a sidebar on
larger windows and a collapsed stack on compact screens. Device preference state
is shared across windows. The native macOS Settings scene uses the same state.

Language defaults to Dominican Spanish (`es-DO`), with English (`en`) available.
Appearance defaults to System, with Light and Dark overrides. UserDefaults stores
only these non-sensitive device preferences. Invalid values fall back safely.
The String Catalog covers the current screens. Native title strings resolve
explicitly against the selected language because macOS window titles can resolve
outside the SwiftUI locale environment.

## Legacy references and choices

`EmsysManager` supplies navigation concepts, terminology, and brand references.
Its generic Spanish, Boolean dark mode setting, reflection-based localization,
and placeholder business destinations were not copied into the foundation.

`emsysApp` contains PencilKit signature prototypes and UIKit-based invoice PDF
generation, PDFKit preview, and sharing. These remain reference material for
later milestones. Invoice content and layout need validation against the current
web/API. Native macOS requires its own capture/rendering integration where the
legacy code assumes UIKit. No document implementation is included here.

Initial tokens use native semantic colors and text styles plus a small spacing
and layout scale. Final brand colors and icons require visual review; legacy
assets do not yet constitute an approved accessible cross-platform palette.

## Startup artwork

The legacy ship logo is supplied as a shared image asset at 1x, 2x, and 3x.
iPhone and iPad use the native `UILaunchScreen` dictionary in the iOS-only
`Configuration/iOS-Info.plist`, merged with generated application metadata.
The launch background follows system appearance. The welcome screen uses the
same artwork on all platforms. macOS opens its normal window directly.
There is no startup timer, artificial delay, animation, or network prerequisite.
Saved in-app appearance takes effect when SwiftUI starts; the operating-system
launch screen itself follows the device appearance.

Both iOS Simulator and macOS builds passed. The generated iOS application plist
was checked for the logo and safe-area configuration, and the macOS welcome
screen was visually checked. A subsequent mobile review observed the native
launch artwork on both iPhone and iPad; see [Mobile validation](mobile-validation.md).

## Project configuration

Localization registration, a unit-test target, a shared scheme, and the approved
iOS-only launch-screen plist were added to project configuration. The existing app bundle identifier, signing,
deployment targets, and supported platforms were preserved. The new test bundle
has its own identifier. A pre-existing user workspace-state change was left alone.

## Verification and remaining acceptance checks

The test suite covers first-launch defaults, stored-value recovery, preference
persistence, and compiled translations in both languages. Debug and Release
compilation was checked for macOS and iOS Simulator. Local verification disables
signing through command-line options without modifying saved signing settings.
All three tests passed on macOS, an iPhone 18 Pro simulator, and an iPad Pro
11-inch (M5) simulator. Simulator test execution does not replace visual and
accessibility acceptance checks on those devices.

macOS interaction checks covered live language changes including window titles,
Light/Dark appearance, System selection, independent navigation in two windows,
and shared preference updates between them.

The subsequent [mobile validation](mobile-validation.md) covers phone and tablet
rotation, localization, appearance, launch artwork, enlarged text, VoiceOver
focus, and iPad keyboard navigation. Narrow iPad app-window resizing remains
unverified because the simulator did not respond to the resize gestures. Full
spoken VoiceOver and physical-device checks remain outstanding.

Distribution signing and bundle availability remain unverified. The app icon
was copied from `emsysApp`, with macOS sizes derived from its 1024-pixel source.
The original artwork and transparency are preserved; App Store icon validation
remains part of release preparation.

No later milestone should start without approval.
