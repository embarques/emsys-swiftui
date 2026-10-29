# Invoice persistence and offline edits

GRDB 7.11.1 provides SQLite persistence. `InvoiceStore` is an actor; opening,
migration and filesystem setup run on a utility task, and database operations run
off the main actor. Migrations never erase the database automatically.

Each user/company/API-environment scope opens a separate directory using a SHA-256 partition key. The production scope retains the original partition path; custom API roots are isolated and the database verifies its environment metadata.
Directory names do not expose user IDs. Application Support stores the database
with a private directory and backup exclusion; iOS applies data protection until
first user authentication. Credentials are never stored in these files.

Invoice is a read-only Codable projection of the current Go invoice response,
including party names, server financial values and line items. Financial values
use Decimal without client recalculation or guessed currency. This projection
must never be reused as an invoice update payload.

List and detail payloads are separate snapshots. A sparse list response updates
page content without erasing previously downloaded details. A genuine detail
response replaces the detail snapshot, including an explicitly empty item list.
The additive migration preserves prior cached payloads. No fields from different
server responses are merged into a synthetic invoice. While offline, details
represent the last successful detail download, which can be older than the list.

The invoice destination is visible only after authentication and the portal's
`canViewInvoice` grant for resource `invoice`. The server still checks access on
every request. Requests download 40-record pages ordered by `id:desc`; page
membership and snapshots commit in one transaction. Invalid IDs, duplicates and
invalid page sizes are rejected. Cached page order is retained. A page becoming
empty never deletes other invoice snapshots or infers a server deletion.

List and detail screens load saved records before a network refresh, then reload
from SQLite after successful downloads. Failed refreshes keep available cached
records and show a localized message. An explicit session-generation boundary
prevents a stale client from downloading another user's records into its old
database. Detail downloads must match the requested invoice identity.

## Durable description editing

The initial editable operation changes existing line-item human descriptions
(the API's `name` field). The portal clears the numeric catalog reference when
switching to free text; the native editor follows that behavior. Prices, totals,
numbering, parties and statuses are not recalculated by this editor.

A separate `InvoiceWriteDocument` retains the complete public sync document,
including unknown fields and exact decimal values. The read projection is never
sent as a full update. GET `/invoices/sync/{id}` supplies this document and an
opaque revision. An unavailable sync route may fall back to the ordinary detail
GET for viewing only; it cannot supply a writable baseline.

Saving descriptions updates the local invoice and inserts an immutable UUID,
expected revision, exact request bytes and original/changed names in one SQLite
transaction. One active edit per invoice is allowed. Reopening the application
preserves pending work. A persisted database change counter prevents an older
in-flight download, including one from another window/store actor, from replacing
newer local changes. Downloads never overwrite an actively edited projection.
The editor retains the baseline it opened; a newer downloaded baseline makes its
save require review rather than silently adopting the new revision.

Uploads use only PUT `/invoices/sync/{id}`. A connection failure retains the exact
request UUID and bytes for retry. Server acknowledgement commits the confirmed
snapshot and completed operation atomically. Stale/invalid edits require review;
authorization failures and unavailable routes remain visible pending states.
There is no fallback to the old unconditional PUT.

Review shows original, local and latest server descriptions. Explicitly keeping
local names overlays only those changes on the chosen latest snapshot, preserves
other server fields and creates a new request UUID. Using the server discards the
active edit only after confirmation. Missing item identities cannot be guessed.
Completed, discarded and superseded entries remain in history; no cleanup removes
them yet. The pending list includes edits outside currently downloaded pages.

## Local creation drafts

The invoice list exposes a local draft list and editor. Unfinished sender/receiver
names, the calendar date and line-item text can be saved without a network request.
Numeric input remains text while unfinished; it is neither rounded nor treated as
a payment/financial result. Drafts have local UUIDs, not reserved server numbers.
They do not create invoices, customers, journal entries or automatic uploads.

Draft bodies and list metadata commit atomically in the same scoped SQLite store.
The paginated list reads metadata without loading every full form. Revision
predicates prevent a stale window from overwriting or deleting a newer saved draft.
On conflict, the editor preserves its form and offers an explicit save as another
draft. Deletion requires confirmation. Drafts are not subject to automatic cleanup.

Current coverage includes reopen/unfinished input, stale save/delete and copy
recovery, authorization context changes, user/tenant/API isolation, invalid state
rejection, calendar-day stability and indexed metadata pagination. Initial Mac
and iPad suites passed 54 tests before the later verification-gate fixes; final
normal-Xcode-workspace results are recorded in implementation-progress.md.

These are preparation forms only. Customer/catalog selection, assignments,
policies/signature, payment review and final submission remain to be connected.
Never convert the typed draft names into guessed existing customer identities.

## Remaining Milestone 5 work

- Complete creation and broader editing fields, validation, numbering, barcode,
  payment and rounding behavior from current portal/API code. Creation must
  follow the current skip-payment/open-Cuadre path or the recorded-payment
  registration/completion path, as appropriate.
- Complete creation drafts and durable dependent submission steps.
- Incremental change/deletion retrieval and best-effort background scheduling.
- Retention and cleanup with all pending-operation protection rules.
- Safe live API, signed-device and visual/accessibility acceptance.

API synchronization routes are in review PR #328, not merged or deployed. Their
absence leaves edits pending and preserves offline work. Local fixture tests
cover transaction rollback, reopen, immutable retry after a lost response,
conflicts, explicit resolution, permission/route failures, download races and
user/tenant/environment isolation. They do not prove a live end-to-end workflow
or final milestone acceptance.
