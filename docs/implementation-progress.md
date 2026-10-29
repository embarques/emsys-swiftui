# EMSYS implementation progress

## Authorization and continuation

Historical checkpoint at approximately 04:25 EDT: usage reached 99%. The former
07:20 continuation has since been removed as instructed below. No milestones
beyond the documented status are complete. Do not consume the account's optional
reset credit without request.

On October 24, 2026, the owner explicitly approved autonomous work on all ten
milestones, starting immediately and resuming after the usage reset. This supersedes
the need to request individual milestone approval. It does not authorize changing
signing or bundle identifiers, publishing, deployment, or production data changes.
Preserve the existing staged and unstaged Apple work; no Apple commits or pushes requested. API work follows its repository requirement for a feature branch and review PR to dev.

The owner clarified on October 25 that 07:20 was a one-time request. Both
`continue-emsys-milestones` and `resume-invoice-redesign-once` were deleted through
automation_update. Continue work now in this chat; do not recreate a recurring
schedule unless the owner explicitly requests one. Save concrete progress before
stopping, but do not claim future unattended execution is scheduled.

### October 25 authorization renewed

The owner explicitly instructed this chat to complete all remaining milestones,
one at a time, test each increment and work independently on all tasks. This
continues the implementation authorization without individual milestone approval.
It does not authorize publishing, production mutations, changing signing or
identifiers, entering unknown credentials or consuming the optional reset credit.
Keep unavailable physical-device/printing/live-account checks explicit and continue
independent work. The owner's staged and unstaged files must remain intact.

## References

- Apple project: `/Users/hectorm/Workspace/xcode/emsys-swiftui`.
- Current portal: `/Users/hectorm/Workspace/emsys-portal`.
- Current Go API: `/Users/hectorm/Workspace/emsys-api`.
- Legacy native reference: `/Users/hectorm/Workspace/xcode/emsysApp`.
- Legacy authentication is superseded by the portal; do not copy it.
- Firebase client configuration is present at `EMSYS/Resources/GoogleService-Info.plist`.
  It matches the current bundle and portal Firebase project; it is ignored and
  untracked. Never print its contents or stage it.

## Milestone status

1. Apple foundation implemented. Tests passed on macOS/iPhone/iPad; see
   `milestone-1.md` and `mobile-validation.md` for evidence and remaining human checks.
2. Selective legacy review completed; see `legacy-apple-review.md` for source
   evidence and modernization decisions.
3. Current web/API review in progress. Invoice routes expose list/search/detail/
   create/update/delete. Delivery completion has a request identifier and dedicated
   workflow; do not assume all mutations share its replay safety.
4. Authentication implementation in progress. Added Firebase 13.1.1 Auth/Firestore,
   sign-in UI, secure SDK restoration, tenant/API authorization bootstrap, logout,
   localized recoverable errors, and session-scoped GET transport. Confirmed portal Firebase email/password,
   ID token Bearer header, company claim with optional Firestore profile fallback,
   `X-Company-ID`, API permissions, and a single 401 refresh/retry; never refresh
   merely for 403. No legacy App-Id/Api-Key headers. Ten tests passed on macOS
   including seven transport regression cases at that checkpoint; current suite
   and platform results are recorded below.
   macOS Keychain Sharing approved and configured; signed runtime validation remains pending. No live account testing performed. API root defaults to the
   portal's current HTTPS root; optional `EMSYSAPIBaseURL` Info value overrides it.
5. GRDB invoice downloads and initial offline line-item description editing are
   implemented, with scoped storage, atomic outbox, immutable retries, conditional
   uploads and explicit conflict review. See `invoice-persistence.md` and the latest
   checkpoint below. API PR #328 is merged into dev; deployment is unverified. Creation now has a five-step wizard, full customer-write snapshots, planned
   payments/discounts, local signature review, durable journal/invoice requests
   and attachment uploads. Live creation acceptance, broader editing and
   incremental deletion handling remain incomplete.
6. Added adaptive `SignatureCaptureView` and normalized Codable `SignatureDrawing`
   with background PNG export and current API image limits. Two export/rejection
   tests passed on macOS. Sender capture is bound to creation review and its durable submission.
   Creation attachments have a separate durable upload queue; delivery capture
   remains pending. Server-generated PDFs can be downloaded, saved,
   previewed, shared and printed natively. Direct printing also renders PDFs locally
   from cached invoice/company settings, including supported pending item edits;
   historical private signatures remain absent. See offline-invoice-printing.md.
   Signed/live/physical and redesigned-screen visual acceptance remain pending.
7. Pickup directory, offline cached viewing/contact and connected completion are implemented. Pickup-to-invoice creation is implemented for ordinary invoice creators, pending companion API rollout. Assigned-driver invoice creation, offline pickup mutation safety and delivery workflows remain incomplete.
8. Android foundation implemented on `codex/android-foundation`; native adaptive navigation, es-DO/en, persistent appearance and scoped Room storage. Four JVM tests and six device tests passed at phone/tablet window sizes. Firebase config and parity remain pending.
9. Android parity pending further Apple business implementation and Android Firebase configuration.
10. Stabilization incremental; final cross-platform checks remain.

## Latest validation

### Connectivity controls requested by owner

- Added top-level localized offline banner, Network framework path monitoring,
  shared synchronization progress/error status and a manual Sync now toolbar
  action. Active windows automatically refresh invoice downloads on reconnection,
  foregrounding and authentication. See `synchronization-status.md`.
- Invoice synchronization refreshes first/saved pages and saved detail copies,
  persists them to SQLite, and reloads visible records. No mutation replay or
  attachment uploads are claimed. Token refresh is no longer required merely to
  open local invoice storage during an already-authorized session.
- Added four regression tests for synchronization lifecycle/concurrency/session
  boundaries/cancellation and fixture-based page/detail refresh. Initial macOS
  and final macOS/iPadOS runs passed all 28 tests with zero failures. Logs:
  `/private/tmp/emsys-final-sync-mac-tests.log` and
  `/private/tmp/emsys-final-sync-ios-tests.log`. `git diff --check` passed.
- Owner explicitly rejected a client-defined offline time cutoff; API permissions
  remain authoritative. No 72-hour rule should be added. At this checkpoint offline relaunch was incomplete; later Keychain-backed restoration is recorded below.

### October 24, 07:20 continuation

- Usage reset confirmed available without consuming the optional reset credit.
- Fixed list refresh erasing richer cached invoice detail responses. Added an
  additive migration preserving old payloads and a regression covering reopen,
  separate page/detail snapshots and authoritative empty-item replacement.
- Bounded the optional Firestore company lookup to five seconds, matching the
  portal. Tests cover success, missing profile, SDK failure and a late callback
  after timeout. No live Firebase requests were made by these tests.
- macOS: final 24-test suite passed with zero failures in
  `/private/tmp/emsys-report-contract-tests.log`.
- iPadOS: final 24-test suite passed with zero failures in
  `/private/tmp/emsys-report-ios-tests.log`.
- `git diff --check` passed; Firebase plist remains ignored. Existing signing,
  identifiers and pending owner decisions were preserved. No live API calls,
  commits or deployments occurred during this continuation.
- Current report contract review documented in `native-document-contracts.md`:
  generation returns an expiring URL in JSON, not PDF bytes. Private selected
  signatures remain server-side; do not invent an equivalent offline renderer
  from the current partial invoice projection.
- Added authenticated JSON POST transport reusing session isolation, the one-401
  refresh limit and redirect restrictions. Exact body preservation across refresh
  passed its regression test. Added typed invoice report selection/request/result
  models with the API's snake-case lookup field and es/en language mapping.
  No report generation was sent to a live API. Report UI/download/storage remain
  pending; this does not complete Milestone 6.
- Portal `.env.local` contains the three Playwright credential/company keys;
  presence alone was checked, without printing values. A safe native test API
  environment is still unconfirmed, so no live login or production API test ran.
- At this earlier checkpoint the signing/API decisions were pending. The owner subsequently approved them as recorded under Open inputs.

### Earlier checkpoint

- macOS: 18 tests passed, zero failures, including transport/session boundaries,
  cached-page failure recovery, persistence reopen/isolation and signature export.
  Final privacy/input-bound adjustment also passed all 18 tests in
  `/private/tmp/emsys-final-mac-tests.log`.
- iPad simulator: all 18 tests passed with zero failures, including GRDB and
  signature export. Log `/private/tmp/emsys-current-ios-tests.log`.
- Final macOS and iOS Simulator Release builds passed after the profile-cache
  adjustment. Logs `/private/tmp/emsys-current-mac-release.log` and
  `/private/tmp/emsys-current-ios-release.log`. Saved signing settings unchanged.
- Final iPhone simulator regression run passed all 18 tests with zero failures:
  `/private/tmp/emsys-final-iphone-tests.log`.
- Dependency resolution completed for Firebase 13.1.1 and GRDB 7.11.1; lockfile
  is in Xcode workspace shared SwiftPM data.
- `git diff --check` passed. Firebase plist remains ignored/untracked.
- Native UI review was attempted through computer-use tools but the Mac is locked.
  Do not claim visual verification of new login/invoice/signature screens.
- No live account or production API validation was performed. No commits,
  publishing, deployments, signing identity or bundle-ID changes were made.

## Open inputs

- Android repository found at `/Users/hectorm/Workspace/android/emsys-kotlin`;
  native Compose starter, package `com.embarqueros.emsys`, SDK 37/minimum 26.
  Foundation implemented after the corresponding Apple behavior; see Android docs/implementation-progress.md.
- Owner asked for a safe development API and test-account configuration location;
  no passwords requested. Source inspection and isolated tests may continue.
- API instructions identify `.env.codex`, `APP_ENV=codex`, and database
  `emsys_codex_test` for integration tests. Never execute against production.
- Owner approved macOS Firebase Keychain Sharing while preserving team, signing identity and bundle ID. Configured the macOS-only entitlement and capability; unsigned Mac build passed (`/private/tmp/emsys-keychain-build.log`). Signed runtime restoration is pending.
- Owner approved required API synchronization changes as separate routes within their existing endpoint groups; existing portal routes must remain compatible.
- Owner approved using existing environment configuration, but those files point at remote services. Write integration tests use a new disposable loopback MongoDB replica set, never production.
- Owner approved Android implementation with Firebase Android configuration left pending; do not block independent work on that file.
- Offline time policy resolved by owner: no arbitrary client-defined cutoff;
  server permissions apply at synchronization. Durable offline session restoration is implemented for recognized connection failures; signed-runtime validation remains pending. Do not request the old 72-hour proposal again.

## Next work

Continue remaining authorized milestones without asking for the already granted
approvals. The initial offline description-editing slice is implemented; final
platform results are recorded in the latest checkpoint. Broader invoice creation
must follow the current portal: skipping payment keeps an open Cuadre reference
without a separate journal; an actual payment registration precedes pending-invoice
completion and its confirmed results must be persisted before advancing. Field operations need scoped local persistence,
photo dependencies and existing atomic delivery completion semantics. Do not
invent pickup replay/versioning or deletion contracts.

API PR #328 is merged into dev; deployment remains unverified. Never substitute
the old unconditional PUT.
Android foundation is tested, but authentication and feature parity are pending;
its Firebase plist-equivalent JSON may remain pending as the owner authorized.
Mac signed-session validation, live safe-environment checks, visual/accessibility
review and physical printing remain acceptance work. The Mac was locked at the
latest UI inspection; continue independent work without asking the absent owner
to unlock it. Existing test environment files point at remote services; use only
disposable local test data for writes. Preserve all user changes and identities.

## Approved API synchronization implementation in progress

- API feature branch `codex/invoice-sync-create` adds only `POST /invoices/sync/create` inside the invoice group. Existing invoice creation stays compatible.
- User/tenant-scoped durable UUID receipt commits atomically with invoice creation, automatic numbering and dependent records. Replays preserve identity; mismatched payloads and deleted results return conflicts. No update versioning/change feed is claimed.
- Disposable loopback MongoDB integration passed concurrent replay, failed-transaction rollback, sequence preservation and deleted-result checks. HTTP tests passed permission denial, discount denial, body limits and conflict mapping. Full Go tests and vet passed. Swagger/Scalar generation and contract tests passed; race-enabled integration tests passed. API commit `2033da3`, review PR https://github.com/embarques/emsys-api/pull/328 targets dev; not merged or deployed. The disposable test container was removed after validation.
- Contract details are in the API repository `docs/invoice-sync-create.md`. Native outbox wiring is not implemented yet. No API deployment or production writes occurred.

## Durable offline restoration checkpoint

