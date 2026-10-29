# Current mobile API review — Milestone 3

Sources inspected on October 24, 2026: current local `emsys-portal` and `emsys-api`.
Paths below are relative to those repositories. No production requests or writes
were performed. This is an incremental contract inventory, not final acceptance.

## Authentication

Portal `src/lib/api/axios.ts` and
`src/lib/auth/firebase/firebase-user-profile.ts` establish Firebase ID-token
authentication. Send `Authorization: Bearer <token>` and tenant `X-Company-ID`.
Company resolution favors the token's `companyId` claim, with optional
Firestore `users/{uid}.companyId` fallback. The profile only supplies company,
name and email; do not introduce legacy App-Id or Api-Key request headers.

API `internal/user/routes.go` provides `/users/current` and `/users/permissions`.
`internal/user/model.go` defines role `{id,name}` and permission
`{name,resourceType}`. Backend permissions and tenant middleware remain
authoritative. Refresh once after 401; 403 is a permission denial, not an
instruction to refresh indefinitely. Do not persist passwords or tokens in
UserDefaults. Firebase's native secure session persistence should own credentials.

The owner rejected an arbitrary client offline time cutoff. Previously verified
contexts may restore after recognized connectivity failures; server authorization
remains authoritative on reconnection. See authentication.md for scope/invalidation.

## Invoices

`internal/invoice/routes.go`: GET `/invoices`, POST `/invoices/search`,
GET `/invoices/{id}`, POST `/invoices`, PUT `/invoices/{id}`, DELETE
`/invoices/{id}`, each with its corresponding invoice permission.
`internal/invoice/model.go` uses ObjectID string identities, server timestamps,
party snapshots, line items, barcode identities, container/branch references,
registration and financial totals. Server values must drive business statuses and
calculations. Local models should preserve absent values rather than invent them.

`internal/invoice/repository.go`, `Update`, matches by `_id` and replaces business
fields while preserving receipts. No expected-version predicate appears in that
update. `updatedAt` alone does not provide atomic optimistic concurrency.
The ordinary routes have no generic replay/conditional-write contract. A durable
deletion/change feed is still absent. The legacy-sync endpoints synchronize the old backend and are not
a mobile device synchronization protocol.

Separate routes in merged API PR #328 provide retry-safe creation and
conditional updates with durable UUID receipts. GET `/invoices/sync/{id}` returns
a complete public write baseline and opaque revision; PUT on the same path checks
that revision transactionally. Existing portal endpoints remain unchanged.
POST `/invoices/sync/create` supports replay-safe creation, including pending
registration completion. PR #328 was merged into dev on October 25, 2026 (verified with GitHub metadata). Deployment and live native acceptance remain unverified.

The native description editor uses only conditional updates, preserving immutable
requests across uncertain responses and requiring explicit conflict review.
Unavailable routes preserve queued work; no fallback to unconditional writes.
A download page is not a reliable deletion signal. Never infer deletion from
absence in a filtered or partially downloaded list.

## Delivery and attachments

`docs/contracts/delivery-completion-wizard.md` and `internal/delivery/routes.go`
define assigned-barcode listing, item review and atomic completion. Numeric
barcode `delivery.id` is distinct from route ID. Completion accepts a stable
UUID `requestId`; an identical retry returns the original result and changed
payload reuse conflicts. Preserve the exact payload and UUID across uncertain
responses. Status IDs and policy agreement come from the current server contract.

`docs/invoice-documents.md`: private attachment metadata has versioned rename/
delete using `If-Match`; stale versions return 409. List pagination is cursor-based.
`docs/contracts/delivery-completion-wizard.md` additionally defines stable photo
`uploadId` replay protection. Completion links already-uploaded photo IDs and
must not be implemented as separate signature/status mutations. Cache original
files, not expiring signed URLs. Never forward API bearer headers to storage URLs.

`docs/contracts/invoice-customer-signature.md` uses canonical `senderSignature`
on invoice writes. Signature images and actual receiver ID are excluded from
read responses. `docs/contracts/delivery-receiver-signature.md` defines a separate
receipt operation with server-assigned signing metadata. These privacy boundaries
limit what an offline renderer can reproduce from synchronized invoice JSON.

## Additional mutation findings

`internal/invoice/service.go`, `CreateWithUser` and `prepareInvoiceCreate`,
allocates server ObjectIDs and timestamps, resolves branch/user/audit context,
requires sender and container, supports controlled automatic numbering, and can
complete an existing PENDING registration after validating its financial state.
Number availability is not a general replay contract: retrying an automatic-number
create can allocate another number. `UpdateWithUser` preserves journal-managed
financial fields and private receipts; native code must not flatten a read
projection into its replacement payload.

