import XCTest

final class BookNexusUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Reproduction: open +, tap the pending-scans link, and confirm the
    /// "Add books" import flow actually presents instead of hanging.
    func testPendingScanImportOpens() throws {
        let app = XCUIApplication()
        app.launch()

        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Add toolbar button missing")
        add.tap()

        let link = app.buttons.matching(NSPredicate(format: "label CONTAINS 'not yet added'")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "pending scan link missing")
        link.tap()

        let nav = app.navigationBars["Add books"]
        XCTAssertTrue(nav.waitForExistence(timeout: 10), "Add books screen did not appear — flow hung")

        // The first import page is a Form; its content must actually render,
        // not just the nav bar. A stalled page means the paging TabView hung.
        let titleField = app.textFields["Title *"]
        if !titleField.waitForExistence(timeout: 10) {
            print("ON-SCREEN ELEMENTS:\n\(app.debugDescription)")
        }
        XCTAssertTrue(titleField.exists, "import page content did not render — flow hung")
    }
}