- Added token-free Keychain snapshots of API-verified user/company/grants, scoped by Firebase project, API root and UID. Only recognized connection failures can restore them; explicit denials and tenant changes invalidate the previous context. No client-defined time cutoff. Logout deletes the snapshot before SDK logout.
- Reconnect, foreground and manual sync revalidate restored contexts. Existing local invoice data remains intact; API requests continue to enforce server permissions.
- Added three regression tests covering Codable round-trip and scope/version/active checks plus strict failure classification. Final macOS suite passed 31 tests with zero failures (`/private/tmp/emsys-offline-session-mac-tests.log`). iPadOS suite also passed all 31 tests (`/private/tmp/emsys-offline-session-ios-tests.log`). The final Data Protection Keychain query adjustment also passed the later 34-test Mac/iPad document runs.
- Snapshot tests do not prove actual Keychain/Firebase restoration on a signed device. Startup currently waits for the first network attempt to fail; these runtime acceptance checks remain pending.

## Native document workflow checkpoint

- Added explicit sender/receipt metadata selection using the current API print contract, report generation, a credential-free HTTPS download stream with resource bounds, and native PDFKit preview/share/print controls.
- Saved PDF bytes and report/selection metadata commit atomically to the existing user/tenant SQLite partition. The latest saved PDF reopens offline; failures preserve it. No capability URL tokens or server filenames are persisted as paths.
- macOS and iPad Simulator final suites passed 34 tests with zero failures. Logs: `/private/tmp/emsys-document-mac-tests.log`, `/private/tmp/emsys-document-ios-tests.log`. Diff checks passed. Existing identifiers/team/signing identity remain intact.
- See native-document-contracts.md for limits. Live report generation, visual checks, physical printing and signed-device auth remain unverified. Offline generation of a new authoritative invoice PDF is not claimed.
- Next independent work: Android native foundation from the clean starter, preserving identity/targets and leaving Firebase Android configuration pending. Apple outbox/edit concurrency/field operations remain unfinished.

## Android foundation validation checkpoint

- Implemented native Compose navigation bar/rail, Spanish/English per-app language support, asynchronous DataStore appearance preferences and readable adaptive layouts. Existing EMSYS logo is used in the adaptive icon.
- Added tenant/user/API-environment scoped Room persistence, bounded transactional snapshot downloads, detail preservation and a matching case-insensitive index. No credentials are stored there.
- Four JVM tests, six instrumented device tests, debug assembly and lint passed on API 37, including a second run at tablet window dimensions. Logs: `/private/tmp/emsys-android-final-tests.log`, `/private/tmp/emsys-android-tablet-tests.log`. Lint has existing dependency/unused-resource notices, no errors.
- Android repo branch `codex/android-foundation`, changes remain local. The separate read-only emulator-5580 was stopped after tests; existing emulator-5554 was not altered. No Firebase configuration or business writes used.
- Authentication/parity, older-API/physical-device acceptance and remaining Apple outbox/field workflows are still pending. Continue with safe invoice mutation and source contract work.

## Earlier invoice mutation review (superseded by evening source trace)

Portal source confirmed the normal creation wizard registers INITIAL-PAYMENT in
an open Cuadre first, even for zero payment, then completes that server-issued
pending invoice using registered number/totals. Preserve this ordering and the
existing journal idempotency key. Do not expose a simplified native creation form
that bypasses it. Relevant portal sources: register-invoice-zero-payment.ts,
invoice-form-workspace.tsx and invoice-payment-transaction-form.tsx.

Planned approved API increment: separate sync invoice snapshot/conditional update
routes, durable request UUID replay, and stale-revision conflicts. Reuse current
business updates transactionally; keep portal PUT behavior compatible. Revision
reads must exclude private signature image bytes. This increment is implemented and tested in the API PR; native consumption is pending. Safe create-route PR #328 remains unmerged/undeployed.

## Conditional invoice sync API checkpoint

- API commit `804d3b1` extends the existing review branch/PR with separate GET and PUT `/invoices/sync/{id}` routes. Existing portal routes remain compatible. Native consumption/outbox is not implemented yet.
- Read transactions return a document plus opaque revision. The revision covers the owned invoice and line items, not unrelated directory counters. Query projections exclude private images/personal receipt IDs. Sender stamping adds a private image digest for same-millisecond change detection.
- Updates atomically compare revisions, apply existing business rules and persist a user/tenant UUID receipt. Exact committed replay acknowledges without rewriting; stale/payload/deleted-result conflicts preserve work. Server-only invoice and line-item bridge identities are retained on this new route.
- Race-enabled isolated tests passed concurrent identical replay, competing updates, ordinary-writer staleness, tenant/deleted-result protection, financial/void/signature preservation, unchanged directory-counter revisions and Cuadre zero-payment registration/completion with one journal.
- Final synthetic revision query: 3,223 bytes projected BSON versus 301,185 bytes original invoice; about 9 ms for the local snapshot at that run. Not a production latency claim. Logs `/private/tmp/emsys-api-sync-all-race.log`.
- Required Go formatting, vet, full tests and Swagger/served Scalar contract checks passed. Logs `/private/tmp/emsys-api-all-tests.log`, `/private/tmp/emsys-api-vet.log`, `/private/tmp/emsys-api-swagger.log`. API docs `invoice-sync-create.md` and `invoice-sync-update.md` describe exact boundaries. No incremental feed or ordinary PUT version enforcement is claimed.
- PR #328 is not merged or deployed. Do not enable an unsafe fallback from conditional mutations to old PUT when the new API is unavailable. The disposable Mongo container was removed after final validation.

## Apple offline invoice editing checkpoint

- Added complete public write-document preservation separate from the read model,
  opaque revision snapshots and exact Decimal/unknown-field retention. The initial
  editor changes existing line-item human descriptions only, matching the portal's
  free-text/catalog-reference behavior. No client financial rules were invented.
- Local projection and immutable UUID/revision/request bytes commit atomically.
  Reopen, lost-response retry, cross-window download races and SQLite transaction
  rollback are covered. A frozen editor baseline cannot silently adopt newer
  server changes. API environments are isolated without moving the existing
  production cache.
- Uploads only use the new conditional invoice route. Stale/invalid edits require
  review; permission/route failures preserve pending work. Review overlays only
  explicit description changes onto a chosen latest snapshot with a new UUID,
  or confirms using the server copy. No unconditional PUT fallback.
- Pending edit list, description editor and conflict comparison screens are
  connected to invoice navigation and localized in es-DO/en. Saving requests an
  upload-only run; manual/reconnect/foreground requests include downloads. Shared
  run tickets preserve requests arriving while another synchronization runs.
- Offline-session revalidation preserves the current authorized navigation while
  checking the same context. Tenant changes/denials invalidate it; no arbitrary
  offline cutoff was introduced. PDF screens recheck print scope and warn that
  server-generated copies do not automatically contain unsynchronized edits.
- macOS and iPad suites passed all 46 tests before the final document-screen
  scope/formatting changes. Logs `/private/tmp/emsys-invoice-outbox-mac-tests.log`
  and `/private/tmp/emsys-invoice-outbox-ios-tests.log`. Final verification is in
  progress; record its result below. Native visual inspection remains blocked by
  the locked Mac. No production writes, Apple commits or deployments occurred.
- Next: finish final verification and implement remaining creation/field-operation
  slices from current contracts, then Android parity. Cuadre-dependent creation,
  attachments, retention, live/signed acceptance and milestones 7/9/10 remain open.

### Final offline-edit validation update

- Final macOS and iPad Simulator runs passed all 47 tests with zero failures after
  the document guards, editor access-scope presentation and pagination migration.
  Logs `/private/tmp/emsys-invoice-outbox-final-mac-tests.log` and
  `/private/tmp/emsys-invoice-outbox-final-ios-tests.log`.
- Added an additive case-insensitive invoice-number index matching list order;
  EXPLAIN QUERY PLAN confirms pagination uses that index without a temporary sort.
- iPhone final regression run also passed all 47 tests with zero failures:
  `/private/tmp/emsys-invoice-outbox-final-iphone-tests.log`.
- Mac Release build passed (`/private/tmp/emsys-invoice-outbox-release-mac.log`).
  iOS Simulator Release build also passed (`/private/tmp/emsys-invoice-outbox-release-ios.log`).
- Updated README, invoice persistence, synchronization and API contract docs to
  reflect the current initial mutation scope and undeployed API dependency.

### Next creation safety dependency

Final journal tracing found a concrete gap: the portal builder does not send the
supported idempotencyKey, and ordinary journal deletion can remove both an empty pending
INITIAL-PAYMENT invoice and the journal carrying its key. A lost-response replay
then loses that evidence. Older comments incorrectly say initial entries cannot
be deleted; the lifecycle code is authoritative. Changed-payload fingerprinting
is absent as well. Do not claim the earlier successful synthetic keyed replay
fixture covers these cases. See api-mobile-contracts.md for the exact evidence
and proposed separate journal sync route. This is authorized under the owner's
existing endpoint-group approval; it needs isolated regression tests before
native registration/payment auto-replay. No journal changes made yet.

## Journal retry protection checkpoint

- A disposable loopback MongoDB probe reproduced the ordinary endpoint gap:
  deleting a registration journal and retrying its same key created a different
  journal and automatically numbered invoice. Nonempty sender snapshots can leave
  the original pending invoice intact; empty pending stubs can be deleted too.
  Log `/private/tmp/emsys-journal-deletion-retry-probe.log`; temporary probe source
  is saved only at `/private/tmp/emsys-journal-retry-probe_test.go`.
- Implemented separate POST `/journals/sync` in the existing journal group with
  journal-create permission, 3 MiB body limit and existing result envelope. It
  commits durable user/tenant receipt, recognized-payload hash and original journal
  identity with the existing posting transaction. Portal POST stays compatible.
- Identical/concurrent replay posts once; changed payload and deleted journal
  conflict. Failed posting rolls back receipt and invoice numbering. Replay after
  statement closure returns the committed result/current summary without reposting.
- Unit/HTTP checks and race-enabled isolated transactions passed, including
  tenant/user scope, both retained/deleted pending stubs, body limits and permissions.
  Logs `/private/tmp/emsys-journal-sync-unit.log`,
  `/private/tmp/emsys-journal-sync-integration.log`. Swagger regeneration and served
  Scalar schema/security checks passed (`/private/tmp/emsys-journal-sync-swagger.log`).
- Full formatting, vet and tests passed. Final combined race-enabled invoice and
  journal transaction tests passed (`/private/tmp/emsys-combined-sync-integration.log`),
  including a deleted linked registration whose journal remains. Full logs:
  `/private/tmp/emsys-journal-sync-all-tests.log`, `/private/tmp/emsys-journal-sync-vet.log`.
- API commit `fc00169` is pushed on the existing review branch and PR #328, now
  titled “Add retry-safe invoice and journal synchronization routes.” It is not
  merged/deployed. No native creation/payment queue uses the route yet. Do not
  fall back to ordinary POST.
- Both disposable journal probe/test containers were removed after validation.
  No remote database/environment-file connection was used. No Apple/Android
  commits or pushes were made; user staged/unstaged work remains preserved.

### Next continuation priorities

1. Read this checkpoint, conventions and source contracts before editing. API PR
   #328 is review-only; do not merge or deploy without a user request.
2. Extend the local drafts into native submission. Skip-payment uses the open
   Cuadre reference without separately posting a zero journal; recorded payments
   need the journal-registration/completion outbox. Use the separate sync routes.
   Persist every UUID,
   frozen payload and confirmed step identity before advancing. Never recreate a
   deleted registration, bypass Cuadre or infer client financial rules.
3. Continue actual pickup/delivery/photo/payment/retention workflows from portal
   and API, followed by Android parity. Android Firebase JSON can remain pending.
4. Signed/live and visual acceptance remain pending; Mac is locked. Preserve
   identities/signing/team, user edits and ignored Firebase config. No production
   writes. Keep documenting precise implemented scope rather than marking all
   milestones complete. The authorized scheduled continuation remains in place.

### Usage checkpoint before scheduled continuation

Current usage reached 96% of the five-hour window. All current source changes are
saved. API working tree is clean after commit/push fc00169 and PR #328 update.
Apple source/docs remain local with user changes preserved. Firebase plist is
still ignored; diff checks pass. Both Apple Release builds and all three 47-test
platform runs passed. No test database/container remains from this increment.
The existing daily 07:20 local continuation is confirmed ACTIVE. Do not consume
the optional account reset credit. Resume the remaining milestones from the
priorities above; the overall ten-milestone task is not complete.

## October 24 evening — drafts and required verification gate

- Owner explicitly requires implemented work to be verified before starting the
  next feature. Added this as a mandatory rule in AGENTS.md and code conventions.
  `scripts/verify.sh` uses normal Xcode DerivedData, pinned package resolution,
  eligible simulator discovery, all Apple platform test runs, both Release builds
  and own-source compiler-warning checks. It stops at the first failure.
