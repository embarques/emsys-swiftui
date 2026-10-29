# EMSYS code conventions

## Names describe the application

Use English, UpperCamelCase for types, and lowerCamelCase for properties and
functions. Follow Swift's argument-label conventions. Prefer complete words and
names that explain purpose at the call site.

Name screens after their purpose: `HomeView`, `SettingsView`, and, when those
features exist, `InvoiceListView` and `InvoiceDetailView`. Use `AppRootView` for
application navigation composition. Do not name production types after a
milestone, implementation phase, prototype, or version number.

Use precise property names: `selectedDestination`, `systemImageName`,
`displayName`, and `minimumSidebarWidth`. Avoid generic names such as `data`,
`helper`, or `manager` when a more specific responsibility can be named.

## Organization and responsibilities

Match a type's file name to the type. Put screens with their feature, application
composition in `App`, navigation definitions in `Navigation`, device preferences
in `Preferences`, and shared visual values in `Appearance/AppStyle.swift`.

Use straightforward names such as `AppStyle.Colors`, `AppStyle.Fonts`,
`AppStyle.Spacing`, and `AppStyle.Layout`. Prefer names that explain the code
without requiring design terminology. Keep shared styles limited to visual values. Language resolution, preference
storage, and appearance behavior belong with their corresponding types.
Separate substantial responsibilities; small supporting types may stay together
when separation would make the code harder to follow.

Keep view bodies declarative. Extract a view or function when it has a coherent
responsibility or materially improves readability. Avoid creating abstractions,
protocols, layers, or dependencies for hypothetical future requirements.

## Readability and efficiency

Use native Swift and SwiftUI APIs where they fit. Keep state at the narrowest
appropriate scope: preferences shared across scenes, navigation owned by each
window. Preserve stable storage keys when renaming Swift symbols.

Use comments to explain intent, constraints, or platform behavior rather than
repeat the code. Format long expressions and collections across readable lines.
Prefer explicit error handling and safe fallback values over force unwraps.

Keep blocking file, database, image-processing, and network work off the main
thread. Do not add fake loading delays or speculative caches. Investigate and
measure performance concerns before introducing extra complexity.

## Validation

Name test suites after the behavior or type they verify, such as
`AppPreferencesTests` and `AppLanguageTests`. Test externally observable behavior
and recovery paths rather than duplicating implementation details.

Run relevant tests and build the affected platforms after refactoring. Keep
unrelated user edits and project settings intact.

The owner requires a verification gate between features. Run
`./scripts/verify.sh` after code/dependency changes and fix any failure before
starting the next feature. It intentionally uses the normal Xcode workspace,
pinned package versions and all three Apple targets. Verify the native Xcode
build after dependency/project changes. Keep live/UI acceptance limitations
explicit; never treat fixture tests as proof of an untested user workflow.

## Interface design review

Treat each screen as a designed workflow, not a collection of default controls.
Establish a clear heading, content hierarchy and primary action. Use intentional
spacing, readable line lengths and consistent field, status and error treatments.
Keep the EMSYS identity; references inform composition and care, not copied colors
or unrelated product features. Use native interactions and avoid decorative
complexity that competes with business information.

Adapt composition to available space rather than stretching a phone screen. Check
compact phones, keyboard visibility, larger text, iPad and resizable Mac windows.
Use semantic colors that remain readable in light and dark appearance. Labels must
remain visible, touch targets usable, and state understandable without color alone.
Before marking a visible change complete, inspect the actual rendered screen as
well as running the verification gate. Record missing visual checks explicitly.

## API-backed local fields

Keep API field names and structures for API-backed values stored locally. For
example, the signature is `senderSignature` with `signerName`, `data` (bare
base64) and `contentType` in both SQLite-bound JSON and the sync payload. Name
local-only metadata according to its purpose, separately from API fields. When
aligning existing persistence, preserve old records through compatible decoding
and never rebuild frozen request bytes or mutation identities during migration.
