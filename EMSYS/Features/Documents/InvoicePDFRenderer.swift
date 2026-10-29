import Foundation

/// Mirrors internal/report/builders.go. Financial values remain the stored
/// invoice values; rendering never settles, recalculates or uploads an invoice.
nonisolated struct InvoicePDFRenderer {
    enum RenderError: Error { case missingInvoice, missingCompany, missingAssets, oversizedContent }
    let invoice: Invoice
    let company: InvoicePrintCompany
    let language: String
    let printedBy: String
    var senderSignaturePNG: Data? = nil
    var now: Date = .now
    var timezone: TimeZone = .current
    private let widths: [Double] = [15, 140, 20, 20]

    func render() throws -> Data {
        guard let number = invoice.number, !number.isEmpty, invoice.invoiceDetails != nil else { throw RenderError.missingInvoice }
        guard !company.name.isEmpty else { throw RenderError.missingCompany }
        guard (invoice.invoiceDetails?.count ?? 0) <= 10_000 else { throw RenderError.oversizedContent }
        var canvas = InvoicePDFCanvas()
        if let logo = company.logo, !logo.isEmpty {
            guard let image = company.logoImage else { throw RenderError.missingAssets }
            try canvas.addImage(image)
        }
        if let senderSignaturePNG { try canvas.addImage(senderSignaturePNG, named: .senderSignature) }
        let notice = authorizationNotice
        let noticeLines = InvoicePDFCanvas.lines(notice, width: 195.9, font: .regular, size: 8)
        let bottom = 279.4 - 23 - Double(noticeLines.count) * 3.5 - 4 - (senderSignaturePNG == nil ? 0 : 18)
        var y = context(&canvas)
        guard y <= bottom else { throw RenderError.oversizedContent }
        for item in invoice.invoiceDetails ?? [] {
            let quantity = item.quantity ?? 0
            let values = [quantity == Decimal(NSDecimalNumber(decimal: quantity).intValue)
                ? NSDecimalNumber(decimal: quantity).stringValue : decimal(quantity), item.name ?? "", money(item.price), money(item.total)]
            let wrapped = values.enumerated().map { InvoicePDFCanvas.lines($0.element, width: widths[$0.offset] - 2, font: .times, size: 11) }
            let height = max(6, Double(wrapped.map(\.count).max() ?? 1) * 4.5 + 1)
            if y + height > bottom {
                canvas.line(10, y, 205, y)
                authorization(&canvas, lines: noticeLines, y: y + 3)
                canvas.finishPage()
                y = context(&canvas)
            }
            guard y + height <= bottom, canvas.pages.count < 1000 else { throw RenderError.oversizedContent }
            var x = 10.0
            for index in widths.indices {
                canvas.line(x, y, x, y + height)
                for (line, text) in wrapped[index].enumerated() {
                    canvas.cell(text, x: x + 1, y: y + 0.5 + Double(line) * 4.5,
                                width: widths[index] - 2, height: 4.5, font: .times, size: 11,
                                align: ["C", "L", "R", "R"][index])
                }
                x += widths[index]
            }
            canvas.line(x, y, x, y + height)
            y += height
        }
        let end = y + max(0, floor((bottom - y) / 6)) * 6
        var x = 10.0
        for width in widths { canvas.line(x, y, x, end); x += width }
        canvas.line(x, y, x, end)
        canvas.line(10, end, 205, end)
        authorization(&canvas, lines: noticeLines, y: end + 3)
        canvas.finishPage()
        let count = canvas.pages.count
        for index in canvas.pages.indices {
            canvas.content = canvas.pages[index]
            footer(&canvas, page: index + 1, count: count)
            canvas.pages[index] = canvas.content
        }
        let pdf = canvas.pdf()
        try InvoiceDocument.validate(pdf)
        return pdf
    }

    private func context(_ canvas: inout InvoicePDFCanvas) -> Double {
        let hasLogo = company.logoImage != nil
        if hasLogo { canvas.image(x: 10, y: 10, width: 76, height: 22) }
        canvas.cell(company.name, x: hasLogo ? 88 : 10, y: 13, width: 74, height: 7, font: .bold, size: 16)
        canvas.cell("No. " + (invoice.number ?? ""), x: 153.9, y: 13, width: 52, height: 7, font: .bold, size: 16, align: "R")
        var y = hasLogo ? 38.0 : 24.0
        let date = invoice.calendarDate.map { format($0, pattern: "MM/dd/yyyy", zone: .gmt) } ?? "-"
        let received = receivedBy
        for (label, value) in [("Fecha", date), ("Furgon", invoice.container?.name ?? "-"), received] {
            canvas.cell(label + ": ", x: 84, y: y, width: 32, height: 5, font: .bold, size: 12, align: "R")
            let lines = metadataLines(value.isEmpty ? "-" : value)
            for (index, line) in lines.enumerated() {
                canvas.cell(line, x: 116, y: y + Double(index) * 5, width: 89.9, height: 5, size: 12)
            }
            let height = max(5, Double(lines.count) * 5)
            canvas.line(116, y + height - 0.5, 205.9, y + height - 0.5)
            y += height + 3
        }
        y += 4
        canvas.cell("Envia:", x: 10, y: y, width: 85, height: 6, font: .bold, size: 12)
        canvas.cell("Recibe:", x: 110, y: y, width: 85, height: 6, font: .bold, size: 12)
        y += 7
        let sender = party(invoice.sender); let receiver = party(invoice.receiver)
        for index in sender.indices {
            if sender[index].isEmpty && receiver[index].isEmpty { continue }
            let left = InvoicePDFCanvas.lines(sender[index], width: 85, font: .regular, size: 10)
            let right = InvoicePDFCanvas.lines(receiver[index], width: 85, font: .regular, size: 10)
            for (column, lines) in [left, right].enumerated() {
                for (row, line) in lines.enumerated() {
                    canvas.cell(line, x: column == 0 ? 10 : 110, y: y + Double(row) * 4.5, width: 85, height: 4.5)
                }
            }
            y += Double(max(left.count, right.count)) * 4.5
        }
        y += 7
        canvas.line(10, y, 205.9, y)
        y += 4
        let summaryWidths: [Double] = [32, 32, 32, 32, 32, 35]
        tableHeader(&canvas, ["Pendiente", "Costo", "Descuento", "Recargo", "Pago", "Balance"], widths: summaryWidths, y: y)
        y += 7
        let status = invoice.paidStatus.flatMap { $0.isEmpty ? nil : $0 } ?? ((invoice.balance ?? 0) <= 0 ? "PAGADA" : (invoice.payment ?? 0) > 0 ? "PARCIAL" : "PENDIENTE")
        let values = [status, money(invoice.cost), money(invoice.discount), money(invoice.surcharge), money(invoice.payment), money(invoice.balance)]
        var x = 10.0
        for index in summaryWidths.indices {
            canvas.line(x, y, x, y + 6)
            canvas.cell(values[index], x: x, y: y, width: summaryWidths[index], height: 6, font: .times, size: 11, align: "C")
            x += summaryWidths[index]
        }
        canvas.line(x, y, x, y + 6)
        y += 6
        canvas.line(10, y, x, y)
        y += 5
        tableHeader(&canvas, ["CANT.", "DESCRIPCION", "PRECIO", "TOTAL"], widths: widths, y: y)
        return y + 7
    }

    private func tableHeader(_ canvas: inout InvoicePDFCanvas, _ headers: [String], widths: [Double], y: Double) {
        var x = 10.0
        for index in widths.indices {
            canvas.rectangle(x: x, y: y, width: widths[index], height: 7)
            canvas.cell(headers[index], x: x, y: y, width: widths[index], height: 7, font: .timesBold, size: 11, align: widths.count == 4 ? ["C", "L", "R", "R"][index] : "C")
            x += widths[index]
        }
    }

    private func authorization(_ canvas: inout InvoicePDFCanvas, lines: [String], y: Double) {
        for (index, line) in lines.enumerated() {
            canvas.cell(line, x: 10, y: y + Double(index) * 3.5, width: 195.9, height: 3.5, size: 8)
        }
    }

    private func footer(_ canvas: inout InvoicePDFCanvas, page: Int, count: Int) {
        if senderSignaturePNG != nil {
            canvas.image(x: 70, y: 240.4, width: 55, height: 17,
                         named: .senderSignature, preserveAspectRatio: true)
        }
        for (x, width, title) in [(10.0, 55.0, "Preparado por"), (70, 55, "Authorizado por"), (130, 75, "Recibido por/ Fecha/ ID")] {
            canvas.line(x, 258.4, x + width, 258.4)
            canvas.cell(title, x: x, y: 259.4, width: width, height: 4, font: .bold, size: 12, align: "C")
        }
        canvas.cell("Fecha de Impresion: " + format(now, pattern: "MM/dd/yyyy hh:mm:ss a", zone: timezone), x: 10, y: 266.9, width: 95, height: 5, font: .italic, size: 8)
        canvas.cell("Impresa por: " + printedBy, x: 105, y: 266.9, width: 100.9, height: 5, font: .italic, size: 8, align: "R")
        canvas.cell("Pagina \(page)/\(count)", x: 10, y: 271.4, width: 195.9, height: 3, size: 8, align: "C")
        if count > 1 { canvas.cell("\(page)/\(count)", x: 170.9, y: 271.4, width: 35, height: 3, size: 8, align: "R") }
    }

    private var receivedBy: (String, String) {
        let value = invoice.receivedBy
        let employee = value?.employee
        let name = [value?.name, employee?.name, value?.route?.name].compactMap { $0 }.first { !$0.isEmpty }
        let label = value?.type == "route" ? "Ruta" : value?.type == "employee" ? "Empleado" : value?.route != nil ? "Ruta" : employee != nil ? "Empleado" : "Recibido por"
        let fallback = [invoice.employee?.name, invoice.employee?.fullName, invoice.employee?.userName, invoice.employee?.email].compactMap { $0 }.first { !$0.isEmpty }
        return (label, name ?? fallback ?? "-")
    }

    private func metadataLines(_ value: String) -> [String] {
        var result: [String] = []; var current = ""; var token = ""
        func appendToken() {
            if InvoicePDFCanvas.width(current + token, font: .regular, size: 12) > 87.9, !current.isEmpty {
                result.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            }
            for character in token {
                if InvoicePDFCanvas.width(current + String(character), font: .regular, size: 12) > 87.9, !current.isEmpty {
                    result.append(current); current = ""
                }
                current.append(character)
            }
            token = ""
        }
        for character in value {
            token.append(character)
            if character == "-" || character.isWhitespace { appendToken() }
        }
        appendToken()
        if !current.isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
        return result
    }

    private func party(_ party: Invoice.Party?) -> [String] {
        let address = party?.address ?? party?.addresses?.first(where: { $0.isPrimary == true }) ?? party?.addresses?.first
        func join(_ parts: String?...) -> String { parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
        let locality = join(address?.state, address?.zipcode)
        let city = [address?.city, locality.isEmpty ? nil : locality].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        let rawPhone = party?.phones?.first?.number ?? ""
        let digits = rawPhone.filter(\.isNumber)
        let national = digits.count == 11 && digits.first == "1" ? String(digits.dropFirst()) : digits
        let phone = national.count == 10 ? "(\(national.prefix(3))) \(national.dropFirst(3).prefix(3))-\(national.suffix(4))" : rawPhone
        return [party?.name ?? "", join(address?.address1, address?.address2, address?.apartment), join(address?.address2, address?.apartment), city, phone]
    }

    private var authorizationNotice: String {
        let name = company.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = company.policyUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if language == "en" {
            return "By authorizing this service, I acknowledge that I have reviewed and agree to \(name)'s Terms & Conditions and Company Policies, available " + (url.isEmpty ? "from the company." : "at: \(url).")
        }
        return "Al autorizar este servicio, reconozco que he leído, revisado y acepto los Términos y Condiciones y las Políticas de \(name), disponibles " + (url.isEmpty ? "a través de la empresa." : "en: \(url).")
    }

    private func decimal(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "0.00"
    }
    private func money(_ value: Decimal?) -> String { "$" + decimal(value ?? 0) }
    private func format(_ date: Date, pattern: String, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