- Reproduced the owner's missing GRDB/FirebaseAuth/FirebaseFirestore products in
  the open Xcode issue navigator. Prior /private/tmp build success did not prove
  the normal Xcode workspace worked. Resolved its missing checkouts at the locked
  versions and invoked Resolve Package Versions in Xcode. Native compilation
  moved past those errors; final native status verification is in progress.
- That native build exposed four session-snapshot actor-isolation warnings. Pure
  Codable/Sendable session values are now explicitly nonisolated. Added an actual
  detached-task encoding/validation regression. Removed unnecessary unavailable
  Sendable conformances from URLProtocol test stubs.
- Four verifier infrastructure tests passed, including simulated package failure
  stopping before any later build/test and rejection of own app/test warnings.
- Before the package-failure report, added local invoice draft list/editor/save/
  confirmed delete with raw incomplete input preservation, date-only semantics,
  separate metadata pagination and scoped SQLite storage. Stale window writes or
  deletes cannot replace newer work; explicit save-as-copy preserves both forms.
  Drafts neither create invoices nor record payment, reserve numbers or upload.
  The initial Mac/iPad suites passed 54 tests; normal-workspace full verification
  with the additional session regression is now running. No final claim yet.
- Parked the unfinished, unwired pickup store/read model/helper at
  /private/tmp/emsys-pickup-work-in-progress. They are NOT active production sources.
  InvoiceStore partition setup was restored. Do not resume that feature until the
  required verification gate and native Xcode build pass.
- Current portal source has changed: skipPaymentAndContinue sets registration=null
  and paymentSkipped=true with an open Cuadre ID; it does not post a zero journal.
  A recorded payment still has a journal/pending-invoice completion dependency.
  Follow these two paths rather than the older blanket zero-registration notes.
  No native submission/payment queue is wired yet. Update API creation docs when
  making the next authorized API increment; do not copy their older zero-payment
  narrative into the client.
- No signing, bundle ID, deployment target or saved project configuration changed
  for this fix. No production writes, dependency upgrades or cache resets used.

### Verification gate recovery in progress

The first normal-workspace gate ran all 55 Mac tests successfully, then correctly
failed on an unused Bool result warning in SynchronizationStateTests and stopped
before iPhone/iPad/Release checks. The test now asserts that the run actually
started. The rerun passed Mac tests and own-source diagnostics and is continuing
through iPhone/iPad/Release. Do not report the full gate passed until it finishes.
First failing gate logs: /var/folders/9t/rhbdvkt12v9bmyvfbvq9r18w0000gn/T/emsys-verification.5WxzsE.
Rerun logs: /var/folders/9t/rhbdvkt12v9bmyvfbvq9r18w0000gn/T/emsys-verification.TLDU4j.

### Final normal-workspace verification result

- The full `./scripts/verify.sh` gate PASSED. All 55 XCTest cases passed with zero
  failures separately on macOS, iPhone and iPad. Both macOS and iOS Simulator
  Release builds passed. Own app/test compiler diagnostics are clean.
- Pinned package resolution, eligible destination checks and diff validation also
  passed. Firebase remains 13.1.1 and GRDB remains 7.11.1. Firebase plist stays
  ignored. No compiled source/config changed while this gate was running.
- Final logs: /var/folders/9t/rhbdvkt12v9bmyvfbvq9r18w0000gn/T/emsys-verification.TLDU4j.
  Overall runner transcript: /private/tmp/emsys-verification-run.log.
- Four verifier infrastructure tests passed. An actual first run stopped on an
  own-source warning before later platforms, proving the gate is enforced rather
  than merely reporting a successful test count.
- Rebuilt from the open Xcode window and inspected its latest native build report:
  “Success in Build succeeded”, October 24 at 9:14 PM, 22.7 seconds, “No issues”.
  The issue navigator was empty with the errors-only filter OFF and no text filter.
  The owner's original missing package/module errors and four actor warnings are
  resolved in that workspace, not just an independent DerivedData folder.
- The verification requirement now applies before another feature. This closes
  the reported build/checking issue, not all ten product milestones. Live Firebase
  workflows, signed Keychain restoration, draft-screen human acceptance, physical
  printing and other pending product work remain explicitly unverified.
- Resume planned feature work only from this verified checkpoint and rerun the
  gate after every code/dependency increment. Pickup work remains parked outside
  the application; no new feature was advanced while these checks were failing.

### Login design revision — in progress

Owner requested a substantially more deliberate interface, especially login, and
supplied a visual reference for quality/composition rather than copied branding.
Paused pickup work. Replaced the generic grouped login form with an EMSYS welcome
area and focused sign-in panel; compact stacked layout and wide two-column layout,
visible field labels, keyboard focus progression and inline loading/error states.
Added es-DO/en welcome and action copy. Existing authentication flow remains.
Documented interface design review expectations in code conventions.

Verification is running through the mandatory normal-workspace gate. The initial
sandboxed attempt could not access Swift package caches/CoreSimulator; reran with
approved build-service access. Do not report this revision complete until the gate
and relevant rendered checks are done. No signing/project settings changed.

### Login revision verification checkpoint

The full mandatory gate PASSED for the login revision: 55 XCTest cases on each
of Mac/iPhone/iPad, Mac and iOS Simulator Release, pinned packages, own-source
compiler diagnostics and diff checks. Logs:
/var/folders/9t/rhbdvkt12v9bmyvfbvq9r18w0000gn/T/emsys-verification.Jml2z4.

Rendered Mac dark appearance inspected in a short window (scroll reaches password
and primary action) and a maximized window (bounded two-column composition).
Window size restored. No credentials entered. Phone visual review is next; iPad,
light appearance, large accessibility text and actual signed login remain pending
acceptance checks. Do not confuse automated platform tests with these UI checks.

The open Xcode workspace rebuilt and ran on iPhone 17. Device Hub shows an
existing signed-in session (Home with Sign Out). Preserved that session rather
than signing the owner out for a screenshot. Phone login visual/keyboard review
therefore remains pending on a separate signed-out simulator or preview; no live
credentials or business records were touched. The Mac login rendering was checked
without credentials. Continue design review before treating visual acceptance as
complete; all automated platform checks above passed.

### October 25 invoice detail redesign — in progress

Owner approved implementing the final visual concept: prominent balance, stacked
sender/recipient names, item description above a row with quantity left and amount
right, and printer/edit icons at the upper right. Replaced the grouped Form with a
bounded native scrolling layout, semantic appearance colors, selectable customer
names, two-decimal monetary values without guessing currency, and accessible
section headings. Existing edit authorization, pending-edit recovery, local print
preparation, sheet reload and synchronization hooks remain intact. Manual refresh
is available through an overflow menu and pull to refresh. No business/API contract
or persistence changes were made.

Verification is NOT complete. The sandboxed gate failed on normal Xcode cache and
simulator permissions. The approved unsandboxed gate passed package resolution,
destination discovery and macOS tests, then hit a build database lock from another
active ./scripts/verify.sh run in this same workspace. Do not use a temporary build
folder or alter signing to avoid the lock. Let the existing build finish and rerun
the full gate. Failed gate logs: /var/folders/9t/rhbdvkt12v9bmyvfbvq9r18w0000gn/T/emsys-verification.K8rhEN.
Native visual acceptance of the redesigned invoice is still pending.

The existing 07:20 continuation schedule continue-emsys-milestones was found active;
a duplicate one-time schedule was removed. An attempted prompt update to prioritize
this redesign was rejected by automatic approval review because recurring unattended
implementation across all milestones requires clearer direct authorization. Its
original schedule/prompt remains unchanged. This checkpoint supplies actual work
status; it does not claim new milestone acceptance or completed UI validation.

### October 25, 07:20 invoice redesign continuation

The full normal-workspace verification gate PASSED before this scheduled resume.
Logs: /var/folders/9t/rhbdvkt12v9bmyvfbvq9r18w0000gn/T/emsys-verification.1cTIpI.
macOS: 72 tests, zero failures. iPhone: 71 tests, zero failures. iPad: 71 tests,
zero failures. macOS and iOS Simulator Release builds, pinned package resolution,
own-source compiler diagnostics and diff checks all passed. At the 07:20 resume,
no Swift, string catalog, project or resolved-package files had changed since that
passing gate, so no redundant rebuild was needed.

Native visual acceptance is still pending: computer access reported that the Mac
is locked and automatic unlock failed. Requested that the owner unlock it; do not
attempt alternate UI access or call the visual check complete. Physical printing,
light/dark and accessibility-size invoice acceptance remain pending until actually
exercised. No production record was edited during validation.

The one-time resume-invoice-redesign-once follow-up was recreated specifically for
this chat and has now fired. The older broader schedule remains unchanged after
its attempted prompt update was rejected. No new milestone started in this resume.
Recommended next increment: close the remaining native-document integration and
acceptance gaps in Milestone 6 before field operations. Confirm current signature
persistence/document integration against the actual API and existing PDF workflow,
then propose the precise increment; do not infer upload or signing contracts.

### October 25 scheduled continuation — cached print regression

- Read the required specification/conventions/progress and current legacy rows,
  invoice list, portal signature wizard and Go invoice/delivery signature paths.
  Added concrete source/style findings to legacy-apple-review.md and documented
  sender-versus-delivery signature integration boundaries in
  native-signature-workflows.md. Updated native-document-contracts.md with the
  current renderer status so historical “unimplemented” notes are not mistaken
  for the current direct-print behavior.
- Native UI check is still blocked: computer access reports the Mac is locked.
  No alternate UI access/unlock attempt, signed-account action or physical print.
  Invoice-detail visual acceptance remains pending; do not mark it complete.
- Found that both directory/detail localPrintDocument awaited background company
  preparation even with cached company data. Two deterministic isolated tests
  reproduced the delay before the fix (both timed out awaiting cached printing;
  refresh was then released so the suite did not hang). Log:
  /private/tmp/emsys-cached-print-before.log.
- Fixed both entry points to use cached settings immediately. First-use printing
  can still await an already-running preparation if no settings exist. Existing
  cancellation-of-presenting-view preparation coverage remains. No API/signature/
  permission rules, project configuration, signing or identifiers changed.
- Full mandatory verification is running:
  /private/tmp/emsys-cached-print-verification.log. Do not advance to a new feature
  or claim the fix complete until all checks pass. No production data was used.

### Cached-print fix — final verification

The full normal-workspace ./scripts/verify.sh gate PASSED: 74 XCTest cases on
macOS, 73 on iPhone and 73 on iPad, all zero failures; both Release builds passed.
Pinned packages, own-source compiler diagnostics and diff checks passed. Logs:
/var/folders/9t/rhbdvkt12v9bmyvfbvq9r18w0000gn/T/emsys-verification.0um5lN.
The two added regressions now prove saved data prints and persists before the
suspended credential refresh completes. Existing first-use/presenter cancellation
coverage also passed. No live HTTP call was made by these fixtures.

Only this recovered printing behavior and the source-review documentation were
changed in this continuation. No new business feature started during verification.
The Mac remains locked, so actual print presentation, invoice-design appearance,
signed login and physical printer output remain acceptance work. Firebase plist
is still ignored; user work and project identity/signing settings are preserved.
The ten-milestone effort remains incomplete; the existing schedule stays active.
Next: finish native visual acceptance when access is available, then complete the
real customer/assignment/policy draft context needed for sender-signature and
invoice submission, using the documented portal/API contracts. Receiver receipt
capture must follow the separate actual delivery review/completion workflow.

### Invoice redesign — native iPhone acceptance

Owner requested continuation after unlocking the Mac. Built and ran from the
actual open EMSYS.xcodeproj in Xcode on iPhone 17; Xcode reported Running EMSYS
on iPhone 17. Preserved the existing signed-in session. Opened the real saved
INV-26-001436 from Facturas and inspected the rendered dark-mode detail screen:
stacked parties, prominent 10.00 balance, item description above quantity left
and 10.00 amount right, total and upper-right edit/printer actions are visible
without clipping at the current text size. VoiceOver accessibility exposes the
section headings and a combined item description/quantity/amount.

Opened Edit descriptions from the toolbar; original item text appeared and Save
was disabled before any change. Canceled without editing/saving. Opened the printer
toolbar action: native AirPrint options and a one-page US Letter invoice preview
appeared. Canceled without submitting a print job. Physical output is unverified.
This closes the previously locked-Mac acceptance blocker for the normal-size
phone dark-mode invoice detail. Light mode, accessibility sizes and iPad/Mac
invoice rendering remain separate pending checks; the native phone check does not
establish them. No code/configuration changed in this continuation, so the passing
full verification gate remains applicable.

