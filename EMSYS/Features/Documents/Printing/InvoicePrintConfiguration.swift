import PDFKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Printing consumes the generated PDF bytes without redrawing the preview.
@MainActor
enum InvoicePrintConfiguration {
    #if os(macOS)
    static func operation(pdf: Data, base: NSPrintInfo = .shared) -> NSPrintOperation? {
        guard let document = PDFDocument(data: pdf),
              let page = document.page(at: 0),
              let info = base.copy() as? NSPrintInfo else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        info.paperSize = bounds.size
        info.orientation = bounds.width > bounds.height ? .landscape : .portrait
        info.scalingFactor = 1
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        return document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false)
    }
    #else
    static func configure(_ controller: UIPrintInteractionController, pdf: Data) {
        let info = UIPrintInfo.printInfo()
        info.jobName = "EMSYS"
        info.outputType = .general
        info.duplex = .none
        if let page = PDFDocument(data: pdf)?.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            info.orientation = bounds.width > bounds.height ? .landscape : .portrait
        }
        controller.printInfo = info
        // Original PDF bytes preserve the fonts, tables and page breaks.
        controller.printingItem = pdf
    }
    #endif
}
