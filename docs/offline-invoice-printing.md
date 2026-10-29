# Offline invoice printing

The invoice directory Print action and the invoice detail printer action generate
and save an invoice PDF on the device, then open InvoiceGeneratedDocumentView.
The viewer uses PDFKit and has an explicit Print button. Only that button opens
the native print dialog, using the same saved PDF bytes. On iPhone/iPad the viewer
opens full screen; on macOS it opens as a resizable sheet. This follows the owner's
requested legacy preview-first interaction without copying its architecture.
These actions do not open the separate server-report InvoiceDocumentView, call
reports/invoices, or download a report.

InvoiceLocalPrinting.generate accepts only a local InvoiceStore, language and
printed-by text. It has no API client. It reads the current local invoice,
including pending edits, and company print settings from that same user/company
and API-environment database. Rendering runs outside the main actor. Existing
print permission and session-context checks run before and after generation.

While connected, opening the directory or invoice detail prepares public company
settings with companies/current and caches the logo, if configured. A new install
must download the invoice and company settings once before printing offline.
Preparation failures preserve the previous company snapshot and do not prevent
invoice browsing. Missing required print data produces a localized error rather
than an invented company name, invoice number or incomplete PDF.

## Layout reference

InvoicePDFRenderer follows the API InvoiceReportBuilder in
internal/report/builders.go and its PDFReport cell behavior:

- Letter, 612 × 792 points; 10 mm page margins.
- Standard Helvetica and Times PDF fonts, WinAnsi text, API font widths.
- Identical metadata, party columns, financial summary and item table dimensions.
- Wrapped rows with repeated invoice context on continuation pages.
- Authorization notice in the printing user's selected language.
- Blank authorization and receipt signature lines, print metadata and page totals.

The supplied one-page reference was compared locally at 2× resolution. Its 722
characters match in order; the maximum glyph position difference is under 0.005
points. Mean absolute pixel-channel difference is 0.072 on a 0–255 scale;
98.81% of pixels are identical. Tiny differences come from coordinate rounding
and combining collinear writing-area borders. The private reference and temporary
reconstruction are not repository fixtures.

The font widths derive from the MIT-licensed gofpdf dependency already used by
the API. Its notice is included in gofpdf-font-license.txt.

## Current data contract limits

The public invoice JSON intentionally does not return signature images, and
companies/current does not return company phone numbers or the report timezone.
Direct local printing therefore leaves signature lines blank, uses the device
printing timezone, and does not invent a company phone. Automatically reproducing
stored server signatures or a different server timezone requires an explicitly
scoped print-data synchronization contract. The separate existing server-document
workflow remains unchanged. This change does not expose private signatures.

## Validation

InvoiceLocalPrintingTests covers offline generation without a network client,
durable document/company settings, tenant isolation, localized authorization
text, Letter dimensions, financial fields, multipage headers and counters,
missing data, and authorization before printing. The required verification script
runs macOS, iPhone and iPad tests and macOS/iOS Release builds. Physical printer
output still depends on the selected printer and user print settings.

## Cached print independence

Directory and detail print actions use cached company settings immediately even
when a background refresh is waiting for credentials/connectivity. If no company
settings have been saved yet, an already-running first-use preparation may finish
before generation; the Print action itself starts no request. Refresh failure
preserves the last saved company and document. Regression tests suspend refresh
before any HTTP request and require both print entry points to finish and persist
their PDF before that refresh is released.


## Preview-first lifecycle

InvoicePreviewModel coalesces generation, ignores stale/revoked-session results,
and clears the document when its session changes or the viewer closes. Canceling
one preview does not cancel shared first-use company preparation. Generation
failure can be retried. PrintDocumentButton rechecks the preview's authorization
at the actual button action. Preview and print do not regenerate one another's
PDF. Regression tests cover the exact bytes, cancellation/replacement, permission
revocation, coalescing and failure/retry. Full automated verification passed in
emsys-verification.mnXSSb. Native iPhone acceptance passed on October 25 after rebuilding and running the
current open Xcode project. The invoice detail printer opened the generated
PDFKit viewer first; its explicit Print action opened native print options, and
Cancel returned to the same PDF. No print job was submitted. iPad/macOS viewer
acceptance and physical printer output remain unverified.
