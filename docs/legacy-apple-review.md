# Legacy Apple review — Milestone 2

Reviewed `/Users/hectorm/Workspace/xcode/emsysApp` selectively on October 24, 2026.
Current portal/API contracts supersede legacy authentication and invoice rules.

| Area | Evidence | Modernization decision |
| --- | --- | --- |
| Signature capture | `OldFolders/Signature/Views/SignatureView2.swift`: PencilKit canvas, clear action, image export, fixed 400-point width, forced landscape, signature logged as base64. | Reuse the capture concept, not the implementation. Use adaptive capture with clear/retry and explicit confirmation; never log images. Persist locally before queuing upload. Support macOS pointer input separately from UIKit. |
| Prototype | `OldFolders/Signature/Views/SignatureView.swift` declares `SignatureView3` and displays placeholder text. | Do not migrate unused prototypes. |
| PDF creation | `Shared/Models/Pdf/PdfCreator.swift`: `UIGraphicsPDFRenderer`, mutable drawing coordinates, line items, totals, signature line, watermark and page calculations. | Treat output as a historical visual reference. Current API document content, policy text and signature selection are authoritative. Separate immutable document input from rendering and paginate long content explicitly. Use platform-independent Core Graphics where practical. |
| PDF model | `Shared/ViewModels/Pdf/PdfViewModel.swift`: renders PDF again through `pdfData()` and increases page height based on item count. | Render once per document revision, persist the result, and preview/share the same file. Use real page boundaries instead of indefinitely increasing page height. |
| Preview/share | `Shared/Views/Pdf/PdfPreviewView.swift`, `ShareView.swift`, `PdfViewUI.swift`: PDFKit/UIKit adapters and activity sheet. | Retain PDFKit as a native preview approach, with iOS/macOS wrappers and accessible actions. Share/export a durable file through native presentation. |
| Printing | PDF output can participate in native sharing. This selective review did not establish a complete direct-print implementation. | Implement explicit iOS print presentation and macOS printing. Verify actual printers separately; do not report simulator checks as printer validation. |

## Integration order

1. Establish authenticated tenant-scoped local invoice data and attachment ownership.
2. Capture signature strokes and a bounded PNG locally; associate record, user and
   tenant without claiming a server signing time.
3. Submit only the fields permitted by each current signature endpoint. Sender
   signature and delivery receiver receipt are distinct operations.
4. Preview cached authoritative server PDFs when available. Offline generation
   needs equivalent current business content; private historical signature bytes
   are deliberately absent from invoice JSON and cannot be reconstructed.
5. Persist generated documents before preview, sharing and printing. Keep files
   needed by pending work and apply retention only after eligibility checks.

No legacy authentication, orientation forcing, payload logging, prototype names,
or UIKit-only business architecture should be copied into the new app. Review
completed; native integration implementation belongs to Milestone 6.

## October 25 — list design and code-style reference

The owner specifically asked that this code inform both interface composition and
coding style. Reviewed these additional sources before further screen work:

| Legacy source | Useful reference | Apply in current native screens |
| --- | --- | --- |
| `Shared/Views/Invoice/InvoiceRow.swift` | Small initials badge, strong invoice number, quieter sender/container/date, trailing balance and textual status. | Preserve the information hierarchy and restrained density. Use current server fields/status semantics, accessible type and native appearance colors. Do not infer a currency or status from historical formatting. |
| `Shared/Views/Invoice/InvoiceDetailRow.swift` | A focused item component, description/total and secondary quantity/unit-price information. | Keep coherent row responsibilities and readable alignment. The owner's newer approved detail composition takes precedence: description first, quantity left and amount right below. |
| `Shared/Views/Customers/CustomerRow.swift` | Primary customer name, grouped phone/address metadata, explicit selection checkmark, loading placeholders. Private `panel` extraction keeps the main selection branch readable. | Use descriptive properties and small private view sections. Keep names and addresses legible; native Button/selection semantics, safe optional handling and actual local loading state replace force unwraps or copied fetching architecture. |
| `Shared/Views/Invoice/InvoiceList.swift` | Separate row component, localized title and light/dark previews. This particular file also contains commented experiments/placeholder content. | Selectively preserve the working composition and preview coverage; do not migrate placeholders, commented-out alternatives or old navigation/data ownership. |

The current `InvoiceListRow` already separates row composition from loading and
uses invoice identity/customer metadata/trailing balance. This is source review,
not visual acceptance of the new row. Phone width, long names, large text and
light/dark appearance must be inspected in the actual application. Code examples
are references for clarity rather than a requirement to repeat every old modifier,
MARK comment, optional fallback or API.


## October 25 — preview before printing

Reviewed Shared/Views/Invoice/InvoicePreview.swift, Shared/Views/Pdf/PdfPreviewView.swift,
PdfViewUI.swift and ShareView.swift after the owner's request. The invoice printer
icon toggles showPdfPreview and presents PdfPreviewView through fullScreenCover.
PdfViewUI hosts a PDFKit PDFView with autoScales enabled. The supplied legacy
preview provides sharing through UIActivityViewController, which exposes printing.
The current native app now preserves the requested preview-first sequence with a
dedicated Print button in its PDF viewer. Its own local generator and original
saved PDF bytes remain the source of preview and print content. Do not copy the
legacy data ownership, force unwraps or old authentication as part of this flow.
