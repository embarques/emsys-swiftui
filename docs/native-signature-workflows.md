# Native signature workflow review

Reviewed current Apple, portal and Go sources on October 25, 2026. This review
identifies the next integration work; it does not claim that capture is connected
to an invoice or delivery yet.

## Separate business operations

The portal's `invoice-form-wizard.tsx` builds a sender signature only for a new
invoice with the policies step included and signature skipping turned off. The
signer's name comes from the selected sender. `invoice-policies-step.tsx` presents
the active policy text and an explicit agreement independently of signature
skipping. Do not add a generic “Sign invoice” action to an existing invoice simply
because the API accepts a write-only senderSignature field.

`customer-signature.schema.ts` sends signerName, bare base64 data and
contentType=image/png. `invoice.DecodeSignatureImage` accepts PNG/JPEG with a
matching MIME type, at most 2 MiB decoded, dimensions no greater than 4096 each
and at most 4,194,304 pixels. Native SignatureDrawing currently exports PNG within
these bounds. `invoice.stampSenderSignature` supplies the authoritative signedAt
and collectedBy values. A local capture timestamp must not impersonate them.

Receiver signatures belong to delivery workflows. The existing standalone
PUT /deliveries/:id/invoices/:invoiceId/receiver/signature validates the delivery,
container and invoice assignment and stores a receipt without completing delivery.
It requires signer name, personal ID and bounded image data. The repository path
fingerprints the signature and delivery to avoid identical stored receipts; this
is not evidence that every delivery mutation has a durable request-UUID contract.
The separate POST /deliveries/:id/invoices/:invoiceId/complete has its own
completion contract and permission requirements. Review that complete workflow
before building an offline delivery submission; do not substitute receipt capture
for completion or add guessed assignments/client permission rules.

## Existing native implementation

SignatureDrawing stores normalized strokes, validates resource bounds and exports
PNG away from the main actor. SignatureCaptureView supports touch/pointer drawing,
clear and accessible empty/captured descriptions. Sender capture is now bound to the creation draft review context and its API-shaped base64 signature
persists in the scoped local draft. Official invoice submission now freezes the context-bound sender PNG in its durable
creation outbox; live submission acceptance remains unverified. Delivery capture
remains an unfinished integration. Local invoice drafts now preserve selected customer/address identities, container,
pickup assignment and active-policy snapshots. Cuadre assignment belongs to the API at synchronization; mobile creation no longer requires a Cuadre review. Financial validation, explicit policy agreement and context-bound signature
confirmation are checked before queueing submission.

InvoiceLocalPrinting generates PDFs from locally saved invoice/company content. It now adds the confirmed local creation’s context-bound sender PNG to the authorization line when the invoice and sender identities match. Receiver signature lines remain blank. Public invoice
JSON deliberately hides signature images and personal IDs. Signature metadata
from reports/invoices/signature-options cannot reconstruct those images. The
existing server-report flow can explicitly select its stored signatures, download
the finished PDF and retain those exact bytes locally.

## Creation integration and remaining acceptance

The creation draft now selects real customer/assignment/policy inputs and preserves
its reviewed drawing and bounded PNG with the scoped draft. Capture remains
separate from agreement and keeps the portal's explicit skip choice. Changing the
signer/customer or substantive review context invalidates the confirmation.

On final review, supported sender-signature fields are frozen in the invoice
submission. Operation UUIDs and exact bytes persist before the separate
synchronization routes are attempted. Skip-payment creates no journal; positive
recorded payments confirm through the journal route before invoice completion.
Signature confirmation cannot bypass invoice/payment validation; the API resolves the accounting period when synchronizing. Tests cover
lost responses, database reopen and cross-window protection. Rejected frozen
operations retain local work for retry; editing or abandoning a partially posted
payment still requires reconciliation support.

For delivery receipts, implement the actual assigned-item review/completion flow,
including its identity and replay rules, before connecting capture. Never log
signature pixels/base64 or personal IDs. Retention must preserve every attachment
needed by a draft, pending operation, conflict or active workflow. Local documents
may include a newly captured signature only when its record/context and supported
print selection are explicit; never borrow another receipt or claim downloaded
historical signature parity.

Validation must cover scoped reopen, stale-window saves, context changes, failed
transaction rollback, exact retry bytes and image bounds with synthetic drawings.
Native device review must cover clear/retry, resizing, keyboard/pointer/touch,
large text and light/dark presentation. Signed/live submission and physical
printing remain separate acceptance checks.


## Confirmed local signature in PDF preview and printing — 2026-10-26

SQLite persists the invoice draft and its signature in the same durable
creation operation. Draft/plan JSON and the outbound invoice share the API shape
`senderSignature: { signerName, data: <bare base64>, contentType: "image/png" }`
through `invoices/sync/create`; the API creates the authoritative invoice.

Local printing only uses a signature from a completed creation associated with
that exact server invoice ID, within the scoped SQLite database. The confirmation
must still match the frozen content and the current sender ID/name. Pending or
unrelated drafts cannot supply a signature. PDFs contain separate logo and
signature image resources, preserve signature aspect ratio and reserve space above
the authorization line on each page. Preview and native printing continue to use
the same persisted PDF bytes. No signed timestamp or recipient signature is
invented. Historical server-only signatures still require the server report; the
public invoice response does not include their image data. Unsynchronized drafts
are not presented as officially created, numbered invoice PDFs.

The local image reflects the confirmed creation captured on this device. A later
server-side signature replacement/revocation cannot be proven while offline; the
server report remains authoritative for current historical signature selection.
Live API submission, native touch capture, live preview and physical printing
remain deferred by the owner. Synthetic fixture rendering checks local PDF layout.


## Shared local/API field names — 2026-10-26

Owner requires API-backed fields to keep their API names in local persistence.
`InvoiceDraft.Content.senderSignature` now uses `InvoiceSenderSignature` with
`signerName`, `data` (a bare base64 string), and `contentType`. Creation sends this
same value directly; no alternate stored `signaturePNG` field or separate request
signature type is written. `confirmation` contains only local review metadata:
context hash, policy agreement and skip choice. PNG bytes are decoded from the
shared base64 value only when needed for validation, preview or PDF rendering.

Compatible decoding reads old `confirmation.signaturePNG` values into the shared
structure. Existing review hashes remain valid because their input excludes the
signature and local confirmation, as before. New saves emit only the shared API
shape; stale review hashes remain stale and cannot authorize a different invoice.
Old queued plans can decode without changing their request UUIDs. Existing frozen
request bytes and hashes are read as stored, never rebuilt for the field rename.