`docs/pickup-appointments.md` and `internal/pickup/routes.go` identify numeric
pickup IDs and daily vehicle-route assignments, not reusable route IDs.
Assignments require matching branch, active pickup route and incomplete pickups.
Omitted route preserves assignment; explicit null clears assignment and stop order.
Do not turn an offline partial edit into a full record replacement or infer a
completed state from label text. General pickup replay/concurrency remains to be
established before automatic uploads.

Payment recording uses the journal engine, not a fabricated payments endpoint.
`internal/journal/handler.go`, `PostEntryRequest`, includes transactionType,
amount, currency/rate, payment method/account, income statement and invoice
context, plus optional `idempotencyKey`. `internal/journal/service.go`,
`PostEntry`, performs its lookup and posting in a transaction. A found key returns
the existing journal; this is not proof that a changed payload under the same
key is rejected. Preserve the exact original operation and confirm its uniqueness
and concurrency enforcement before using it for durable offline retries. Backend
financial and settlement status remains authoritative.

GET list pagination uses page/offset/limit; defaults are page 1 and 40 records in
`internal/core/query/pagination.go`. `sort.go` parses comma-separated
`field:direction` pairs, such as `id:desc`; it does not use a guessed `-id` form.
Page membership is only a snapshot, not a durable change cursor.

## Remaining review

Trace complete invoice portal request builders, decimal/rounding and numbering
edge cases; assigned pickup completion permissions; payment validation, key
uniqueness and financial replay semantics; change-feed/deletion handling.
Document those contracts before implementing their mutations. Backend changes,
if needed, must be narrowly proposed and validated against both web and native
callers; missing contracts must never be silently filled in by the client.

## Current creation ordering

The evening recheck of `invoice-daily-income-step.tsx` found that the active
skipPaymentAndContinue path sets registration=null, paymentSkipped=true and the
open Cuadre ID. It does not call registerInvoiceZeroPaymentInCuadre; that helper
is currently unreferenced. `canContinueInvoiceDailyIncomeStep` accepts either an
actual registration or skipped payment with a positive open statement ID.
The normal create wizard still requires this step and policy review.

For skipped payment, use the ready invoice payload with the open Cuadre reference
and separate invoice sync creation route. Do not post an extra zero-payment
journal based on older notes. For an actual recorded payment, preserve the journal
sync UUID/body and returned pending invoice identity/number/totals before invoice
completion. Completion reuses that issued number with automatic numbering off.
The existing isolated synthetic journal/completion test proves that second path;
it is not evidence that every portal create must first post a journal.

Native local draft preparation is implemented; ready-payload construction,
reference selection and dependent submission queues remain pending.

## Field-operation implementation boundaries

Rechecked pickup/delivery route middleware and portal delivery wizard sources.
Pickup IDs are positive uint32 values, unlike invoice ObjectIDs. Pickup comments
contain purpose, unit, uint8 quantity and description. Incomplete assignments and
explicit null/omitted route semantics must be preserved. General pickup mutation
replay/versioning remains unresolved; never queue ordinary PUT as if safe.

Delivery assigned listing has its own endpoint and named assigned permissions;
do not reuse the unrestricted delivery directory for assigned-only users.
Authoritative route middleware and assigned-access implementation take precedence
over older narrative paragraphs in delivery documentation. Review validates both
delivery and invoice identity; completion additionally uses invoice update access.
The client must not invent employee/crew authorization rules.

The portal uploads at most 12 image documents sequentially, retaining each stable
photo UUID as uploadId and each confirmed document ID. Successful uploads survive
a later upload/completion failure. Completion submits the frozen request UUID,
selected canonical/legacy piece IDs, uploaded document IDs, selected current
policies/agreement and actual receiver signature in one atomic server operation.
Native offline persistence must durably preserve original photo bytes and step
results before proceeding. A definitive conflict requires fresh review; it must
not silently resubmit changed pieces/signatures under an old UUID. No native
field-operation writes or cleanup are implemented yet.

### Registration retry caveat found during final trace

The portal's current `createDailyIncomeJournal` builder does not actually include
an idempotencyKey. The Go endpoint supports it, and the earlier isolated fixture
supplies one explicitly; that fixture is not proof of portal retry behavior.
The native sync flow instead persists its own requestId before sending to the
new separate journal route and omits entry.idempotencyKey. Never derive an
operation identity from invoice number alone.

More importantly, `journal/invoice_lifecycle.go:removeEntryFromInvoiceTotal` can
delete an empty INITIAL-PAYMENT pending invoice when its journal is deleted, and
`journal/repository.go:Delete` physically removes that journal. This implementation
takes precedence over an older service comment saying initial entries cannot be
deleted. The current replay lookup is on the journal itself, not a durable receipt,
and there is no changed-payload fingerprint. Consequently, deletion after a lost
response can remove the existing replay evidence. Do not enable offline automatic
registration/payment replay on the strength of the ordinary duplicate check alone.

