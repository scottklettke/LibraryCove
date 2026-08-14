import XCTest

final class BookNexusUITests: XCTestCase {
    /// JSON matching `[CatalogBook]` used to seed `PendingScanStore` via the
    /// `UI_TEST_PENDING_SCANS` launch environment, so the import flow is
    /// testable offline without a camera. Two books lets tests observe a
    /// drop from "2 remaining" to "1 remaining".
    private let pendingScansSeed = #"""
    [{"id":"seed-1","title":"The Swift Programming Language","authors":["Apple Inc."],"isbn":"9780137463602","publicationYear":2021,"genres":["Programming"],"publisher":"Addison-Wesley","pageCount":560,"description":"The definitive guide.","language":"en","coverURLs":[],"descriptionSource":"openlibrary","source":"seed"},
     {"id":"seed-2","title":"Designing Data-Intensive Applications","authors":["Martin Kleppmann"],"isbn":"9781449373320","publicationYear":2017,"genres":["Databases"],"publisher":"O'Reilly","pageCount":616,"description":"Reliable systems book.","language":"en","coverURLs":[],"descriptionSource":"openlibrary","source":"seed"}]
    """#

    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Camera permission is usually auto-granted on the simulator, but be
        // safe if a system permission alert ever appears.
        addUIInterruptionMonitor(withDescription: "Camera permission") { alert in
            if alert.buttons["Allow"].exists {
                alert.buttons["Allow"].tap()
                return true
            }
            return false
        }
    }

    private func pendingScansApp() -> XCUIApplication {
        let app = baseApp()
        app.launchEnvironment["UI_TEST_PENDING_SCANS"] = pendingScansSeed
        return app
    }

    /// App with UI-test hygiene: fresh library (no duplicate/leftover records
    /// across runs) and the scan/import seeds wired in by the caller.
    private func baseApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_DATA"] = "1"
        return app
    }

    /// Fresh installs land on the login screen; create a local user so the
    /// library tab (with its toolbar) is reachable.
    private func enterLibraryIfNeeded(_ app: XCUIApplication) {
        let enter = app.buttons["Enter library"]
        if enter.waitForExistence(timeout: 5) {
            enter.tap()
        }
    }

    private func openScanner(_ app: XCUIApplication) {
        // "Scan ISBN" may be in the toolbar directly or folded into the
        // "More" overflow on narrow screens.
        let scan = app.buttons["Scan ISBN"]
        if !scan.waitForExistence(timeout: 5) {
            let more = app.buttons["More"]
            XCTAssertTrue(more.waitForExistence(timeout: 3), "could not find Scan ISBN")
            more.tap()
            XCTAssertTrue(scan.waitForExistence(timeout: 3), "Scan ISBN not in overflow menu")
        }
        scan.tap()
    }

    /// Camera mode must offer a way to cancel and return to the Add screen.
    func testScannerHasCancel() throws {
        let app = pendingScansApp()
        app.launch()
        enterLibraryIfNeeded(app)
        openAddSheet(app)
        openScanner(app)

        let close = app.buttons["Close scanner"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "scanner has no cancel button")
        close.tap()

        XCTAssertTrue(app.navigationBars["Add a book"].waitForExistence(timeout: 10),
                      "did not return to the Add screen after cancelling the scanner")
    }

    /// "Add all" after scanning must land on the import/edit/swipe screen and
    /// actually add the books (not just claim they were added).
    func testAddAllOpensImportFlowAndAddsBooks() throws {
        let app = baseApp()
        app.launchEnvironment["UI_TEST_SCANNED_BOOKS"] = pendingScansSeed
        app.launch()
        enterLibraryIfNeeded(app)
        openAddSheet(app)
        openScanner(app)

        // Scanned books seeded → "Add all" is enabled.
        let addAll = app.buttons["Add all"]
        XCTAssertTrue(addAll.waitForExistence(timeout: 10), "Add all button missing")
        XCTAssertTrue(addAll.isEnabled, "Add all expected enabled with scanned books")
        addAll.tap()

        // The import/edit/swipe screen must appear with both books.
        XCTAssertTrue(app.navigationBars["2 remaining"].waitForExistence(timeout: 10),
                      "Add all did not open the import flow")

        addAllRemainingBooks(app)

        // Flow completes → returns to the library with both books actually
        // present in the grid/list (asserting the book title text).
        let first = app.staticTexts["The Swift Programming Language"]
        let second = app.staticTexts["Designing Data-Intensive Applications"]
        XCTAssertTrue(first.waitForExistence(timeout: 10),
                      "imported book missing from library — books claimed added but not saved")
        XCTAssertTrue(second.exists,
                      "second imported book missing from library")
    }

    /// Reads the import flow's "N remaining" title (nil once the flow is gone).
    private func remainingCount(_ app: XCUIApplication) -> Int? {
        for nav in app.navigationBars.allElementsBoundByIndex {
            let label = nav.identifier
            if let space = label.firstIndex(of: " "),
               let n = Int(label[..<space]) {
                return n
            }
        }
        return nil
    }

    /// Taps "Add to library" for every queued book in the import flow, scrolling
    /// each form's save button into view, until the flow closes. The button
    /// lives at the bottom of a lazily-rendered form, so it is scrolled for
    /// BEFORE checking existence. Waits for the queue to shrink between taps so
    /// it never double-taps the same page (which trips the duplicate-alert path
    /// instead of advancing).
    private func addAllRemainingBooks(_ app: XCUIApplication) {
        for _ in 0..<6 {
            let addButton = app.buttons["Add to library"]
            var scrolls = 0
            while !addButton.isHittable && scrolls < 6 {
                app.swipeUp()
                scrolls += 1
            }
            guard addButton.isHittable else { break }
            let current = remainingCount(app) ?? 0
            addButton.tap()
            if current > 1 {
                guard app.navigationBars["\(current - 1) remaining"].waitForExistence(timeout: 10) else { break }
            } else {
                break // last book: the flow completes and dismisses to the library
            }
        }
    }

    /// Seeds and imports both books via the pending-scan banner, leaving the
    /// test on the library (grid view by default) with the books present.
    private func addSeededBooks(_ app: XCUIApplication) {
        openImportFlow(app)
        addAllRemainingBooks(app)
        XCTAssertTrue(app.staticTexts["The Swift Programming Language"].waitForExistence(timeout: 10),
                      "seeded books not imported")
    }

    /// Sorting by "date added" must show the add date in the grid just like
    /// the list view does (regression guard for the grid-cell subtitle).
    func testGridShowsAddedDateWhenSortingByDate() throws {
        let app = pendingScansApp()
        app.launch()
        enterLibraryIfNeeded(app)
        addSeededBooks(app)

        // The sort menu is a dedicated toolbar button labelled with the
        // current sort — default "Title (A–Z)" — not an overflow item.
        let sortMenu = app.buttons["Title (A–Z)"]
        XCTAssertTrue(sortMenu.waitForExistence(timeout: 10), "sort menu missing in toolbar")
        sortMenu.tap()
        // When not currently date-sorted the option reads "Date added (oldest)"
        // (it toggles toward newest-first).
        let dateSort = app.buttons["Date added (oldest)"]
        XCTAssertTrue(dateSort.waitForExistence(timeout: 5), "date-added sort option missing")
        dateSort.tap()

        // Each grid cell (still the active view) now shows a short-form date.
        let dateText = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "^[0-9]{1,2}[-/ ][0-9]{1,2}[-/ ][0-9]{2,4}$")
        ).firstMatch
        XCTAssertTrue(dateText.waitForExistence(timeout: 5),
                      "added date not shown in grid when sorting by date added")
    }

    /// Presents the AddBookView sheet. On an empty library a dedicated
    /// "Add a book" FAB is shown; otherwise the toolbar "Add" — which may
    /// overflow into the "More" menu on narrow screens.
    private func openAddSheet(_ app: XCUIApplication) {
        let fab = app.buttons["Add a book"]
        if fab.waitForExistence(timeout: 5) {
            fab.tap()
        } else {
            let add = app.buttons["Add"]
            if add.waitForExistence(timeout: 3) {
                add.tap()
            } else {
                let more = app.buttons["More"]
                XCTAssertTrue(more.waitForExistence(timeout: 3), "could not find a way to add a book")
                more.tap()
                let overflowAdd = app.buttons["Add"]
                XCTAssertTrue(overflowAdd.waitForExistence(timeout: 3), "Add not in overflow menu")
                overflowAdd.tap()
            }
        }
    }

    private func openImportFlow(_ app: XCUIApplication) {
        openAddSheet(app)

        let link = app.buttons.matching(NSPredicate(format: "label CONTAINS 'not yet added'")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "pending scan link missing")
        link.tap()

        // Seeded with two pending books → the import pager shows "2 remaining".
        XCTAssertTrue(app.navigationBars["2 remaining"].waitForExistence(timeout: 10),
                      "import flow did not appear — pager hung")
    }

    /// Reproduction: open +, tap the pending-scans link, and confirm the
    /// "Add books" import flow actually presents instead of hanging.
    func testPendingScanImportOpens() throws {
        let app = pendingScansApp()
        app.launch()
        enterLibraryIfNeeded(app)
        openImportFlow(app)

        // The first import page is a Form; its content must actually render,
        // not just the nav bar. A stalled page means the paging TabView hung.
        let titleField = app.textFields["Title *"]
        if !titleField.waitForExistence(timeout: 10) {
            print("ON-SCREEN ELEMENTS:\n\(app.debugDescription)")
        }
        XCTAssertTrue(titleField.exists, "import page content did not render — flow hung")
    }

    /// The import form (edit a scanned book before adding) must offer a
    /// Delete action that drops the book from the queue without saving it.
    func testDeletePendingBookInImportFlow() throws {
        let app = pendingScansApp()
        app.launch()
        enterLibraryIfNeeded(app)
        openImportFlow(app)

        // The delete (trash) button must be present on the import form.
        // The delete (trash) button must be present on the import form.
        let nav = app.navigationBars["2 remaining"]
        let trash = nav.buttons.matching(NSPredicate(format: "label CONTAINS 'rash'")).firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 10), "no delete button on import form")
        trash.tap()

        let alert = app.alerts["Delete this book?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "delete confirmation did not appear")
        alert.buttons["Delete"].tap()

        // One book dropped → seeded two originals, remaining shows 1.
        XCTAssertTrue(app.navigationBars["1 remaining"].waitForExistence(timeout: 10),
                      "book was not dropped from the import queue")
    }

    /// Settings must expose all three data-management options.
    func testSettingsShowsDataOptions() throws {
        let app = pendingScansApp()
        app.launch()
        enterLibraryIfNeeded(app)
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["Export library"].waitForExistence(timeout: 10), "Export row missing")
        XCTAssertTrue(app.buttons["Import library"].exists, "Import row missing")
        XCTAssertTrue(app.buttons["Delete all data"].exists, "Delete row missing")

        // Export actually builds the zip and presents the share sheet.
        app.buttons["Export library"].tap()
        XCTAssertTrue(app.staticTexts["Library export ready"].waitForExistence(timeout: 10),
                      "export share sheet did not appear")
        XCTAssertTrue(app.buttons["Save or share export"].exists, "share button missing")
        app.buttons["Done"].tap()
    }

    /// Deleting everything is guarded by two warnings and a typed confirmation.
    func testDeleteAllDataRequiresTypedConfirmation() throws {
        let app = pendingScansApp()
        app.launch()
        enterLibraryIfNeeded(app)
        app.tabBars.buttons["Settings"].tap()

        let deleteRow = app.buttons["Delete all data"]
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 10), "Delete row missing")

        // First warning: a confirmation dialog must appear before anything else.
        deleteRow.tap()
        let dialogContinue = app.buttons["Continue"]
        XCTAssertTrue(dialogContinue.waitForExistence(timeout: 5), "first warning dialog missing")
        dialogContinue.tap()

        // Second warning: the destructive button stays disabled until exactly
        // "DELETE" is typed.
        let confirmButton = app.buttons["Permanently delete and start fresh"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5), "typed-confirmation sheet missing")
        XCTAssertFalse(confirmButton.isEnabled, "delete button should be disabled until DELETE is typed")

        // An explicit Cancel must dismiss the sheet without deleting anything.
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.exists, "delete-confirmation sheet has no Cancel button")
        cancel.tap()
        XCTAssertTrue(confirmButton.waitForNonExistence(timeout: 5), "Cancel did not dismiss the sheet")

        // Re-open and run the typed-confirmation path to completion.
        deleteRow.tap()
        XCTAssertTrue(dialogContinue.waitForExistence(timeout: 5), "first warning dialog missing (re-open)")
        dialogContinue.tap()
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5), "typed-confirmation sheet missing (re-open)")
        XCTAssertFalse(confirmButton.isEnabled, "delete button should be disabled until DELETE is typed")

        let field = app.textFields["Type DELETE"]
        field.tap()
        field.typeText("DELET")
        XCTAssertFalse(confirmButton.isEnabled, "button must require the full word DELETE")

        field.typeText("E")
        XCTAssertTrue(confirmButton.isEnabled, "button should enable once DELETE is typed")

        confirmButton.tap()

        // Data (including the active member) is gone → back to the login screen.
        XCTAssertTrue(app.buttons["Enter library"].waitForExistence(timeout: 10),
                      "library was not reset — login screen expected")
    }

    /// The Ask AI tab must exist and, with no AI engine configured on the
    /// simulator, sending a question surfaces the graceful settings-hint
    /// error instead of crashing or hanging.
    func testAskAIReachableAndShowsGracefulEngineError() throws {
        let app = baseApp()
        app.launch()
        enterLibraryIfNeeded(app)

        let tab = app.tabBars.buttons["Ask AI"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Ask AI tab missing")
        tab.tap()
        XCTAssertTrue(app.navigationBars["Ask AI"].waitForExistence(timeout: 5),
                      "Ask AI screen did not present")

        // A suggestion chip pre-fills the input; send it.
        let chip = app.buttons["What should I read next?"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "suggestion chip missing")
        chip.tap()
        let send = app.buttons["Send"]
        XCTAssertTrue(send.isEnabled, "send should enable after a suggestion is picked")
        send.tap()

        // No engine configured → the graceful fallback error, not a hang.
        XCTAssertTrue(app.staticTexts["AI isn't ready. Set up an engine in Settings → AI."]
            .waitForExistence(timeout: 15), "graceful engine error did not appear")

        // A visible way back to the library must exist and actually switch tabs.
        let back = app.buttons["Back to library"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no exit button on Ask AI")
        back.tap()
        XCTAssertTrue(app.navigationBars["Ask AI"].waitForNonExistence(timeout: 5),
                      "still on Ask AI after pressing exit")
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected,
                      "Library tab not selected after exiting Ask AI")
    }

    /// The OpenAI engine is now "OpenAI-compatible endpoint", needs only an
    /// endpoint URL (API key optional, no save button — it persists as you
    /// type), and Settings shows a connection-logs section. This is the
    /// surface the user relies on to wire up a local endpoint.
    func testAISettingsExposeKeylessOpenAIConfigAndLogs() throws {
        let app = baseApp()
        app.launch()
        enterLibraryIfNeeded(app)
        app.tabBars.buttons["Settings"].tap()

        // Engine is openAI by default → the picker reads the new name.
        var scrolls = 0
        while !app.staticTexts["OpenAI-compatible endpoint"].exists && scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(app.staticTexts["OpenAI-compatible endpoint"].exists,
                      "engine picker not showing OpenAI-compatible endpoint")

        // Bring the endpoint fields fully into view, then assert the keyless
        // configuration surface (no save button needed).
        if scrolls < 2 { app.swipeUp() }
        XCTAssertTrue(app.textFields["aiEndpointField"].waitForExistence(timeout: 5),
                      "Endpoint URL field missing")
        XCTAssertTrue(app.secureTextFields["aiAPIKeyField"].exists,
                      "optional API key field missing")
        XCTAssertTrue(app.buttons["Test connection"].exists,
                      "Test connection button missing")
        // LabeledContent("Saved") surfaces as one combined element.
        XCTAssertTrue(app.staticTexts["Saved, Automatically as you type"].exists,
                      "saved-automatically feedback missing")

        // Connection logs section sits below the AI section.
        scrolls = 0
        while !app.staticTexts["AI connection logs"].exists && scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(app.staticTexts["AI connection logs"].exists,
                      "AI connection logs section missing")
    }

    /// The AI settings must surface the tokens/second indicator option
    /// (persistence and the toggle binding are covered by unit tests).
    func testAISettingsExposesTokenRateToggle() throws {
        let app = baseApp()
        app.launch()
        enterLibraryIfNeeded(app)
        app.tabBars.buttons["Settings"].tap()

        // The AI section sits below Profile/Data/Sync; scroll until the option
        // comes into view.
        let row = app.switches["Show tokens/second"]
        var scrolls = 0
        while !row.waitForExistence(timeout: 2) && scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(row.exists, "token-rate toggle missing in AI settings")
    }

    /// Genre cleanup over an engine-less simulator must show the error state
    /// with a Retry, not a blank sheet.
    func testGenreCleanupShowsErrorStateWithRetry() throws {
        let app = baseApp()
        app.launch()
        enterLibraryIfNeeded(app)

        // "Clean up genres…" lives in the toolbar's Genre menu.
        let genreMenu = app.buttons["Genre"]
        XCTAssertTrue(genreMenu.waitForExistence(timeout: 10), "Genre menu missing in toolbar")
        genreMenu.tap()
        let cleanup = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Clean up genres'")
        ).firstMatch
        XCTAssertTrue(cleanup.waitForExistence(timeout: 5), "Clean up genres menu item missing")
        cleanup.tap()

        // With no engine configured the sheet shows the error state and Retry.
        XCTAssertTrue(app.navigationBars["Clean up genres"].waitForExistence(timeout: 10),
                      "clean-up sheet did not present")
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 15),
                      "error state with Retry did not appear")
    }
}