Signature integration remains constrained by the actual creation/delivery
workflows documented in native-signature-workflows.md: name-only local drafts
lack customer identity, policy agreement and assignment/payment review context.
Do not add signature capture to an existing invoice as a shortcut. The next
focused feature proposal is durable real-customer/policy review context in drafts,
followed by sender capture and exact-byte submission recovery once the approved
API route is available. Receiver signatures remain part of delivery acceptance.

### Draft customer identity — implemented and verified automatically

Added existing GET customers/autocomplete consumption, minimal customer/address
snapshots and a scoped SQLite customer cache. Drafts can choose actual sender and
recipient records and explicitly choose an address. Editing a name clears its
customer/address reference. Save validation rejects mismatched names, roles and
addresses; older name-only drafts remain readable. Existing stale-window revision
checks still apply. Search can use downloaded customers without credentials or
network requests; online refresh is permission/session bound, with failed refresh
preserving cached matches and 401/403 hiding the returned choices. No production
customer writes or invoice submissions were introduced.

Six new regression cases passed with the full normal-workspace gate, including
cache reopen/user/tenant/API isolation, literal/accent/address search, malformed
batch rollback, customer/address draft persistence and identity clearing, legacy
draft decoding, actual autocomplete query shape, offline failure and authorization
denial. All Mac/iPhone/iPad tests and both Release builds passed, with clean own-
source diagnostics. Logs: /var/folders/9t/rhbdvkt12v9bmyvfbvq9r18w0000gn/T/emsys-verification.gZj1ev.
The Mac locked again before native customer-picker acceptance; an unlock request
is pending. This feature's UI is not yet visually accepted. No signing or project
settings changed.

### Complete policy review snapshots — implemented and verified automatically

Added exact active-policy text to local draft review and scoped SQLite persistence.
GET invoice-policies/active is paginated: the native downloader fetches pages of
40 until the final short page, rejects duplicate identities/repeated pages,
inactive or malformed policies, and enforces bounded content. Only a fully
validated download replaces the cached snapshot. The server's valid null/empty
set is distinct from an unknown, never-downloaded policy set. Draft save/reopen
retains policy text in the same revision-protected draft payload. Failed refresh
keeps previously saved text. The UI labels this as preview, without agreement,
signature, server acceptance or submission claims. Permission checks follow the
actual invoice-create OR invoice-policy-view middleware.

Five additional regression tests cover all-page retrieval, later-page failure,
repeated-page rejection, unknown/empty/reopen/scope behavior, draft rollback and
permission denial. Full normal-workspace gate passed: 85 Mac tests, 84 iPhone and
84 iPad tests, all zero failures; both Release builds and own-source diagnostics
passed. Logs: /var/folders/9t/rhbdvkt12v9bmyvfbvq9r18w0000gn/T/emsys-verification.ILVagt.
Native customer/policy UI acceptance is still pending the owner's unlock; do not
claim those screens passed from unit tests alone. The earlier invoice detail
and editor/AirPrint presentation checks remain recorded separately.

Verified with GitHub metadata that API PR #328 merged into dev on October 25;
updated the stale native API review accordingly. Deployment is unverified and
must not be inferred from merging. API docs/invoice-sync-create.md still contains
an older blanket zero-payment-registration narrative. Current portal source
invoice-daily-income-step.tsx skipPaymentAndContinue instead preserves the open
Cuadre ID with registration=null/paymentSkipped=true; do not copy the stale text.
The actual registration and explicit-skip paths need separate native queues.

Next increment: preserve actual container, pickup-source/route/employee, payment-
location and Cuadre context in drafts using current portal/API reference data.
Only after full review context and validations exist should sender agreement and
signature capture be enabled. Receiver signatures remain in the actual delivery
review/completion flow. Invoice creation, payment posting, field operations,
retention, Android parity and final live acceptance are not complete.

An attempted update of the older daily continuation schedule was rejected again
by automatic approval review: broad standalone implementation permission does not
establish explicit recurring unattended execution permission. A direct daily
07:20 America/New_York authorization question is pending in this chat. Do not
retry or change scheduling by another mechanism without that answer. Existing
schedule remains unchanged. Owner's code, signing, identity and existing staged
changes were preserved; no commits, deployment or production business writes.

### Daily continuation authorization resolved

The owner replied "try again" to the explicit daily 07:20 America/New_York
continuation request. Retried through automation_update; automatic approval
succeeded. continue-emsys-milestones is ACTIVE and now targets this chat
01a17230-384d-7363-a28e-4506406e7c38 with the authorized remaining milestones,
normal-workspace verification, preservation of user work and quiet/non-actionable
notification behavior. Do not create another duplicate schedule. Disable it when
all authorized work is complete or canceled. Native access is available again;
pending customer/policy visual checks are being retried.


### One-time schedule correction and native draft acceptance

The owner clarified that the 07:20 request was only once and instructed work to
continue now. Deleted both schedules through automation_update. The preceding
"daily continuation authorization resolved" entry is superseded; no recurring
work is scheduled.

Native iPhone dark-mode check: opened a new unsaved draft, searched existing
customers through the authorized GET autocomplete route, selected the sender and
explicitly selected its address. Identity/name/address controls rendered and the
saved-customer hint appeared. No customer or invoice was written to the server.
Scrolled to policy preview, loaded actual active policy text using the read-only
endpoint, and verified the unknown-policy label was replaced by readable policy
content. No agreement or signature was submitted. Began cancel/discard of the
unsaved test draft; verify the final dismissal before reporting that path passed.
Light mode, large text, keyboard and iPad/Mac checks are still pending.

Owner additionally requested reviewing the legacy PDF preview workflow. Inspected
legacy InvoicePreview.swift (printer toggles fullScreenCover), PdfPreviewView.swift
(PdfViewUI plus sharing) and PdfViewUI.swift (PDFKit auto-scaling). Legacy share
uses UIActivityViewController; the supplied version exposes printing through
sharing. New requested behavior uses a dedicated Print button in the viewer.
Changed both invoice print entry points to generate/persist the existing local
PDF, open a PDFKit preview, and print only on explicit viewer action. Removed
automatic native print presentation. Generation is coalesced, can be canceled,
and ignores stale/revoked-session results; print action rechecks authorization.
The preview and printer receive the same saved bytes. Regression coverage added
for byte preservation, duplicate-generation suppression, session revocation,
cancellation/new-preview races and failure/retry. Full verification is running;
do not advance or claim this workflow complete until it passes and native preview
then Print is exercised.

### Preview-first printing — automated verification passed

The full required gate passed for the reviewed legacy-style PDF preview workflow:
all macOS/iPhone/iPad tests, both Release builds, package resolution, own-source
diagnostics and diff checks. Logs:
/var/folders/9t/rhbdvkt12v9bmyvfbvq9r18w0000gn/T/emsys-verification.mnXSSb.
Attempted actual native preview after the gate, but the Mac locked again and
computer access could not unlock it. Therefore preview-first native acceptance
remains pending; do not substitute the earlier immediate-AirPrint check as proof
of this new interaction. Same saved PDF bytes and paper/scale behavior remain.
No physical print job was submitted. Both continuation schedules remain deleted.
Continue the authorized milestones now, retaining the pending native UI checks.

### Draft container identity — verified automatically

Added actual numeric UInt32 container references and read-only GET /containers
lookup with normal name filtering, descending ID pagination, scoped SQLite cache,
explicit selection/clear and draft persistence. Cache reads require no token or
network. Later-page errors preserve earlier choices and retry the same page;
repeated identities are rejected rather than silently mixing unstable pages.
A valid legacy container may have a blank name: preserve its raw name and display
its actual numeric ID rather than inventing a name or rejecting that record.
Invalid numeric identities cannot replace saved draft/cache data. The backend's
canViewContainer/container permission gates lookup; unfinished drafts still save
without a container and remain non-submittable local work.

Final stable-source full gate passed, including the blank-name correction and five
new regression cases. Logs:
/var/folders/9t/rhbdvkt12v9bmyvfbvq9r18w0000gn/T/emsys-verification.oCzlY5.
All platform tests, both Release builds, package/own-source diagnostics/diff passed.
The preceding gate zql02C passed too, but was not used as final evidence because
the compatibility correction occurred while it ran. Native container-picker and
preview-first PDF UI checks remain pending the owner's unlock; do not infer them
from the earlier customer/address/policy screen checks.

Pickup assignment source review confirmed current portal uses vehicle-routes
(dated/recurring assignments) plus nested reusable route crew references, not the
/routes crew list as a substitute. Keep both ObjectID identities separately.
Warehouse/office employee selection also follows active employee, branch-code,
branch-type and job-role rules with the portal's fallback; do not guess them.

### Pickup assignment — final automated verification

Implemented actual route/warehouse/office pickup sources in local drafts. The
route picker downloads /vehicle-routes filtered by routeType=pickup, preserves
the dated/recurring route ObjectID separately from the nested reusable crew ID,
and excludes delivery-branch options as the portal does. Employee lookup caches
only identity, active/job-role and branch metadata; financial employee totals,
contact details and unrelated personnel fields are discarded. Source-specific
role matching and the portal's search-result fallback are preserved. Optional
branch catalog permission is not required merely to select an eligible employee.
Changing source clears incompatible assignments. Draft save validates reference
consistency; old drafts still decode and incomplete assignments remain saveable.
All catalogs and selected snapshots remain user/tenant/API scoped.

Full gate passed after correcting a test-only generic helper declaration:
/var/folders/9t/rhbdvkt12v9bmyvfbvq9r18w0000gn/T/emsys-verification.iXC63Q.
Six added regressions cover separate IDs/reopen/source changes, employee rules,
later-page failure preserving old cache, duplicate catalog rollback, mixed-source
rejection, scope/permission isolation and minimal employee field persistence.
Native assignment-picker acceptance remains pending the owner's unlock.

Cuadre/payment-review context is now in verification. Added optional verified
profile branch data compatibly with old session snapshots, exact branch/date
read-only income-statement search, explicit unknown/missing/closed distinctions,
scoped review persistence and draft reference selection. Payment location remains
separate from the user's Cuadre branch. No payment journal, settlement or invoice
submission is triggered. A test fixture initially assumed URLSession exposed a
POST body as httpBody rather than httpBodyStream; corrected its body capture
without changing production transport or weakening the query assertion. Full gate
rerun is in progress; do not advance until it passes.

### Cuadre verification and final document review

Full verification passed in emsys-verification.rF3wjN: 107 macOS tests and
106 tests each on iPhone and iPad, with macOS and iOS Simulator Release builds.
The legacy invoice preview flow was reviewed directly: InvoicePreview opens
PdfPreviewView, which displays PDFKit content and provides sharing/printing.
The native replacement opens the exact generated PDF before its explicit Print
action. Final review now requires an authorization closure on every print button
and rejects noncanonical API dates. Pickup reference types were separated into
matching filenames under the required conventions. The gate for these final
corrections is running. Native viewer/picker checks remain unavailable: computer
use reports the Mac is locked and cannot unlock it automatically. No actual
printer output, live financial posting or full-milestone completion is claimed.

Final correction gate passed: emsys-verification.mbqeJk. All three Apple test
suites, both Release builds, dependency resolution, compiler diagnostic checks
and whitespace validation passed in the normal Xcode workspace. This completes
the automated gate for this increment; native preview-first acceptance still
requires an unlocked Mac. Remaining milestones are not marked complete.

### Current-build native PDF acceptance

Mac access became available. The initially installed simulator app was stale and
still opened AirPrint directly; rebuilt/reran the open EMSYS Xcode project on
iPhone 17 before accepting the flow. The current build restored the existing
signed-in session, opened saved invoice INV-26-001436, displayed the redesigned
detail with top-right pencil/document and printer icons, and opened the generated
PDF viewer from the printer. The viewer's explicit Print action opened native
print options. Cancel returned to the PDF. No actual job or production business
mutation was sent. iPad/macOS viewer acceptance remains separate.

Next incremental dependency: APIClient can send exact pre-encoded POST bytes for
the existing sync routes without JSON re-encoding. Added fixture regressions for
byte preservation across 401 refresh and unavailable-route failure without any
fallback request. This does not enable invoice/journal uploads; durable creation
validation and queue integration remain unfinished. Full gate is running.

Immutable POST transport gate passed: emsys-verification.BnL9s1. All macOS,
iPhone and iPad tests, both Release builds, dependency resolution, compiler
diagnostic checks and whitespace validation passed. The new tests use synthetic
URLProtocol fixtures only. No live sync write or payment was made.

### Refresh exposed beside overflow