Implemented approved API increment in commit fc00169 / review PR #328: a separate
journal synchronization submission route with durable user/tenant UUID receipt,
payload fingerprint and original journal identity committed with existing posting.
Deleted-result replay must conflict without reposting. Preserve ordinary portal
routes, reuse financial validation/transactions and test concurrent replay,
deleted pending registration, changed payload and rollback in isolated MongoDB.
The route is POST /journals/sync; its exact contract is in API docs/journal-sync-post.md.
It remains unmerged/undeployed, and native creation/payment queues are not wired yet.

## Deferred operational assignment during mobile creation

The owner clarified on October 26 that mobile operators do not know the container
or pickup origin/assignment when entering an invoice. Native requests now omit
those unknown values. API PR #332 (open, not deployed) permits omission while
preserving sender/financial/authentication/replay requirements. Requested labels
remain saved but barcode generation waits for a real container assignment through
the existing update flow. A supplied invalid container is rejected; no placeholder
operational assignment is generated. Deploy that PR before using unassigned
mobile submission. Documents still require a container and remain locally queued
until later assignment and an explicit retry.

### Invoice creation item descriptions — 2026-10-26

The portal's `invoice-form.tsx` loads `useItemPicker`; its
`invoice-line-item-description-combobox.tsx` searches catalog names, newest first,
and permits free text. Selecting a catalog entry in `invoice-line-items-editor.tsx`
copies its description and two-decimal default price, preserving quantity, labels,
and a manually overridden total. The native wizard follows those rules with a
searchable native sheet launched from each existing item card. The invoice draft
and creation request retain the merchandise description text, never a numeric
catalog identity in place of that text.

The existing API is `GET /invoice-descriptions`, with `page`, `limit`, and
`sort=createdAt:desc,id:desc`; its envelope contains `data` entries with numeric
`id`, `name`, numeric `price`, and optional `createdAt`. The Go route requires
`settings/view` (`canViewSettings`), so catalog access is independently checked
within the existing tenant/session boundary. Users without that permission retain
free-text item entry. Catalog selection is read-only and creates no server item.

The downloaded catalog is stored in the scoped GRDB database in a new migration.
A refresh replaces it only after all pages validate; failures retain previously
downloaded entries. The implementation bounds a download to 1,000 entries / 2 MiB
and reports an error rather than silently replacing the cache with a truncated
list. Authorization failures hide the catalog. Selected descriptions and prices
remain durable draft values independent of a subsequent catalog refresh.

### Mobile payment capture delegates accounting periods to the API — 2026-10-26

Owner clarified that the mobile application captures invoice payments and does
not select or manage Cuadres/daily income. The current API checkout (aecdd18)
implements `journal.Repository.ResolveCurrentCloseout`, called by
`ensureIncomeStatement` during journal posting. It resolves the accounting period
from server recording time and branch, and supplies currency/rate when omitted.
Invoice creation without an initial payment uses the API's current-period lookup;
completing a payment registration can carry the statement identity returned by
the server. This is server-provided association data, not a mobile period choice.

New mobile creation plans no longer require a cached payment review, open period
or permission to view income statements. The wizard no longer presents Cuadre
selection. It captures method, amount, discount, bank/check/reference information
and payment location, and uses the authenticated account's branch for submission.
Journal requests omit client statement IDs and currency; unpaid invoice requests
omit a statement reference. A confirmed journal's statement identity is retained
only when completing its linked invoice. Existing frozen request bytes remain
unchanged on retry. Old draft review fields remain decodable but do not control
new submissions. Invoice numbering is unchanged pending the owner's later design.

Live API/device integration is unavailable by owner instruction. Inspection of
the current repository does not establish which API revision is deployed, or
prove live payment posting. Missing/currently unavailable accounting periods remain
server errors; the app must preserve pending requests and never fabricate a Cuadre.

### Attachment assignment recovery and upload identity — 2026-10-26

Reviewed `internal/invoice_document/service.go`, `upload_id.go` and the existing
unique invoice/upload-ID index. Upload remains `POST /invoices/{id}/documents`
with multipart `file` plus stable UUID `uploadId`. Replays are accepted only for
the same invoice, actor, bytes, original name, MIME and size. Native retries keep
the exact multipart body and UUID stored with the local attachment.

