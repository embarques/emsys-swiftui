# Reserved invoice numbers for offline creation

Backend PR embarques/emsys-api#354 defines the authoritative reservation contract.
Portal PR embarques/emsys-portal#189 provides management. Apply the documented ownership migration and deploy those
contracts before enabling this Apple client. Android adoption is deferred.

The Invoices directory and draft list show a warning when locally usable numbers
reach the server's low threshold (default 10). New creation is disabled at zero.
The Reserved invoices sheet downloads unclaimed user assignments exclusively
for this installation. Users with canGenerateOwnInvoicePool on invoice_pool_self
can generate 50 numbers for themselves while connected; otherwise an administrator
must assign a pool in the portal. The backend generates all numbers.

SQLite is scoped to user, company and API environment. It durably stores an
installation UUID, reservation proofs, local states and pending pool requests.
Selecting a reservation and saving the immutable invoice outbox commit in one
local transaction. A failed draft save rolls back selection. Consumed reservations
cannot be selected twice, returned, or resurrected by a stale server download.
The reserved number is visible before upload. Initial-payment and no-payment
creation both use the proof; payment completion preserves the confirmed number
and does not resend a consumed proof. Server acknowledgements must retain the
reserved ID and number. Older frozen outbox entries decode without reservation
metadata and retain their original bytes and retry identities.

Returning a number quarantines it locally before any network request. An uncertain
return remains unavailable across restarts. Requests keep their original encoded
bytes and UUID until acknowledged; background synchronization also retries them.
A return acknowledgement records a tombstone so replayed old assignment data cannot
make the number available again. Retired token history also blocks delayed downloads
from any earlier assignment, including after several return/reassignment cycles.
This history is retained for retry safety. A later assignment with a new token can restore
an unused returned number. Invalid/stale/permission-denied requests remain pending
for explicit review or retry; the client never invents a replacement number.

Downloads reconcile only after every cursor page succeeds. A partial or malformed
response leaves the previous local pool intact. A local pool revision rejects any
download that began before another pool operation or reconciliation committed, so
a delayed empty response cannot erase newer assignments. Download memory is bounded to
10,000 reservations; the sheet displays at most 100 unused numbers at once.
Counts and selection use an indexed local state query. Pool requests require
network connectivity; already-downloaded numbers support offline creation.

Validation includes local transaction rollback, empty-pool blocking, durable
consumption and return quarantine, assignment token changes, tenant/device
isolation, receipt identity, exact-byte retry after a lost response, permission
loss, and existing invoice/payment/pickup outbox recovery tests. Native layout is
checked with a hosted view fixture. Live Firebase accounts, physical-device
network synchronization and signed distribution remain separate acceptance checks.

Pool allocations use the tenant user ID, independently of employee IDs. The server
filters /mine and claim/return actions by the logged-in user. A user does not need
an employee relationship to download assigned numbers. Employee metadata is resolved
by the API at invoice creation. Legacy local employee allocations remain decodable
so pending proofs and frozen invoice requests are preserved through API migration.