Owner requested frequently used Refresh beside the overflow control. Added a
direct arrow.clockwise toolbar button immediately before the overflow menu in
invoice list and detail, reusing existing refresh behavior and the detail loading
guard. Existing pull-to-refresh remains available. Full gate passed in
emsys-verification.pHCMfv, including all three Apple test suites and both Release
builds. Open Xcode project rebuilt and ran on iPhone 17. Native inspection could
read the initial screen, but navigation clicks repeatedly failed with computer-use
noWindowsAvailable, including after reacquiring the Device Hub window; final
rendered toolbar placement is therefore not visually verified.

### Navigation menu redesign from owner's reference

Owner supplied an invoice-app menu reference as visual inspiration. Implemented
a native adaptive menu with EMSYS branding, Work and Preferences sections, larger
icon-backed destination rows, localized descriptive subtitles and an authenticated
account/branch footer. Existing permission rules still control invoice access.
Phone navigation uses a dedicated menu column; larger devices retain the split
sidebar with independent navigation per window. The reference's subscription,
currency, client, item and report screens were not treated as new EMSYS business
requirements or inserted as nonfunctional menu destinations.

The existing Home, Invoices and Settings destinations retain their content,
refresh/printing controls, authorization, local storage and sync lifecycle. Added
translation checks for all new navigation text. Full gate and native visual
acceptance are in progress.

Navigation verification passed in emsys-verification.mcVkvQ: all macOS/iPhone/
iPad tests, dependency resolution, diagnostic checks and both Release builds.
Open Xcode project rebuilt/ran on iPhone 17. Native dark-mode inspection confirmed
brand header, grouped rows, subtitles and account footer fit at current text size;
Invoices opened, Back returned to the menu, and Settings opened with existing
Spanish/dark preference values. Also confirmed the direct Refresh icon is visible
beside overflow in the invoice list. The restored session initially displayed
Home; returning to its menu showed the new layout. Light-mode/large-type and
iPad/macOS visual acceptance remain unverified. No preferences, live business
records, account credentials or sign-out state were changed during this check.

### Mobile invoice creation wizard — layout and recovery

Owner approved a full creation wizard using the supplied mobile visual reference,
EMSYS colors and current portal/API workflow. Initial increment replaces the long
draft form with Details, Customers, Items, Payment/Cuadre and Review steps, a
progress header, persistent Back/Continue controls, local Save draft at any step,
and a review summary. The current step persists compatibly in existing drafts.
Step validation preserves incomplete drafts while requiring selections before
advancing. Local validated line arithmetic follows portal positive-amount cent
rounding and explicit total overrides. Three new regressions cover arithmetic,
invalid/overflow input and step blocking/reopen recovery. Full gate passed in
emsys-verification.mJFUDQ. This is not complete official creation: payment posting,
policy agreement/signature, documents and durable creation upload remain.

Contract review found CreateWithUser calls UpsertCustomer, which writes email and
IDNumber even when absent in our minimal cached customer snapshot. Native
submission must not send these partial snapshots as a complete customer update.
Resolve this before enabling live creation; no business writes were performed.

Sender-policy confirmation increment: local drafts now preserve a bounded PNG,
explicit policy agreement and the portal's signature-skip choice. SHA-256 of the
reviewed draft (excluding navigation/confirmation metadata) binds them to actual
content. Substantive changes invalidate the old confirmation; navigation does
not. Capture exports away from the main actor and rechecks authorization/content
before publishing. Store validation rejects invalid images and preserves the
existing 3 MiB draft limit. These are local confirmations, not server signedAt or
collectedBy metadata, and no invoice/journal is created by saving them.

Native UI acceptance of the first wizard was not achieved: Xcode's active
destination had changed to the connected physical iPhone, while Device Hub
showed the simulator's old form. The UI tool then explicitly reported that the
user changed Xcode. Avoid contending with the owner's window; do not count the
old simulator form as new-wizard validation. No physical workflow acceptance or
production submission is claimed.

Context-bound signature full gate passed in emsys-verification.JjzKaq, including
all three test suites and both Release builds. Native signature/complete-wizard
acceptance remains separate. Subsequent increment exposes a permission-aware
Create invoice plus button next to Refresh/overflow and uses full-screen wizard
presentation on iOS (a bounded sheet on Mac). Draft reopen uses the same wizard.
Payment location now selects actual branch codes from the existing paginated
branch contract and scoped cache, with duplicate-code elimination and permission
guards. An added regression verifies cached offline choices and denied access.
Final gate for this increment is running. Official creation remains unfinished:
customer full-write snapshot preservation, journal dependency/recovery, documents
and the immutable creation queue must be completed before enabling submission.

Latest wizard-entry/payment-location gate passed in emsys-verification.MWpwMv:
116 macOS tests, 115 each on iPhone/iPad, both Release builds, dependencies,
compiler diagnostics and diff checks. Native launch acceptance is blocked by
current app configuration: built Debug simulator bundle identity differs from
the bundled Firebase BUNDLE_ID. Checked only presence/equality, never printed
configuration secrets. Current identity is owner-controlled; no signing, bundle
identifier or Firebase file was changed to bypass the launch guard. Requested
owner direction through an async question (keep development identity with its
matching configuration versus explicitly restore original EMSYS identity).

Invoice creation is NOT complete. Current functionality is the local five-step
wizard, validation, lookup inputs, step recovery, amounts, policy agreement and
context-bound saved sender PNG. Current final action is explicitly Save draft,
not Create invoice. Required follow-up remains: full existing-customer write
snapshots to prevent clearing fields; permission-aware discount/payment methods,
recorded-payment journal dependency and receipt recovery; document attachment
capture/durable upload; exact immutable invoice creation outbox and outcome UI;
native full-flow acceptance with matching configuration. No live invoice or
journal was submitted. Do not mark this request achieved from the passing gate.

### iPhone retry/sign-out diagnosis

Owner reported Retry and Sign out do nothing on the deployed iPhone. Traced the
configuration guard: Firebase was never initialized for the mismatched bundle,
so Retry repeated the same guard and Sign out had no SDK session to end. Added
explicit missing/mismatched/incomplete installation diagnostics, a Check
configuration action with visible failure result, and hid Sign out until the
auth service exists. Validate options before Firebase initialization and reject
reuse of an unrelated configured Firebase app. Added two no-network regressions.
Full gate passed in emsys-verification.FpPq8h on all Apple targets/Release builds.

Installed/launched only the verified Debug app on iPhone 17 simulator via simctl;
left the physical phone and Xcode destination alone. Native light-mode UI showed
the identity mismatch explanation, no misleading Sign out button, and tapping
Check configuration visibly added “Configuration checked: the problem remains.”
No signing/bundle/Firebase credentials were changed and no live login was tested.
Physical login remains blocked until owner selects intended identity and supplies
matching Firebase options or authorizes restoring the original app identity.
This diagnostics fix does not complete official invoice creation.

### Restore the previously working Firebase identity — October 26

Owner clarified that Firebase had worked and requested correction rather than
being asked to choose a new identity. Compared staged known-working project with
current project and existing Firebase client: original application identity
com.embarqueros.emsys matches that client; the current unstaged app identity had
a .dev.hectorm suffix in Debug and Release. Its origin was not established; prior
notes attributing the identity choice to the owner were an inference and should
not be treated as evidence. Restored only those two identifier values to the
previously working identity as the requested regression correction. Team, signing
settings, Firebase client and credentials were preserved. The earlier async
identity-choice question is obsolete; no new Firebase project is required.

Added packaged-client equality validation to the full gate, after physical-iPhone
SDK compilation. Matching options are necessary for runtime authentication even
when all fixture tests compile/pass. Configuration diagnostics remain useful for
actual invalid installations; they do not replace fixing the package identity.
Full verification is in progress.

The previous missing InvoiceDraftConfirmation report was traced to a stale
physical-iPhone source list. A fresh normal-workspace iPhone SDK build compiled
that file successfully. Extended gate includes the physical-device build and
passed in emsys-verification.xgCC45 before the identity restoration.

### Invoice creation: full customer details and payment intentions — October 26

The owner approved continuing the listed creation work. Selected parties now
retain the full customer-write fields required by CreateWithUser/UpsertCustomer,
including email, IDNumber, typed phones, selected-address location and verification
metadata. Minimal autocomplete projections cannot replace these snapshots.
Snapshots and drafts remain partitioned by API, tenant and user. Tests cover
scoped offline reopen and rejecting an older customer download after selection
changes. Full gate passed: emsys-verification.5wzqG0.

The payment step now follows the portal's explicit skip/record choices, discounts,
method-specific requirements, actual BANK account references and current-branch
open Cuadre review. Local totals represent intended recording, never settled
payment. Cached bank accounts work offline; failed refresh preserves cache, and
authorization denial does not fabricate account choices. Full gate passed:
emsys-verification.ImrwxV.

### Durable invoice and initial payment submission — October 26

The review action now saves the draft and immutable creation operation in one
SQLite transaction. Positive initial payments use POST /journals/sync first;
the confirmed receipt and subsequent invoice request commit before attempting
POST /invoices/sync/create. Skip/zero payment does not create a journal. Server
invoice payment values determine the balance, including uncleared methods.
Number allocation remains server-owned. The sender signature is included only
when its saved review context is current; the server owns collection timestamps.

Journal/invoice UUIDs and exact request bytes persist through connection loss,
termination and reopen. Confirmed payment is never reposted just to retry invoice
creation. Missing synchronization routes, authorization denial and conflicts keep
frozen local work visible for explicit attention/retry; ordinary creation endpoints
are never an unsafe fallback. Active creation drafts cannot be edited/deleted.
Server-confirmed invoice snapshots and completion update atomically. Full normal
workspace gate passed: emsys-verification.LCK5j0 (Mac/iPhone/iPad tests, unsigned
physical iPhone SDK compile, packaged Firebase validation and Release builds).

API route deployment and live invoice/payment creation remain unverified. No
production invoice, journal or payment was created for these tests. A rejected
frozen operation currently supports retry after external correction; it does not
support editing or abandoning a partially posted payment without reconciliation.

### Durable creation attachments — October 26

Reviewed invoice_document handler/service/model and upload_id.go before adding
uploads. The actual API accepts PDF and signature-detected raster images only,
up to 25 MiB per file, despite the portal's broader picker list. Upload requires
invoice/update permission and a confirmed invoice with container and number.
Native Files import supports the API's formats; camera capture and a separate
Photos picker are not part of this increment.

Imported original bytes, SHA-256 metadata and the current draft commit together
in scoped SQLite. The UI explains that adding/removing a file also saves the draft.
No image decoding/recompression or blocking file reads run on MainActor. File
reads are bounded. Queued attachments become uploadable in the same transaction
that records invoice confirmation, preserving the reviewed attachment set.

POST /invoices/:id/documents uses deterministic multipart bytes and the existing
uploadId UUID contract. Authentication refresh preserves the body and tenant;
redirect and session-change protections also apply to uploads. Lost responses
retain upload identity and bytes. Upload failure cannot recreate an invoice or
repost payment. Pending uploads survive reopen and prevent draft cleanup. Draft
copies have independent attachment identities; submitted creations cannot be
copied into another creation through conflict recovery. Pending uploads have a
separate status from confirmed invoice creation.

First attachment increment passed the full gate in emsys-verification.w2mwg6:
132 Mac tests and 131 tests each on iPhone and iPad, physical iPhone SDK build, packaged Firebase
identity validation and Mac/iOS Release builds. Follow-up recovery checks and
native acceptance are in progress.

Native read-only inspection on iPhone 17 confirmed container search, route
refresh/selection and navigation into the customer step. Office employee refresh
failed; this is an unresolved live acceptance check, not covered by fixture tests.
No invoice, journal, payment, signature or attachment was submitted to the server.

### Creation recovery follow-up and native acceptance limits — October 26

Follow-up covers pending-attachment badges/deletion protection, independent file
identities when saving a conflicted draft copy, and refusal to copy a frozen
submission. File import reads bounded chunks to EOF. Selected customer detail
refresh now refreshes displayed public phones/addresses and flags a removed
selected address instead of silently keeping its old write snapshot. Blank label
counts require whole UInt8-sized quantities; explicit labels and surrounding
numeric whitespace use the same validation in preview and submission. The top
save action uses a shorter visible label with its full accessibility label.

Historical API commit 6c973d8 changed employee active from omitempty to always
present. Native decoding now tolerates the older omitted field while excluding
that employee from eligible assignments; omission never grants active status.
A fixture regression covers this compatibility path. The earlier observed office
refresh failure has not been retested with a signed-in rebuilt app and must not
be claimed resolved solely from this compatibility change.

The rebuilt app was installed/launched on the existing iPhone 17 simulator and
visibly opened the normal EMSYS sign-in screen. An async request asks the owner
to enter credentials directly there for protected-screen acceptance. No credential
was copied, Firebase configuration changed, signing changed, or login bypass added.
Earlier read-only route/customer UI observations were on the prior running build;
they do not prove the latest protected creation/payment/attachment screens.