The API currently requires a nonzero container ID, trimmed container name and
invoice number before document upload. Mobile creation still omits unknown
container information. Attachments remain durable in `awaitingContainer` until a
server list/detail refresh supplies an assigned container. Accepted snapshot writes
promote only that invoice's waiting attachments in the same SQLite transaction.
A full sync uploads newly eligible files after downloads in that same run. Manual
retry does not bypass the container wait, and completed uploads cannot be promoted
again. Stale downloads rejected by the local version guard cannot promote files.

API filenames use `strings.TrimSpace`, reject dot/dot-dot and count Unicode code
points up to 200. New native imports normalize surrounding whitespace and validate
those limits. Existing queued files keep their original multipart bytes; receipt
validation compares the server's normalized original name, avoiding a false failed
acknowledgement after a successful upload. No local rename rewrites a queued UUID.
# Pickup field workflow review — 2026-10-26

Reviewed `internal/pickup/{model,request,routes,handler,service,query_filters}.go`,
`docs/pickup-appointments.md`, portal `orders-api.ts`, `order-view-sheet.tsx` and
the appointment-to-invoice prefill implementation. Pickup IDs are positive
UInt32 values; daily route references and completion actor references use Mongo
ObjectID strings, while branch IDs are UInt16 values. These are different types.

GET/list/search allow `canViewPickup` or `canViewAssignedAppointments` on
`pickup`. The server scopes assigned-only users
to their routes. Native requests must not add an administrative override or
invent an employee/route filter. POST `/pickups/search` accepts the standard
query body and `completed=true|false`; absent completed defaults to false. The
mobile directory downloads pages of 50 and searches number, parties, phone,
address, route and comment text. Downloaded records are saved in a dedicated,
user/tenant/API-partitioned GRDB database before publication. Offline searches
cover downloaded records only, not all server appointments. There is no pickup
incremental-deletion feed, so cached membership can be stale while disconnected;
a detail 403/404 removes that cached record, and a list 401/403 clears the cache.

Offline completion now uses the companion pickup sync contract (backend rollout
required): POST `/pickups/sync/search` downloads a bounded scoped page of
`{pickup, revision}` snapshots; GET `/pickups/sync/:id` refreshes one snapshot.
POST `/pickups/sync/:id/complete` accepts immutable `{requestId, revision}` and
returns `{pickup, revision, requestId}` after server confirmation. Ordinary
GET/search remain read-only compatibility fallbacks and cannot prepare completion.
No ordinary PUT is used as an unsafe sync fallback.

SQLite commits a frozen UUID/request to the pickup outbox before any upload;
its operational projection immediately shows completion pending synchronization.
Restarts and retries preserve identical request bytes. Downloads cannot overwrite
pending intent. 409 requires explicit review/acceptance of the current server
copy; unknown outcomes cannot be discarded. 401/403 and unavailable endpoint
states retain work for explicit retry. Denied snapshots are hidden while active
operations remain durable. Global synchronization attempts pickup and invoice
queues independently and reports unresolved work.

The API commits minimal completion status/audit fields and an idempotency receipt
in one tenant transaction. It checks existing view/update grants and current
assigned-route scope. Changed revisions conflict. Accepted receipt replays never
re-complete a dispatcher-reopened record. Legacy-enabled companies remain pending
until the explicit legacy completion operation confirms; missing legacy mappings
require administrative repair. The endpoint never creates a legacy pickup.
Pickup creation, photos/signature upload and incremental deletion retrieval still
need separate contracts. Completion does not create an invoice or record payment.

The pickup-to-invoice association is now implemented in the companion API branch
`codex/pickup-invoice-association`: create/sync accept `pickup: {id: UInt32}` or a
legacy string ID, resolve the server snapshot in the tenant transaction, and
retain the association. This requires that backend change before mobile use;
older servers reject the object instead of safely persisting the association.
Creation does not mark the pickup complete. Native prefill follows the current
Portal: sender, chosen recipient, hydrated customer details and existing catalog
items; pickup instruction rows never become invented invoice charges.

The existing API sync route requires ordinary invoice create permission. Native
pickup creation therefore uses `canCreateInvoice` with existing invoice view
access. Portal assigned-only `canCreateAssignedInvoice` and context endpoints are
not implemented in the checked-out API; native does not widen authorization to
simulate that flow. Those driver-only writes remain a separate backend gap.

## Scoped pickup invoice customer context

Companion GET `/pickups/:id/invoice-context?receiverId=<ObjectID>` returns
`{pickupId, revision, sender, receiver?}`. It reads at most the pickup's sender
and chosen receiver in a tenant transaction and excludes unrelated customer
metadata. The native app persists complete invoice fields under the original API
names, selects the first address for both parties, and can reuse the downloaded
context offline. Confirmed denial never falls back to a cached context. This is
preparation only: assigned-only invoice writes and permission seeding remain
separate work, and no general customer-list authority is granted.
