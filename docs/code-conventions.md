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

Name a file after its primary type or a clearly related group of types. Put
screens with their feature, application
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

## MVVM and repositories

Organize larger features into `Models`, `Views`, and `ViewModels` within the
feature. Place feature-owned repositories and data adapters together when they
need their own group. Keep small features easy to navigate and keep supporting
types beside the primary type when they share a responsibility. For example, a
small invoice pickup reference can live with the invoice data that uses it.

| Role | Responsibility |
| --- | --- |
| Model | Define business data, its rules, and validation or calculations that can be tested independently of a screen. |
| View | Render screen state, manage local presentation details such as focus, and forward user actions. |
| ViewModel | Expose screen state and coordinate user actions. Name screen-owned observable types `*ViewModel`. Delegate data access and keep transport, SQL, and sync mechanics out of the screen state. |
| Repository | Expose business data operations such as loading invoices or queuing a draft. Coordinate persistence and synchronization through the existing store, API client, and sync code. |

Give a ViewModel an explicit repository dependency. Use an existing store as that
dependency when it already fulfills the repository role. Add a separate
repository when it owns work such as coordinating local and remote data, or
turning a saved draft into a durable queued operation. Avoid forwarding wrappers
and introduce protocols where a real substitution is needed.

For offline-capable features, use GRDB-backed SQLite as the app's operational
source of truth. Keep the business write and outbox insert in one transaction.
Preserve request identity across retries and reconcile server results into SQLite
before reporting confirmation to the UI. Preserve tenant scope and existing
conflict handling when moving these responsibilities.

For example, the invoice ViewModel receives the Save action and asks the
repository to queue the draft. The store commits the invoice and outbox together.
The sync worker sends the queued request and records the server result. The
ViewModel presents the saved, pending, or confirmed state from that data.

## Maintainability review

Before implementation, trace the intended workflow and identify which existing
types and operations can handle it. Before completion, trace the changed
workflow again and review the diff:

- Confirm that each responsibility has a clear owner and the relevant code is
  easy to locate. Keep related declarations together and split files where a
  responsibility merits its own home. Use file and line counts as review signals.
- Check that changed functions and logic blocks follow the comments rule and
  that named steps and multiline control flow make decisions easy to follow.
- Check for duplicate work, per-row database queries, unnecessary network
  requests, and blocking work on the main thread. Measure suspected bottlenecks
  with representative data before adding optimization complexity.
- Protect existing behavior with regression coverage when refactoring a
  workflow, including offline persistence, retry, and recovery where applicable.
- Run the required verification gate. For UI changes, inspect the native layout
  at relevant device sizes, with large text or the keyboard open when applicable,
  and record any checks that were unavailable.

## Readability and efficiency

Use native Swift and SwiftUI APIs where they fit. Keep state at the narrowest
appropriate scope: preferences shared across scenes, navigation owned by each
window. Preserve stable storage keys when renaming Swift symbols.

Prefer explicit error handling and safe fallback values over force unwraps.

Keep blocking file, database, image-processing, and network work off the main
thread. Do not add fake loading delays or speculative caches. Investigate and
measure performance concerns before introducing extra complexity.

## Comments and readable logic

These requirements apply to new and modified production code and tests.

- Add a `///` comment above every new or modified function, initializer, and
  computed property, including private members. Explain what it does and, where
  relevant, its inputs, result, side effects, or failure behavior.
- Add a short `//` comment immediately before each distinct logic block, whether
  it lives in a function, a closure, or a view body. Explain what the block
  accomplishes and why its decisions matter. Cover validation, branching, loops,
  data transformations, state updates, and error and recovery paths. Explain
  business rules and format assumptions where the code relies on them.
- Put each branch and its statements on separate lines. Avoid nested ternaries,
  chained transformations that hide decisions, and inline closures that do
  multiple things. Name intermediate values for what they represent. Keep short
  inline expressions for direct reads or calls that are clear at a glance.
- Keep related steps together so the reader can follow the workflow in order.
  Extract a function only when its responsibility merits a separate name.
  Update comments as logic changes and check the entire diff for missing or
  stale comments and compressed logic before marking the work complete.

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