The open Xcode workspace visibly recognizes the new source/test files. Its saved
signing page still reports that com.embarqueros.emsys is unavailable to the selected
Personal Team and has no development profile. The owner explicitly chose to keep
this identity and register it later. Unsigned physical-SDK compilation is distinct
from signed physical-device installation; no project identity/signing workaround
was made. Live posting/upload, route deployment, real printing, latest protected
wizard visuals, larger text/light appearance/iPad/Mac form acceptance remain open.

Final follow-up verification passed in emsys-verification.MLe2tF: 136 macOS
tests and 135 tests each on iPhone/iPad, zero failures; pinned package resolution,
normal-workspace unsigned physical-iPhone SDK build, packaged Firebase identity
validation, macOS Release, iOS Simulator Release and diff check all passed.
No app/test source compiler warnings were accepted. This validates compilation
and fixture recovery behavior, not the outstanding live/native acceptance above.

### Defer operational assignments during phone invoice entry — October 26

Owner clarified that the phone operator does not know the container or pickup
origin/assignment. Removed both selections and their review rows from the shared
creation form. Date alone completes the initial details step. New drafts no longer
require operational assignments; requests omit nil container, pickupSource,
receivedBy, route, pickupEmployee and officeBranch rather than inventing values.
Previously saved selections/frozen operations are preserved. A regression verifies
scoped reopen and exact omission in the immutable creation request.

Attachments on a confirmed invoice without a container now retain their original
bytes in an awaitingContainer state. They are protected from cleanup, display the
reason, and can be retried after a later assignment. Expected waiting does not
report an upload failure. The existing document API still requires a container.

The current API rejected these omissions and derived barcode numbers from the
container. Implemented the required companion API change in the clean isolated
worktree /private/tmp/emsys-api-deferred-assignment, branch
codex/deferred-invoice-assignment, commit 18bbe64. API PR #332 targets dev:
https://github.com/embarques/emsys-api/pull/332. It is open, not merged/deployed.
Deploy it before mobile unassigned creation. Required references, financial rules,
permissions and tenant/replay boundaries remain enforced. Label intent persists
without sequence allocation; normal update generates missing barcodes once a
container is supplied. Omitted fields preserve a pending registration's existing
assignment. Audit logging handles no container without dereferencing nil.

API checks passed: go fmt ./..., go vet ./..., go test ./..., make swagger with
shared Swagger/Scalar contract tests, and the guarded sync-create integration
suite against a newly created disposable loopback MongoDB replica set using only
emsys_codex_test. Integration proved unassigned create/replay/edit, later assignment
without duplicate labels, and initial-payment completion without a container.
The temporary test container was stopped/removed. The owner's API checkout stayed
on clean dev. No production database, merge or deployment was used.

### Correct the simulator sign-in regression — October 26

Owner reported correct credentials failing after the verification product was
installed. Sanitized simulator logs prove FIRAuthErrorDomain 17995 with
SecItemCopyMatching -34018 (required entitlement missing). The installed unsigned
artifact had no signing entitlements. This was an agent installation mistake,
not evidence of invalid credentials or Firebase client mismatch. Rebuild/install
with normal saved simulator signing after serialized verification; never install
the unsigned verification product for live authentication. Do not alter project
identity, team or Firebase options. Added this distinction to verification.md.

Deferred-assignment Apple gate passed: emsys-verification.XyMSjV, with 138 macOS
tests and 137 tests each on iPhone/iPad, zero failures; normal-workspace physical
SDK compilation, packaged Firebase check and both Release builds passed.

The subsequent normal Debug simulator build (no signing overrides) passed:
/private/tmp/emsys-signed-simulator-build.log. Xcode generated the simulator's
application-identifier entitlement for J87PCBC7U8.com.embarqueros.emsys. Installed
that signed build without uninstalling/deleting app data. Native screenshot now
shows Inicio and Cerrar sesión: the existing Firebase session restored without
re-entering credentials. This establishes recovery of the simulator's secure
session, not a new password-authentication request. No Firebase/project/signing
settings or app identifiers changed. Further UI input currently returns
noWindowsAvailable from computer-use despite the readable home screenshot; the
new date-only wizard layout still needs a native visual check when control is
available. Do not install unsigned verification artifacts for live login again.

### Xcode Prepare build recovery on a new branch — October 26

Owner reported a failed build and requested a new branch, then supplied a native
Xcode screenshot: invalid reuse after initialization failure. Created Apple branch
codex/fix-xcode-initialization without discarding/staging/committing the owner's
existing work. Xcode's 2:08 a.m. report showed the error in Prepare build, before
any Swift compilation, after dependency graph and provisioning preparation.
Restarted Xcode through its native UI, reopened this same workspace and built the
unchanged iPhone 17 destination with normal saved settings. Xcode visibly reported
Build Succeeded at 2:11 a.m. No source, dependencies, signing, identity or build
settings were changed for this recovery. A fresh Run is being checked separately.

The initial ambiguous failure report also prompted a read-only API CI review.
Merged API PR #332 is on remote/local dev at b8740828d2eb1d9f920a749de653ea4dbb723846;
its feature branch/worktree were deleted as requested. The dev image workflow
40278114383 fails during doctl token authentication with HTTP 401, before Docker
build or push. Earlier runs failed similarly. This is a separate credential issue;
no token was read/changed and no deployment was performed. The unused empty API
fix branch created before the screenshot clarified the target was removed, and
the API checkout is restored to clean dev.

Fresh native Run also succeeded: Xcode visibly reports Running EMSYS on iPhone 17,
and Device Hub shows the EMSYS home screen. This increment required no source or
dependency change, so no new synthetic regression test was added; the exact
owner-workspace Build and Run were verified directly. Existing full gate results
remain documented above. Apple changes are preserved locally on the requested
fix branch; no Apple commit or push was performed.

### Select the first customer address automatically — October 26

Owner requested automatic selection of the first address for both sender and
receiver. selectCustomer now picks the first address with a usable stable ID for
the selected party. Customers without usable addresses remain unselected; choosing
a different customer clears the previous party's selection. If search data omitted
addresses entirely, customer-detail hydration selects the first usable address
when it arrives. Detail refresh preserves a manual selection and retains the
existing missing-address review behavior.

Regression coverage exercises both party roles, first-in-array order even when a
later address is marked primary, manual override through offline refresh and scoped
reopen, late address hydration and replacing a customer with no addresses. Full
serialized verification is running in emsys-verification.BodUYT; 140 Mac tests
passed so far. Current simulator has the owner's unsaved draft. Native input on
Guardar returns noWindowsAvailable, so an async message asks the owner to save it
before replacing the running app. Do not terminate/reinstall over unsaved user work
or install the unsigned verification product for live authentication.

### Prioritize live behavior and fix item-removal runtime crash — October 26

Owner explicitly redirected the workflow: functionality/native behavior first,
then tests. This supersedes earlier test-first sequencing; preserve the verification
requirement after behavior is checked. The address-default gate already passed
in emsys-verification.BodUYT (140 Mac, 139 iPhone/iPad tests; all build/configuration
checks). After the owner saved the draft, a normal signed build was prepared.

Owner then supplied a runtime exclusivity trap in InvoiceDraftEditorModel.content,
with removeAll and the bound item getter on the main-thread stack. Traced it to
Quitar artículo: removeAll's predicate read item.id through the same observed
content array currently held for modification. Moved removal behind removeItem(id:),
so the view resolves a UUID value before the array's exclusive write starts. No
exclusivity checks were disabled. Added a focused regression for deleting a bound
row, preserving another unfinished row, repeated deletion, last-row deletion and
local reopen. Do not claim this alone proves the actual screen.

