# Native document integration contracts

## Current status — October 25

Two distinct paths now exist. Direct Print renders a new PDF from local invoice
and cached company settings; see [Offline invoice printing](offline-invoice-printing.md).
The server-report path downloads the original PDF and preserves its bytes through
storage, preview, sharing and print. Sections below describing offline generation
as unimplemented are historical planning notes, superseded by the local renderer.

Local printing currently uses blank signature lines. It cannot reproduce private
historical signatures absent from public invoice responses. Signature capture
exports bounded PNGs but is not yet connected to durable business operations or
uploads. See [Native signature workflows](native-signature-workflows.md) for
current source contracts and the integration order. No completed signature
integration or exact signed-report parity is claimed. Live/signed and physical-printer acceptance remain pending.


Reviewed the current Go report routes, `internal/report/handler.go`,
`internal/report/model.go`, and `docs/contracts/invoice-print-signatures.md`.

The report generation endpoint returns JSON, not PDF bytes. Its data contains
`reportId`, `fileName`, `url`, `expiresAt`, and optional `engine`. A native client
must obtain the document separately and persist the actual PDF, rather than
cache an expiring URL as if it were a durable offline document.

Invoice print permission and the authenticated tenant apply to report generation
and metadata choices. Signature choices come from POST
`/reports/invoices/signature-options`; only signer/receipt metadata is returned.
POST `/reports/invoices` accepts explicit per-invoice selections. Sender-only is
the portal's initial selection; receipt selection must be deliberate. Do not
guess the latest receiver or reuse another invoice's signature.

Selected private signatures are loaded only on the server. Invoice JSON does
not supply those image bytes or the actual signer's personal ID. Therefore the
current native read projection is insufficient to reproduce the authoritative
invoice PDF offline. No new native invoice renderer should claim equivalent
content by inventing missing policies, signatures or financial rules.

## Implementation sequence

1. Typed report request/result models and authenticated POST transport have been
   added with the same session-generation boundary as GET. A regression verifies
   that token refresh preserves the exact JSON body; no automatic network-failure
   replay is introduced. The invoice document UI now uses these models.
2. Add explicit signature metadata selection and enforce invoice print access.
3. Download the generated HTTPS capability URL without forwarding API bearer or
   tenant headers. Validate the PDF before committing a durable local file.
4. Associate the local file with its user, tenant, invoice, selected signatures
   and report revision. Do not expose another session's cached document.
5. Preview the saved file with native PDFKit, then share/export that same file.
   Present iOS printing and macOS PDF print operations only from user actions.
6. Preserve pending/active/explicitly retained files during eventual cleanup.

Native preview and printing APIs reviewed:

- [PDFView autoScales](https://developer.apple.com/documentation/pdfkit/pdfview/autoscales)
- [PDFDocument print operation](https://developer.apple.com/documentation/pdfkit/pdfdocument/printoperation(for:scalingmode:autorotate:))

## Implemented native workflow

Invoice details expose Documents when the existing canPrintInvoice grant is
present. Metadata comes from the existing signature-options route; the initial
selection includes the sender only. Receipt selection is explicit, including
legacy receipts. The API still enforces print permissions and validates choices.

The generated HTTPS capability URL is downloaded using a separate ephemeral
session with no API/tenant headers, cookies or cache. Redirects, non-200 results,
non-PDF content, invalid/locked/empty PDFs and documents over 20 MiB or 1,000 pages
are rejected. Streaming enforces the byte limit even without Content-Length.
These are native resource bounds, not new invoice business rules.

Validated bytes, report ID, signature selection and save time commit in one SQLite
transaction inside the existing user/tenant partition. Capability URLs and their
access tokens are not persisted. SQLite bytes remove the split-commit/orphan-file
problem for these bounded documents. The latest saved PDF can reopen offline.
An earlier PDF remains intact if generation/download/storage fails. No automatic
document cleanup is enabled; retention must preserve active/retained records.

Native PDFKit preview, iOS/iPadOS print presentation, macOS PDF print operation,
and PDF sharing/export use the saved bytes. Temporary export is managed by the
system Transferable integration; server filenames do not become local paths.
The report ID identifies the saved report revision, not an invented invoice
concurrency version. A saved PDF is an earlier generated copy, not a live view.

All 34 tests passed on macOS and iPad Simulator, including reopen/tenant isolation,
invalid-PDF rollback, credential-free download requests, invalid response types,
HTTP failure handling, unsafe URL rejection and bounded unknown-length streaming.
Logs: /private/tmp/emsys-document-mac-tests.log and
/private/tmp/emsys-document-ios-tests.log. The 20 MiB stream fixture completed as
part of these test runs; no production report was generated.

Actual report generation with an account, visual/accessibility review, physical
printing and share targets remain manual acceptance checks. Offline invoice PDF
generation still requires authoritative content that the current read projection
does not contain; saved server-generated PDFs are available offline.

The document screen rechecks its authenticated print scope before presenting
protected content and around asynchronous generation/download steps. It shows a
localized warning when the invoice has pending edits: generation uses server
information, and the saved PDF does not automatically include offline changes.
A manual upload action is available. Existing saved PDFs remain historical copies.

## Exact API invoice printing

The API-generated PDF is the invoice layout authority. The legacy SwiftUI PDF creator is historical reference only: the saved-server-document path does not rebuild the invoice from local fields, render a SwiftUI view to a screenshot, or regenerate a PDF from its preview. Download, SQLite persistence, preview, export and AirPrint retain the original PDF bytes. Signature selections and language belong in the API report request.

The supplied API reference is US Letter (612 x 792 points), portrait. macOS print operations copy per-job print settings, select the PDF's paper size, reset scaling to 100%, and disable scale-to-fit/automatic rotation. iPhone/iPad send the original saved Data to AirPrint with the PDF's orientation and single-sided output. Printer paper selection and imageable margins still require real-device acceptance; fixture tests do not establish physical printer output.

Regression coverage verifies byte-for-byte saved document recovery, multipage Letter geometry, raw AirPrint input with no formatter or page renderer, print-controller reuse, and macOS paper/scale settings without changing shared printer preferences. Customer reference PDFs are not committed to the repository.


## Required offline generation

Offline support must include generating a new PDF from the current local invoice,
not only reopening a previously downloaded report. A saved API PDF is a historical
copy and cannot represent unsynchronized edits. The local generation path remains
unimplemented; the current Generate action requires connectivity.

Use a native vector PDF renderer, with the Go InvoiceReportBuilder as the layout
specification and the legacy SwiftUI PdfCreator as a native implementation
reference. Preserve Letter dimensions, exact column geometry, font metrics,
wrapping, repeated invoice identity on continuation pages, terms language, signature
placement and print metadata. Do not treat the legacy layout as equivalent to the
current API layout. Compare deterministic synthetic API/native fixtures, including
long metadata, multiline items, signatures and multipage invoices, before claiming
visual parity.

Persist an authorized user/company-scoped print snapshot with the full invoice
parties and addresses, financial totals, container/route context, company name,
phone, policy text/URL, timezone and required logo assets. The current small list
projection and name-only local drafts do not contain all these fields. Selected
private signature images are also absent from the existing public responses; an
explicit authorized synchronization contract is required to make them available
locally. Missing assets must be handled explicitly, never silently substituted or
borrowed from another invoice/company.

Build printable content from the local snapshot plus supported pending edits;
retain invoice revision and template version with generated documents so stale
copies can be identified. Local drafts have no server invoice number: never
invent an official number, financial status, paid amount or receipt signature.
Local generation must preserve the established session/print-permission boundary
and produce saved PDF bytes used unchanged by preview, sharing and native print.
