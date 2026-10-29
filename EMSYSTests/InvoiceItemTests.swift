import XCTest
@testable import EMSYS

final class InvoiceItemTests: XCTestCase {
    func testCatalogIdentifiersAreNotPresentedAsDescriptions() {
        let catalog = Invoice.Item(id: "item", name: "Box", description: "123", quantity: nil, price: nil, total: nil)
        XCTAssertEqual(catalog.displayName, "Box")
        XCTAssertNil(catalog.supportingDescription)
        let legacy = Invoice.Item(id: "item", name: nil, description: "Fragile box", quantity: nil, price: nil, total: nil)
        XCTAssertEqual(legacy.displayName, "Fragile box")
        XCTAssertNil(legacy.supportingDescription)
        let additional = Invoice.Item(id: "item", name: "Box", description: "Handle with care", quantity: nil, price: nil, total: nil)
        XCTAssertEqual(additional.supportingDescription, "Handle with care")
    }
}