Stopped the trapped Xcode debugger process, which was also preventing the pending
simulator installation from completing. Normal signed crash-fix compilation passed
in /private/tmp/emsys-item-removal-signed-build.log. Installed and launched the
fixed app (PID 56667 at that checkpoint) without deleting app data. No credential,
Firebase or identity changes. Keyboard Command-[ successfully navigates from Home
to Menu; accessible Facturas opens the list. Device Hub coordinate clicks on its
remote toolbar fail/noWindowsAvailable or time out, and that toolbar isn't in its
AX tree. Asked owner to open Crear factura for the actual address/removal check;
keep automated tests after this functional check as requested.

Owner opened a new temporary invoice for native verification. On the installed
signed build, selected a sender and receiver from cached customer pickers. Both
address pickers immediately displayed the first actual address without a manual
address selection. Continued into Artículos; removed the only row, added two rows,
removed one then the last row again. The app remained responsive after each
operation. Continue with zero rows displayed the localized item validation message
instead of trapping. This is actual native verification of the reported failure,
not an inference from unit tests. No invoice/payment was submitted or draft saved.
Cleared the temporary receiver selected solely for this check. Owner's earlier
saved draft was preserved. Required regression gate starts only after these live
functional checks, honoring the owner's workflow correction.

Post-functional-check gate passed in emsys-verification.OUZnpq: 141 Mac tests,
140 tests each on iPhone/iPad, zero failures; unsigned physical-iPhone SDK compile,
packaged Firebase validation and Mac/iOS Simulator Release builds all passed. The
running simulator retains the normally signed, natively checked crash-fix build;
no unsigned test artifact was installed afterward. Changes remain on
codex/fix-xcode-initialization; no Apple commit/push or production writes occurred.

## Invoice wizard description catalog — 2026-10-26

Reviewed the portal's invoice description combobox, item-editor selection handlers,
item-picker query, and the Go invoice-description route/model before implementing
native selection. Each existing wizard item card now has a catalog selection
button opening a searchable native list with description and default price.
Selection copies the description and two-decimal price while preserving quantity,
labels and a manual total. Free-text descriptions remain editable, matching the
web workflow. Selection uses a stable item UUID rather than a binding into the
mutating array, preserving the preceding exclusivity-crash fix.

Catalog access follows the actual settings/view permission and existing scoped
session factories. A new GRDB migration stores downloaded descriptions per
API/user/company scope. Offline access uses downloaded entries; incomplete,
invalid or failed refreshes do not replace the saved list. The picker includes
refresh, loading, empty, authorization and recoverable failure states in Dominican
Spanish and English. No signing or bundle configuration changes were made.

The normal signed Debug iPhone simulator build succeeded and was installed,
restoring the existing signed-in account. Saved drafts were preserved. The
simulator is at the invoice list; the owner was asked to open Crear factura
because its toolbar control is absent from Device Hub's accessibility tree.
Live catalog selection, keyboard layout and actual offline UI behavior remain
unverified until that form can be opened. Automated regression coverage exercises
selection values/manual totals, editable custom text, removed-row handling,
permission revocation, scoped durable SQLite recovery, search order, the actual
GET endpoint, failed refresh and HTTP 403 handling. Final verification results
are recorded below when the serial gate finishes.

Catalog verification completed: `./scripts/verify.sh` passed in the normal
workspace, logs `emsys-verification.IZ4mYk`: 144 macOS, 143 iPhone and 143 iPad
tests, physical-iPhone SDK build, packaged Firebase identity check, macOS Release,
iOS Release and diff validation. The signed simulator build used for the live
account was installed before the gate; unsigned verification products were not
installed over it. Live catalog UI acceptance remains pending the owner opening
Crear factura as described above; automated coverage is not claimed as proof of
that untested screen interaction.

## Mobile payment capture without Cuadre selection — 2026-10-26

Owner clarified that the mobile app only records invoice/payment information;
daily income and Cuadre assignment happen in the API at sync time. Inspected the
current API resolver before changing the wizard. Removed the Cuadre picker,
statement-status/date metadata and required-review validation from creation.
Submission now takes the authenticated account branch rather than a branch from
a downloaded statement. New journals omit statement identity/currency and allow
the API to resolve them. Unpaid invoices omit the statement reference; completing
a paid registration uses only the identity returned by its journal response.
Cached review fields remain decodable for old drafts and frozen operations.
Invoice numbering and saved signing/project settings are unchanged.

Added local regressions proving a payment can queue without Cuadre-view access,
requests omit client accounting-period choices, a closed cached review from a
different branch cannot choose the period, and frozen request bytes survive
reopening SQLite. Existing lost-response, journal-first, attachment and invoice
retry coverage now starts from drafts without a Cuadre review. Updated pending
submission copy to avoid telling a mobile user to check/select a Cuadre.
Live integration and native UI acceptance are explicitly deferred by the owner;
no API requests, real payments or account/device operations are used for checks.

Verification completed in `emsys-verification.QAaPKY`: required serial workspace
gate passed with 146 Mac tests and 145 tests each on iPhone/iPad, physical-device
SDK compilation, packaged Firebase identity validation, Mac and iOS Release builds
and diff validation. Integration tests against the real API and native UI checks
were not performed, per the owner's stated lack of access. No build was installed
over the current simulator session and no API/backend code was changed.

## Local sender signature in invoice PDFs — 2026-10-26

Owner authorized connecting captured sender signatures to local PDF preview and
printing, and reaffirmed SQLite-first persistence followed by API sync creation.
Confirmed that JSONEncoder already stores PNG Data as base64 in draft/plan JSON;
the invoice sync payload uses `senderSignature.data` as bare base64, with signer
name and `image/png`. No alternate creation endpoint or financial/numbering logic
was added.

Added retrieval of a context-valid signature only from the completed local
creation for that server invoice ID in the scoped database. Sender ID/name must
match the current invoice snapshot. Pending drafts, another invoice and another
tenant cannot provide its signature. The read-only invoice party projection now
retains the API customer ID for that association check. The PDF canvas supports
separate named logo/signature images; renderer reserves an authorization area and
fits the signature without distortion on each page. The generated document's
selection records sender inclusion. Existing preview and print actions continue
to consume the same persisted PDF bytes.

Local regressions verify base64 representation in both SQLite-bound content JSON
and the sync request, database reopen, confirmed-only association, cross-invoice
and tenant isolation, saved document bytes and multi-page layout. Rendered and
visually inspected the synthetic seven-page fixture's first page: logo and sender
signature both render, signature remains above the authorization line, terms and
footer are unobstructed. Fixture paths are `emsys-signed-invoice-fixture.pdf` and
`.png` in the macOS temporary directory. The fixture uses synthetic drawing strokes
as both the logo and signature solely to exercise independent image resources.
Live capture, API acceptance, native preview interaction and physical printing
remain deferred by owner instruction. Unsynced drafts do not get fabricated
numbers or masquerade as official invoice PDFs.

Required serial workspace verification passed in `emsys-verification.t75aXr`:
148 macOS tests, 147 iPhone tests and 147 iPad tests, physical-iPhone SDK build,
packaged Firebase configuration check, Mac/iOS Release builds and diff validation.
No signing/bundle configuration changes, live API mutation or printer action was
performed. The rendered synthetic PDF was visually inspected independently of the
passing tests; native account/device integration remains explicitly deferred.

## Align local signature fields with API names — 2026-10-26

Owner requires API-backed values to keep the same names locally and in the API;
local-only metadata can keep purpose-specific names. Added this convention to
`docs/code-conventions.md`. The draft's stored signature is now `senderSignature`
with `signerName`, bare-base64 `data`, and `contentType`, using the same Codable
value sent in the invoice sync payload. Removed the alternate stored signature
field from confirmation; confirmation retains only local context hash, policy
agreement and skip choice. Capture, preview, PDF rendering and validation read the
shared value. PNG bytes are decoded only for native validation/rendering.

Backward-compatible content decoding upgrades old confirmation.signaturePNG
values in memory; subsequent saves use only API names. Existing context hashes
remain valid for unchanged reviewed content and stay invalid for changed content.
Queued plan identities are retained, and previously frozen journal/invoice bytes
and their hashes are not rewritten. Regressions cover legacy draft upgrade and
SQLite reopen, identical signature data/API field shape, old queued plan decoding
and semantic request equivalence. Existing capture/review invalidation, base64
sync, PDF and lost-response tests remain part of the required serial gate.
No native UI change is intended; live API/device checks remain deferred by owner.

Also preserved the image in an older incomplete draft whose sender name was
cleared: SQLite may retain the valid PNG, but it is not a valid submission
signature until its signer and review are valid again. Final required gate passed
in `emsys-verification.LXdSGr`: 150 Mac tests, 149 iPhone tests, 149 iPad tests,
physical-iPhone SDK compilation, Firebase configuration validation, Mac/iOS
Release builds and diff checks. Existing signed app/device sessions were not
replaced. Live integration remains deferred as requested.

## Attachment recovery after later container assignment — 2026-10-26

Owner authorized attachment/offline recovery work with live integration deferred.
Reviewed the existing API upload identity, filename normalization, container
requirements and SQLite attachment lifecycle. Found attachments never left
awaitingContainer automatically after a later assignment; manual retry could also
force them pending without an assignment. Added transaction-bound promotion after
accepted server list/detail snapshot writes and a post-download attachment pass
in full sync, so an assigned file can upload in the same run without recreating
its invoice. Retained API container id in the read projection and require its
nonzero ID/name, matching the actual document endpoint. Manual retry cannot bypass
awaitingContainer and its UI action remains disabled when there is nothing else
to retry. Existing completed, failed and unsynchronized data stays protected.

Also aligned filename trimming/code-point limits with the API. New imports use
the normalized filename; old queued multipart bodies remain unchanged and accept
the API's normalized receipt name. Added local regressions for invalid assignment,
stale snapshot rejection, manual retry guard, lost upload response, SQLite reopen,
identical retry UUID/body, completed-upload replay protection, same-run full-sync
promotion/upload and filename normalization. No live API calls or real documents
were uploaded; native file-picker/camera checks remain deferred.

Final required serial workspace gate passed in `emsys-verification.mwrsyJ`:
153 Mac tests and 152 tests each on iPhone/iPad, physical-iPhone SDK compilation,
packaged Firebase validation, Mac/iOS Release builds and diff checks. Existing
queued file metadata remains readable; stricter API filename validation applies
to new imports rather than invalidating old outbox rows. No native app session was
replaced, and no live invoice, payment or document mutation was performed. Live
file-picker/camera behavior and deployed-API acceptance remain unverified.

## Native tabs and adaptive navigation — 2026-10-26

Owner paused pickup implementation and approved navigation first: Pickups,
Invoices, Deliveries, Daily Income and More. Added native SwiftUI tabs on iPhone,
with a separate NavigationStack per tab. iPad uses sidebar-adaptable navigation,
starting with a sidebar in wider windows. Mac retains grouped sidebar navigation.
More contains existing Home/Settings, manual invoice synchronization and account/
sign-out actions. The original invoice create/refresh/overflow toolbar remains in
InvoiceListView. Settings is also accessible before sign-in, preserving language
and appearance access. Navigation resets across authentication contexts and uses
per-window state. Invoice numbering/business persistence and signing settings are
unchanged.

Invoices remains the initially selected working section. Pickup, delivery and
income destinations explicitly show unavailable-workflow content until their
implementation; no fake operational data or unsupported mutations were added.
Reviewed actual pickup/delivery route permissions, including assigned-appointment
and assigned-delivery view grants, rather than adding an administrative-role rule.
Those grants control placeholder authorization; invoice data retains the existing
session.canViewInvoices guard. All five phone destinations stay in a stable order.
New navigation labels and explanatory states are localized in es-DO and English.

Normal signed iPhone compilation succeeded. Direct native interaction is currently
unavailable: CUA reports that the Mac is locked. Did not terminate, reinstall over
or otherwise replace the owner's existing app session. Native fixture checks use
isolated test windows and no real account/API. The tab-switch regression verifies
an entered invoice search survives Invoices → More → Invoices. Corrected the
initial test's assumption that a retained tab must re-run onAppear; native tabs
keep that view alive, so the test observes selection separately. Removed an
unreliable AppKit bitmap capture that produced a blank sidebar; it is not counted
as visual acceptance of Mac navigation.

Ran an additional standard iPhone 17 portrait check on a newly created temporary
simulator: passed, and visually inspected the rendered native five-tab bottom bar
with all Spanish labels readable. Foldable iPhone Duo's native layout can use a
side-mounted bar; the normal portrait phone check prevents treating that layout as
the standard iPhone result. Saved the synthetic rendering at
/private/tmp/emsys-navigation-portrait.png, then removed only the temporary test
simulator. The user's original iPhone simulator and saved drafts were untouched.
Final full workspace validation and iPad sidebar fixture inspection follow below.

Final serial `./scripts/verify.sh` passed all checks, including macOS/iPhone/iPad
tests, the physical-iPhone SDK build, Firebase configuration checks and both
Release builds. Logs: `$TMPDIR/emsys-verification.zabXkn`.
Inspected the final synthetic iPad rendering: the five destinations appear in the
native sidebar with Invoices selected. In this portrait fixture the sidebar
overlays/dims the detail; the snapshot also has translucent background text, so it
does not establish full iPad visual acceptance. The standard portrait iPhone
rendering and tab-state regression passed. Interactive Mac navigation and
protected live-account flows remain unverified because native computer access is
locked; no account, real invoice or printer actions were performed. Pickup,
delivery and income operational workflows are not implemented by this change.
# Pickup directory and connected completion — 2026-10-26

Owner authorized resuming pickup work standalone after the native navigation
change. Replaced the Pickups tab placeholder with a permission-gated native
directory and details, retaining existing invoice and session behavior. Reviewed
web appointment views/completion and the actual Go pickup routes, supplied-field
update semantics, assignment rules and data types before implementation.

The directory supports pending/completed filters, server search, pagination,
refresh/retry and offline search of downloaded records. Snapshots are stored in
GRDB `pickups.sqlite` in protected, backup-excluded partitions for each API root,
tenant and authenticated user. Local disk operations run in a store actor opened
off MainActor. API-backed fields keep API names; reference ID types distinguish
ObjectID route/actor references from numeric pickup and branch IDs. Cached
records render before refresh. Authorization denial clears cached directory data;
denied/deleted detail records are removed and hidden. No live credential refresh
is needed merely to open the authorized local store.

Details show customer contact/address, recipients, date, route, stop, branch and
requested item/instruction rows. Calling/directions use native links, with action
layout adapting to available width. The detail column has a readable width on
larger windows. Completion asks for confirmation and requires connectivity plus
the actual pickup update grant. It reads the latest record, sends only
`{"completed":true}`, saves the returned server snapshot and verifies with GET.
An unknown mutation result blocks another completion until explicit refresh;
there is no automatic replay or whole-record replacement. Returning to the list
refreshes the displayed status. Labels and recoverable errors are localized.

Limitations and backend gaps are recorded in `docs/api-mobile-contracts.md`:
pickup writes have no safe offline idempotency/version contract, no incremental
deletion feed, and no documented pickup photo/signature upload contract. Offline
completion and those mutation features remain unavailable. Invoice sync/create
does not currently preserve an appointment association, so creating a linked
invoice from a pickup is also deferred; standalone invoice creation is unchanged.
This increment implements browsing/contact/connected completion, not every
potential field-operations capability. No backend files or signing were changed.

Regression coverage includes durable reopen and user/tenant/server isolation,
invalid-page rejection, offline search, durable downloads, denial cleanup,
completion's minimal patch and read-after-write confirmation, read-only grants,
already-completed records, offline blocking and unknown-result recovery without
automatic mutation replay. Rendered the real PickupDetailView in isolated native
iPhone/iPad test windows with synthetic records. Inspected the customer,
instructions and completion action; no real account, phone call, Maps launch or
business mutation was exercised. Live integration/device acceptance remains
deferred as requested. Final workspace gate results follow below.

The iPad render caught an oversized contact-action row with hidden labels from
the adaptive fitting container. Replaced it with separate native labeled link
rows. Rechecked the corrected detail on a temporary standard portrait iPhone 17:
all seven pickup tests passed, and both contact labels/address/instructions render
readably. Preserved the synthetic preview at
`/private/tmp/emsys-pickup-portrait.png` and deleted only the temporary simulator.
Also corrected pickup-number filters to JSON numbers after reviewing the API's
strict numeric query validation, with regression coverage for exact ID matching.
Intermediate gates passed; the second run required terminating only its stalled
`simctl diagnose` child after all iPad tests passed, then completed remaining
checks. Final full validation reruns after the query/layout corrections.

Final serial `./scripts/verify.sh` passed without intervention:
160 macOS tests, 161 iPhone tests and 161 iPad tests, all with zero failures;
physical-iPhone SDK compilation, Firebase identity validation, macOS Release,
iOS Simulator Release and whitespace checks passed. Logs:
`$TMPDIR/emsys-verification.DrV7RT`. Inspected the final iPad native rendering
again: the contact labels and completion button are visible, with no oversized
blank contact row. Mac interactive layout, dark/large-text visual acceptance,
the protected live-account directory and real server completion remain
unverified; fixture rendering/tests do not establish those checks.

## Canonical pickup permissions and company-role migration — 2026-10-26

Owner explicitly requested removal of the retired company-wide pickup grant and
synchronization of company roles. The API migration's read-only preflight found
nine affected roles across all eight configured companies. Applied the reviewed
transactional migration successfully to every company; a second read-only pass
reported zero affected roles in each company. The migration replaces retired
references with the actual tenant's canonical pickup-view reference, verifies no
old references remain, and deletes the obsolete permission document. Assigned-only
drivers and unrelated grants remain unchanged.

Removed the retired fallback from native navigation authorization and its mobile
contract notes. Company-wide access now recognizes only `canViewPickup`; drivers
use `canViewAssignedAppointments`. API PR #335 records the applied migration and
source cleanup. Companion portal PR #168 removes the unused web permission alias;
targeted ESLint and full TypeScript checks passed with the bundled Node runtime.
Unrelated existing API/portal edits were preserved in their original checkouts.
API PR #335 and Portal PR #168 were subsequently merged into dev on October 26; the owner handles deployment. The owner subsequently requested complete identifier removal; the completed
migration utility and obsolete fixtures were removed from the API PR. Native
verification results follow.

The serial native gate passed all tests and builds: macOS/iPhone/iPad suites,
physical-iPhone SDK compilation, packaged Firebase identity, both Release builds
and diff checks. Logs: `$TMPDIR/emsys-verification.Hvyza3`. All iPad tests passed
before Xcode stalled collecting diagnostics; terminated only that run's owned
`simctl diagnose` child, allowing the remaining checks to finish. No live device,
session logout or signed-in UI operation was performed for this permission-only
change. An independent source search found no retired-name references remaining
in native application code or mobile contract documentation.


## Invoice creation from a pickup — 2026-10-27

Owner approved continuing this workflow standalone. Reviewed Portal appointment
prefill, recipient selection, customer hydration and invoice write payload, plus
the current API request conversion and invoice/sync transactions. Portal creates
one invoice for the chosen recipient and does not automatically convert pickup
instruction comments to financial items or mark the pickup completed.

Added Create invoice to native pickup details for existing ordinary invoice
creators. Multiple recipients require a deduplicated choice. The existing wizard
opens with customer identities and a visible pickup reference, hydrates full
customer snapshots through its normal online/cache path, chooses the first
address, and retains its catalog-based invoice items, payments and signature
review. The API-backed `pickup: {id}` association survives draft save/reopen,
confirmation hashing, frozen transactional outbox requests and downloaded invoice
projections. Old drafts without pickup remain readable. Session/context checks
continue to gate both preparation and subsequent editing.

Found the API's existing request converter discards its string pickup input and
rejects the Portal's object reference. A dedicated companion API branch now
accepts both representations, preserves legacy string sync fingerprints, resolves
the actual tenant pickup snapshot in the invoice transaction after replay lookup,
and rejects missing references without committing financial writes or receipts.
No pickup completion or uniqueness-per-pickup rule was invented. A single indexed
pickup lookup is added only to linked creation; ordinary/replayed creation adds
none. No production performance benchmark or live business write was performed.

Driver-only creation remains unavailable: the current API sync route requires
ordinary invoice create permission and lacks the Portal's assigned-invoice context
and authorization contract. Native does not use pickup-view permission as invoice
write authority. The companion API change must be merged/deployed before using
this flow against that server. API integration regressions were added but remain
unexecuted because live integration is deferred; ordinary tests do not establish
MongoDB transaction acceptance. Native validation and visual evidence follow.

Companion API PR: https://github.com/embarques/emsys-api/pull/337 (open, not merged).
Go formatting, vet, full non-integration tests and generated Swagger/Scalar checks
passed on the committed branch. The API worktree is clean. No Portal change is
required; its current caller already supplies the pickup reference.

Visual inspection of the actual synthetic iPhone/iPad wizard renderings confirmed
the pickup number, selected customer names and navigation/save actions are visible.
The fixture intentionally has no downloaded addresses and does not establish live
customer lookup or first-address behavior. Added a separate offline hydration
regression for renamed customer snapshots, first-address selection for both
parties and preservation of an explicitly changed address. A pickup's historic
customer name may differ from the current customer record; linked hydration now
matches identity/role and updates both the displayed name and full snapshot,
while retaining the existing concurrent-selection checks. Standalone invoice
hydration keeps its existing matching behavior.

Final regression suites passed: 165 macOS tests and 167 tests each on iPhone/iPad,
all with zero failures, including the renamed-customer/first-address regression.
Native iPad detail rendering also shows the new Create invoice action separately
from connected pickup completion. Preserved wizard fixture screenshots at
`/private/tmp/emsys-pickup-invoice-iphone.png` and
`/private/tmp/emsys-pickup-invoice-ipad.png`. These are synthetic light-mode
renderings, not live-account/device, dark-mode, large-text or printer acceptance.
The final serial workspace gate logs are `emsys-verification.wkt3SQ`.

Final `./scripts/verify.sh` completed successfully without intervention:
normal-workspace package resolution, all three suites above, physical-iPhone SDK
compilation, packaged Firebase identity checks, macOS Release, iOS Simulator
Release and diff checks. No signing/project/dependency configuration was changed.
Swift changes remain local with the owner's existing uncommitted work preserved.
API PR #337 remains open; no merge/deployment or live business mutation occurred.

## Device-cached permissions and profile synchronization — 2026-10-27

Owner requested local permission use, refresh at explicit sign-in and a manual
profile action. Permissions were already persisted with the verified profile in
an environment/user-scoped, device-only Keychain snapshot. Restoration previously
attempted API authorization first and retried it when reconnecting. Changed the
session loader to restore a valid device snapshot without permission/profile API
requests. Explicit sign-in and Sync permissions bypass the cached snapshot; a
missing, foreign or unreadable copy still requires fresh authorization. Removed
permission revalidation from foreground/reconnection and ordinary data-sync
triggers. Firebase token renewal and API authorization of business requests remain
unchanged; no arbitrary offline expiration was introduced.

More's account/profile section now displays the role, permission-sync button,
last successful update and localized recovery text. Desktop account navigation
adds Perfil access to the same section. Manual refresh is serialized, keeps the
session context stable and replaces in-memory grants only after secure persistence
succeeds. Transient refresh/server/storage failures retain the prior verified
copy and report failure; confirmed authorization denial, inactive user or tenant
change clears access and removes the offline snapshot. Logout still removes it.
Old snapshots without the optional update timestamp remain readable. No passwords
or Firebase tokens are added to this cache; no API field names were changed.

Added regression coverage for cache-only restoration, explicit refresh bypass,
foreign/missing snapshots, refresh failure versus revocation, timestamp/legacy
compatibility and native Spanish profile-control rendering. Final results follow.

Inspected the real reusable permission controls rendered with synthetic Spanish
account data on iPhone/iPad: role, sync action, last update and retained-copy error
text are readable. Evidence copies are `/private/tmp/emsys-permissions-iphone.png`
and `/private/tmp/emsys-permissions-ipad.png`. They do not prove live Firebase
login/manual sync or signed Keychain persistence. Live account, physical-device,
Mac interaction, dark-mode and large-text checks remain unavailable/deferred.

Final suites passed: 170 macOS tests, 173 iPhone tests and 173 iPad tests, zero
failures. Final gate logs: `emsys-verification.RJGtIE`. Xcode stalled collecting
simulator diagnostics after all iPad tests completed; terminated only that run's
owned `simctl diagnose` child, allowing its remaining compilation/build checks to
continue. No user app session or account was signed out or replaced manually.
This increment does not complete assigned-driver invoice creation or the safe
offline pickup-completion outbox; those field-operation gaps remain as documented.

The final serial `./scripts/verify.sh` completed successfully, including normal
workspace dependency resolution, the suites above, physical-iPhone SDK compilation,
packaged Firebase identity checks, macOS Release, iOS Simulator Release and diff
checks. No signing/bundle identifiers, dependency versions, API/Portal code or
production data changed. Existing staged/unstaged Swift work remains preserved;
this increment is local and was not committed or pushed.

## Publishing the completed Apple work — 2026-10-28

Owner authorized committing, pushing and merging the accumulated work, then
continuing the driver/offline pickup workflow on new branches and review PRs.
API PR #337 was already merged into dev (fd2c87d); its temporary branch has
already been removed. Deployment remains the owner's responsibility.
The Apple publication includes the completed foundation, invoice workflows,
native documents, pickup directory and permission caching documented above.
Personal Xcode state is retained locally and removed from source control;
Firebase configuration remains ignored. The original staged Xcode window-state
blob was preserved at /private/tmp/emsys-xcode-userstate-staged.xcuserstate.
No signing/bundle settings were changed for this publication.


## Offline pickup completion — 2026-10-28

Published existing Apple work through merged PR #1, then created a dedicated
feature branch. Offline pickup completion adds scoped revision downloads,
transactional SQLite outbox persistence, immutable retry identities, pending
status presentation, conflict review and independent global upload attempts.
Server changes live in a companion API PR: completion and its receipt commit
atomically, enforce current assignment and preserve unknown fields. Legacy
completion dependencies remain pending until confirmed without creating duplicate
legacy records. API rollout is required before native offline completion is enabled.

Regression coverage exercises restart recovery, duplicate requests, changed
revisions, denied/reassigned records, receipt validation, reopened pickups,
unknown network outcomes and explicit conflict recovery. A disposable loopback
MongoDB replica set verifies transaction behavior and concurrent retries; no live
company or account is used. Native synthetic rendering checks the pending state.
Assigned-only invoice creation remains a separate unfinished capability. This
increment does not add financial settlement, daily income or Cuadre operations.

API validation passed: go vet ./..., go test ./..., generated Swagger/Scalar
contract checks, and two consecutive disposable MongoDB transaction runs. Fixed
fixture cleanup ordering so repeated runs remove their own records before
closing the database connection. The task-owned MongoDB process was stopped.
Companion API PR: https://github.com/embarques/emsys-api/pull/342 (open).

Final Apple suites passed 175 macOS / 178 iPhone / 178 iPad tests. Inspected
native synthetic iPhone/iPad rendering: pending completion is explicit, contact
controls remain readable and iPad shows the retained-change hint and retry.
Evidence: /private/tmp/emsys-offline-pickup-iphone.png and
/private/tmp/emsys-offline-pickup-ipad.png. Live account/device synchronization,
physical printing, Mac interaction, dark mode and large-text checks remain
unverified. No bundle, signing, dependency or production data changes were made.

Final serial ./scripts/verify.sh passed without intervention: normal-workspace
package resolution, all suites above, physical-iPhone SDK compilation, Firebase
identity validation, macOS Release, iOS Simulator Release and diff checks.
Logs: emsys-verification.KnoG8d. Existing publication PR #1 is merged; this
increment is submitted separately for review and requires the companion API rollout.

## Scoped pickup invoice customer preparation — 2026-10-28

Reviewed and merged API PR #342 before SwiftUI PR #2; fetched target branches
and confirmed no target drift from the tested heads before merge. Temporary
branches were removed locally/remotely. Deployment remains the owner's task.
Started new API/Apple branches for the assigned-driver invoice prerequisite.

A scoped API read returns only the pickup's sender and selected receiver with
complete invoice identity/contact/address fields, excluding notes and balances.
It enforces pickup view plus invoice creation-context authority and current route
membership for assigned-only context. It does not grant general customer access
or enable assigned invoice writes. Receiver selection cannot escape the pickup.
SQLite caches this response per pickup/recipient within the existing protected
API/user/company partition; denied/hidden pickups cannot use it. The existing
full-authority mobile invoice entry prefers this context, selects the first
address for both parties and preserves all returned customer write fields.
Transport failure may use cached context; confirmed denials do not.
Older API responses retain the existing full-authority preparation path.

No container or pickup-origin fields were added. Signature, payment capture and
invoice submission contracts are unchanged. The assigned-only writer, locked
parties, driver catalog/policy access and queue authorization remain the next
increment. In particular, no new Create-action permission was seeded: generic
invoice middleware must be reviewed before granting restricted driver writes.

API checks passed (format, vet, full tests, generated Swagger and served Scalar
contract tests), including two isolated MongoDB integration runs for selected
customer validation and assignment revocation even with full pickup view. API
PR #343 is open. The disposable database process was stopped after testing.

Final Apple tests passed 177 macOS / 181 iPhone / 181 iPad. Inspected actual
synthetic wizard rendering on iPhone/iPad; the first sender address is selected,
and the iPad also shows the first recipient address selected. Evidence copies:
/private/tmp/emsys-prepared-invoice-iphone.png and
/private/tmp/emsys-prepared-invoice-ipad.png. These do not prove live authentication,
real company/device integration, dark mode, large text or Mac interaction.
Xcode stalled collecting simulator diagnostics after every iPad test passed;
stopped only that run's owned simctl diagnose child to allow remaining builds.

Final serial ./scripts/verify.sh passed: normal-workspace package resolution,
all suites above, physical-iPhone SDK build, Firebase identity check, macOS
Release, iOS Simulator Release and diff checks. Logs: emsys-verification.TuMz5X.
No signing, bundle, dependency versions or live company records changed.
