# Native invoice directory

The approved mobile invoice design is implemented in the local `emsys-swiftui`
workspace on `codex/swiftui-invoice-list`. It is a native SwiftUI implementation;
the HTML preview and the unmerged Portal branch are references only.

## Behavior

- Preserve the native Invoices heading. Search, filter button, balance summary,
  horizontal All / Balance due / Paid / Incomplete views, month groups, invoice
  identities, party addresses, balances, containers and quantities are native views.
- Expand an invoice row to view receiver/contact information, open invoice details,
  or open the permission-protected document/print workflow.
- Load 50 records per batch as the footer appears, retain a manual Load more action,
  support pull-to-refresh, deduplicate IDs and retry a failed batch without losing
  earlier records. No Previous/Next pagination remains in this screen.
- Search invoice number, sender, receiver and container. Combine quick views with
  date range and container filters. Online payloads use the existing GET list and
  POST search contracts, stable date/id sorting, typed numeric balance values,
  scoped credentials and cancellation/generation checks.
- Search and page downloaded records in SQLite while offline. Escape literal SQL
  wildcard characters in search input. Keep the existing per-user/company/server
  database partitions and preserve pending writes and rich detail snapshots.
- The summary is explicitly the balance of downloaded invoices. It is not a claim
  about the entire company's receivables. An authoritative all-company aggregate
  would require an API aggregation contract; downloading every invoice to build
  this header is not introduced.
- Initial local preparation uses a stable view container and a deadline/retry state.
  The header remains visible during preparation or failure rather than being hidden
  behind an indefinite full-screen spinner.

## Compatibility and limits

The online Incomplete filter requires the registration search allow-list addition
in the separately prepared API change. The native app does not silently replace
that server filter with filtering one downloaded page. No API PR was merged as part
of this port.

Printing continues to use the existing document workflow. Saved PDFs print offline;
generating a new PDF from offline invoice changes remains separate, unfinished work
requiring the full print-data/signature synchronization contract and local renderer.

Validation includes native directory rendering at compact width, dark/light themes
and accessibility text sizes, offline search/filter/reopen tests, typed request
contracts, preservation of saved details, batch failure/retry/deduplication, and
initialization timeout/cancellation/recovery. Fixture checks do not establish live
account access, full tenant data availability or physical printer output.


## Automatic first-page loading

A live simulator trace reproduced cancellation of the presentation task while
Facturas remained visible. That cancellation was propagated into local store
preparation, leaving the screen in its initialization failure state. Manual Retry
could succeed after navigation completed.

Local preparation now owns its bounded task lifetime and still validates the
current authenticated context. The directory owns its initial/query requests;
new searches cancel older requests, while a transient navigation cancellation
cannot suppress the first page. Opening Facturas requests all authorized invoices
with page=1, limit=50 and sort=date:desc,id:desc, with no search/view filters by
default. Downloaded records remain the offline fallback.

The regression cancels the presentation task during preparation, verifies actual
first-page GET parameters and displayed records, and verifies that replaced
searches do not send stale requests. Runtime failure diagnostics contain only
error domain/code and cancellation state, never credentials or invoice data.


## Live versus offline source

Online/unknown connectivity requests the live API first without presenting the
saved list as current results. Explicit offline mode searches and pages SQLite
without an API request. A transport connectivity failure can fall back to that
cache before the network monitor updates; authentication, authorization, TLS and
server errors are not treated as offline and remain visible errors. First-page
errors can be retried normally.

Closing a sheet refreshes from the live API while online, rather than forcing the
list into cached mode. Network-status changes reload the current query from the
appropriate source. Local write-version conflicts preserve local edits and expose
a retryable refresh error instead of silently switching an online list offline.
The downloaded-balance summary keeps its explicit downloaded scope.
