import XCTest

final class BookNexusUITests: XCTestCase {
    /// JSON matching `[CatalogBook]` used to seed `ScanQueueStore` via the
    /// `UI_TEST_PENDING_SCANS` launch environment, so the import flow is
    /// testable offline without a camera. Two books lets tests observe a
    /// drop from "2 remaining" to "1 remaining".
    private let pendingScansSeed = #"""
    [{"id":"seed-1","title":"The Swift Programming Language","authors":["Apple Inc."],"isbn":"9780137463602","publicationYear":2021,"tags":["Programming"],"publisher":"Addison-Wesley","pageCount":560,"description":"The definitive guide.","language":"en","coverURLs":[],"descriptionSource":"openlibrary","source":"seed"},
     {"id":"seed-2","title":"Designing Data-Intensive Applications","authors":["Martin Kleppmann"],"isbn":"9781449373320","publicationYear":2017,"tags":["Databases"],"publisher":"O'Reilly","pageCount":616,"description":"Reliable systems book.","language":"en","coverURLs":[],"descriptionSource":"openlibrary","source":"seed"}]
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

    /// Selection mode must offer an obvious exit: a prominent Cancel on the
    /// leading edge — previously the only way out was "Done" buried in the
    /// overflow "…" menu.
    func testSelectionModeShowsProminentCancel() throws {
        let app = pendingScansApp()
        app.launch()
        enterLibraryIfNeeded(app)
        addSeededBooks(app)

        let select = app.buttons["Select"]
        if !select.waitForExistence(timeout: 10) {
            let more = app.buttons["More"]
            XCTAssertTrue(more.waitForExistence(timeout: 3), "Select missing from toolbar")
            more.tap()
            XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 3), "Select not in overflow")
        }
        app.buttons["Select"].tap()

        let cancel = app.buttons["cancelSelection"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10),
                      "selection mode has no prominent Cancel button")

        // The selected count must be fully readable. It used to sit in the
        // toolbar where iOS clipped "1 selected" down to "1 s…"; it now
        // lives in the full-width bar along the bottom.
        app.staticTexts["Designing Data-Intensive Applications"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5),
                      "selection count missing or truncated")

        cancel.tap()

        // Back to the normal toolbar: Select is reachable again and the
        // selection-mode Cancel is gone.
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 10)
                          || app.buttons["More"].exists,
                      "toolbar did not restore after cancelling selection")
        XCTAssertFalse(app.buttons["cancelSelection"].exists,
                       "Cancel survived exiting selection mode")
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
            // The pager can re-render (element identities change) under slow
            // first-run conditions. Re-resolve, wait, and retry the tap a few
            // times so a mid-transition vanish never aborts the whole flow.
            var tapped = false
            for _ in 0..<3 where !tapped {
                let target = app.buttons["Add to library"]
                if target.waitForExistence(timeout: 3), target.isHittable {
                    target.tap()
                    tapped = true
                } else {
                    app.swipeUp()
                }
            }
            guard tapped else { break }
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

        // The banner always opens the pending-scan review list (every status —
        // ready, resolving, or failed), not a no-op; "Add all" hands importable
        // books to the pager. Seeded with two pending books → 2 remaining.
        XCTAssertTrue(app.navigationBars["Pending scans"].waitForExistence(timeout: 10),
                      "pending-scan review did not open")
        let addAll = app.buttons["Add all"]
        XCTAssertTrue(addAll.waitForExistence(timeout: 5), "Add all missing on review")
        addAll.tap()

        let twoRemaining = app.navigationBars["2 remaining"]
        if !twoRemaining.waitForExistence(timeout: 10) {
            print("IMPORT-FLOW STATE:\n\(app.debugDescription)")
        }
        XCTAssertTrue(twoRemaining.exists, "import flow did not appear — pager hung")
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

    /// Regression: tapping the pending-scans banner must always do something,
    /// even when no scan has finished looking up. The old code silently
    /// returned when nothing was importable. The review opens with every
    /// non-importable scan visible and actionable (status review + Remove).
    func testPendingScanBannerOpensReviewWhenLookupUnresolved() throws {
        let app = baseApp()
        app.launchEnvironment["UI_TEST_PENDING_ISBNS"] = "9780000000001"
        app.launch()
        enterLibraryIfNeeded(app)

        openAddSheet(app)
        let link = app.buttons.matching(NSPredicate(format: "label CONTAINS 'not yet added'")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "pending scan link missing")
        link.tap()

        // Review list presents even though nothing is importable — and "Add all"
        // is correctly disabled (the previous no-op behavior is gone).
        XCTAssertTrue(app.navigationBars["Pending scans"].waitForExistence(timeout: 10),
                      "banner with unresolved scan did not open the review")
        let addAll = app.buttons["Add all"]
        XCTAssertTrue(addAll.exists, "Add all button missing")
        XCTAssertFalse(addAll.isEnabled, "Add all must be disabled with nothing importable")

        // The unresolved scan is visible and opens its status review sheet.
        let failedRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Review ISBN 9780000000001'")
        ).firstMatch
        XCTAssertTrue(failedRow.waitForExistence(timeout: 10), "unresolved scan row missing")
        failedRow.tap()
        XCTAssertTrue(app.navigationBars["ISBN 9780000000001"].waitForExistence(timeout: 10),
                      "status review did not open for unresolved scan")

        // Removing from the scan list clears it; the review shows its empty state.
        let remove = app.buttons["Remove from scan list"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "remove action missing")
        remove.tap()
        XCTAssertTrue(app.staticTexts["No pending scans"].waitForExistence(timeout: 10),
                      "review should show empty state after removing the last scan")
    }

    /// Regression for the reported "stuck looking up" bug: a real queued ISBN
    /// background lookup must leave the "Looking up" state (ready, unavailable,
    /// or failed) rather than spin forever. Seeded via the live-lookup seam so
    /// the full camera→queue→catalog path runs without a camera. Any terminal
    /// status is acceptable; the test fails only if the item is still resolving
    /// after a generous window. Network is not required: an offline simulator
    /// fails the lookup fast (.failed), which also leaves the state.
    func testLiveLookupLeavesLookingUpState() throws {
        let app = baseApp()
        app.launchEnvironment["UI_TEST_LIVE_LOOKUP_ISBNS"] = "9780137463602"
        app.launch()
        enterLibraryIfNeeded(app)
        openAddSheet(app)

        let link = app.buttons.matching(NSPredicate(format: "label CONTAINS 'not yet added'")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "pending scan link missing")
        link.tap()
        XCTAssertTrue(app.navigationBars["Pending scans"].waitForExistence(timeout: 10),
                      "pending-scan review did not open")

        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Review ISBN 9780137463602'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "queued scan row missing")

        let lookingUp = app.staticTexts["Looking up ISBN 9780137463602…"]
        guard lookingUp.waitForExistence(timeout: 5) else { return } // already resolved
        let deadline = Date().addingTimeInterval(45)
        while lookingUp.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertFalse(lookingUp.exists,
                       "lookup still spinning after 45s — background processor never resolved it")
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

        // The conversation persists across launches; clear any leftover chat so
        // the chips deterministically start from the empty state.
        let clear = app.buttons["Clear conversation"]
        if clear.waitForExistence(timeout: 3), clear.isEnabled {
            clear.tap()
        }

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
        // The Model picker (auto-detect / server-reported override) must be
        // part of the keyless configuration surface.
        XCTAssertTrue(app.descendants(matching: .any)["aiModelPicker"].firstMatch.exists,
                      "Model picker missing in AI settings")
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

    /// The Author filter is a searchable multi-select sheet: search, tap a
    /// result, and the selection filters the library with a removable chip.
    func testAuthorFilterSearchAndMultiSelect() throws {
        let app = pendingScansApp()
        app.launch()
        enterLibraryIfNeeded(app)
        addSeededBooks(app) // imports "Apple Inc." + "Martin Kleppmann"

        let author = app.buttons["Author"]
        XCTAssertTrue(author.waitForExistence(timeout: 10), "Author filter button missing")
        author.tap()
        // A first-run tap can be swallowed while the toolbar settles — retry once.
        if !app.navigationBars["Authors"].waitForExistence(timeout: 3) {
            author.tap()
        }
        XCTAssertTrue(app.navigationBars["Authors"].waitForExistence(timeout: 10),
                      "author filter sheet did not open")
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "search field missing in filter")
        search.tap()
        search.typeText("Martin")

        let martin = app.buttons["Martin Kleppmann"]
        XCTAssertTrue(martin.waitForExistence(timeout: 5), "search result not shown")
        martin.tap()
        app.buttons["Done"].tap()

        // Only the matching book remains, with a removable chip.
        XCTAssertTrue(app.staticTexts["Designing Data-Intensive Applications"].waitForExistence(timeout: 10),
                      "matching book missing after filter")
        XCTAssertTrue(app.staticTexts["Author: Martin Kleppmann"].waitForExistence(timeout: 5),
                      "selected-author chip missing")
        XCTAssertFalse(app.staticTexts["The Swift Programming Language"].exists,
                       "non-matching book should be filtered out")

        // Removing the chip clears the filter.
        let remove = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Remove Author'")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "chip remove button missing")
        remove.tap()
        XCTAssertTrue(app.staticTexts["The Swift Programming Language"].waitForExistence(timeout: 10),
                      "filter not cleared after removing chip")
    }

    /// The About & Feedback screen is reachable from Settings and surfaces the
    /// app's open-source attributions and roadmap (the new disclosure/changelog
    /// surface must exist and be navigable).
    func testAboutReachableAndShowsDisclosures() throws {
        let app = baseApp()
        app.launch()
        enterLibraryIfNeeded(app)
        app.tabBars.buttons["Settings"].tap()

        let about = app.buttons["About & Feedback"]
        var scrolls = 0
        while !about.exists && scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(about.waitForExistence(timeout: 10), "About & Feedback row missing")
        about.tap()
        XCTAssertTrue(app.navigationBars["About & Feedback"].waitForExistence(timeout: 10),
                      "About screen did not open")
        // Open-source attribution for the bundled MarkdownUI dependency.
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'MarkdownUI'")
        ).firstMatch.waitForExistence(timeout: 5), "open-source disclosure missing")
        let roadmap = app.staticTexts["Coming in the future"]
        var roadScrolls = 0
        while !roadmap.exists && roadScrolls < 8 {
            app.swipeUp()
            roadScrolls += 1
        }
        XCTAssertTrue(roadmap.waitForExistence(timeout: 5), "roadmap section missing")
        // The changelog page is reachable and shows bundled content.
        let changelog = app.buttons["Changelog"]
        var changelogScrolls = 0
        while !changelog.exists && changelogScrolls < 8 {
            app.swipeUp()
            changelogScrolls += 1
        }
        XCTAssertTrue(changelog.waitForExistence(timeout: 5), "Changelog link missing")
        changelog.tap()
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'BookNexus'")
        ).firstMatch.waitForExistence(timeout: 5), "changelog did not render")
    }

    /// Long-pressing a grid book opens a manual assignment menu: create a new
    /// shelf for that book, then Group by Shelf must show it under that shelf
    /// (the manual shelf workflow that replaced the AI tools entry).
    func testLongPressAssignsShelfAndGroupsByIt() throws {
        let app = pendingScansApp()
        app.launch()
        enterLibraryIfNeeded(app)
        addSeededBooks(app) // two seeded books → populated grid

        // Long-press the first book's cell (its title text) → action menu.
        let book = app.staticTexts["The Swift Programming Language"]
        XCTAssertTrue(book.waitForExistence(timeout: 10), "book cell missing")
        book.press(forDuration: 1.2)

        // Long-press opens the action dialog (assign shelf / edit tags / delete).
        let assign = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Assign to shelf'")
        ).firstMatch
        XCTAssertTrue(assign.waitForExistence(timeout: 5), "assign-to-shelf menu missing")
        assign.tap()

        XCTAssertTrue(app.navigationBars["Assign to shelf"].waitForExistence(timeout: 10),
                      "assign sheet did not open")
        // Create a brand-new shelf inline.
        let newField = app.textFields["New shelf…"]
        XCTAssertTrue(newField.waitForExistence(timeout: 5), "new-shelf field missing")
        newField.tap()
        newField.typeText("Home")
        app.buttons["Add"].tap()
        app.buttons["Done"].tap()

        // Group by Shelf to confirm the assignment took effect.
        let group = app.buttons["Group"]
        XCTAssertTrue(group.waitForExistence(timeout: 10), "Group menu missing")
        group.tap()
        let shelfGroup = app.buttons["Shelf"]
        XCTAssertTrue(shelfGroup.waitForExistence(timeout: 5), "Shelf grouping missing")
        shelfGroup.tap()

        XCTAssertTrue(app.staticTexts["Home"].waitForExistence(timeout: 10),
                      "assigned shelf section missing after grouping by shelf")
        XCTAssertTrue(book.exists, "book must appear under its assigned shelf")
    }

    /// Ask AI suggestion chips must be context-aware: static starters on an
    /// empty conversation, then follow-ups derived from what was asked — not
    /// the same three starters forever. A chip tap fills the input; it does
    /// not auto-send. A no-engine simulator still exercises the real surface:
    /// chips update from the conversation even though the reply errors out
    /// gracefully.
    func testAskAISuggestionsAdaptToConversation() throws {
        let app = baseApp()
        app.launch()
        enterLibraryIfNeeded(app)
        app.tabBars.buttons["Ask AI"].tap()

        // The conversation is intentionally persisted across launches, so the
        // simulator can carry a leftover chat from earlier runs. Reset it via
        // the app's own clear affordance to start from the empty state.
        XCTAssertTrue(app.navigationBars["Ask AI"].waitForExistence(timeout: 10),
                      "Ask AI screen did not open")
        let clear = app.buttons["Clear conversation"]
        if clear.waitForExistence(timeout: 3), clear.isEnabled {
            clear.tap()
        }

        // Empty conversation → the static starter chips are shown.
        let starter = app.buttons["What should I read next?"]
        XCTAssertTrue(starter.waitForExistence(timeout: 10),
                      "starter chips not shown after clearing")

        // Ask a recommendation question. No engine is configured on the
        // simulator, so the reply will fail fast; the chips still update from
        // the conversation the moment the user message is queued.
        let field = app.textFields["Ask about your library…"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no input field")
        field.tap()
        field.typeText("Recommend my next read")
        app.buttons["Send"].tap()

        // The thread-continuation chip must replace the generic starters —
        // proof the suggestions now depend on conversation state.
        let continuation = app.buttons["Which of those should I start with?"]
        XCTAssertTrue(continuation.waitForExistence(timeout: 10),
                      "chips did not adapt to the conversation")

        // Wait out the failing reply so the chips are tappable, then verify a
        // chip tap only fills the input rather than sending.
        var attempts = 0
        while !continuation.isEnabled && attempts < 20 {
            sleep(1)
            attempts += 1
        }
        continuation.tap()
        // Once a field holds text, iOS stops exposing it via its placeholder,
        // so re-resolve the (single) input rather than re-matching the prompt.
        let input = app.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 3), "input field gone after chip tap")
        XCTAssertEqual(input.value as? String, "Which of those should I start with?",
                       "chip should fill the input, not send it")
    }

    /// A seeded assistant turn rich in markdown (heading, bold, bullets) — the
    /// kind of output the model returns. The bubble must render it styled
    /// (heading visible, no literal `**`/`##`/`- ` tokens), not leak raw
    /// markdown as text.
    func testAskAIRendersMarkdownInsteadOfRawTokens() throws {
        let app = baseApp()
        app.launchEnvironment["UI_TEST_TRANSCRIPT"] = markdownTranscriptSeed
        app.launch()
        enterLibraryIfNeeded(app)
        app.tabBars.buttons["Ask AI"].tap()
        XCTAssertTrue(app.navigationBars["Ask AI"].waitForExistence(timeout: 5),
                      "Ask AI screen did not present")

        // The heading is parsed into a styled element — not a literal "## ".
        let heading = app.staticTexts["Reading Plan"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10),
                      "heading not rendered from markdown:\n\(app.debugDescription)")

        // No raw markdown tokens survive anywhere in the bubble set.
        let raw = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '**' OR label CONTAINS '##' OR label CONTAINS '- Dune'")
        )
        XCTAssertEqual(raw.count, 0,
                       "raw markdown leaked into bubbles — render failed")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "AskAI-markdown-rendered"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Tapping a scanned book in the strip opens its details in a review sheet
    /// (editable form) with the delete option there — not a tap-to-delete-hit
    /// on the strip. Deleting removes it from the scan list without adding.
    func testScannedBookTapsToReviewAndDelete() throws {
        let app = baseApp()
        app.launchEnvironment["UI_TEST_SCANNED_BOOKS"] = pendingScansSeed
        app.launch()
        enterLibraryIfNeeded(app)
        openAddSheet(app)
        openScanner(app)

        // The strip lists the seeded books as tappable review thumbnails.
        let review1 = app.buttons["Review The Swift Programming Language"]
        XCTAssertTrue(review1.waitForExistence(timeout: 10), "scan thumbnail missing")
        review1.tap()

        // Tapping opens details (editable form) in a sheet, not immediate delete.
        XCTAssertTrue(app.navigationBars["Review scanned book"].waitForExistence(timeout: 10),
                      "tap did not open review sheet")
        XCTAssertTrue(app.textFields["Title *"].waitForExistence(timeout: 10),
                      "review sheet should show the editable title field")

        // The delete action lives on the review form, as requested.
        let nav = app.navigationBars["Review scanned book"]
        let trash = nav.buttons.matching(NSPredicate(format: "label CONTAINS 'rash'")).firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "no delete button on review sheet")
        trash.tap()
        let alert = app.alerts["Delete this book?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "delete confirmation did not appear")
        alert.buttons["Delete"].tap()

        // Sheet dismissed and the strip shrank to the remaining book.
        XCTAssertTrue(app.staticTexts["1 scanned"].waitForExistence(timeout: 10),
                      "deleted book still listed in scan strip")
        XCTAssertFalse(app.buttons["Review The Swift Programming Language"].exists,
                       "deleted book still tappable in strip")
    }

    /// Regression for the reported "OK leaves the scan pending" bug: with a
    /// stale scan entry for a book that IS in the library, rescanning shows
    /// the duplicate alert; OK must DISCARD the queued scan (the alert
    /// promises "skip this scan"), so the pending-scan banner disappears.
    /// The rescan is injected through the real handleCode path via
    /// UI_TEST_SCAN_CODE (the simulator camera produces no frames). Phase 2
    /// must NOT set UI_TEST_RESET_DATA — that would wipe the library the
    /// first phase imported and the ISBN would no longer be a duplicate.
    func testDuplicateScanOKDiscardsPendingScan() throws {
        // Phase 1: reset to a known state and import both seed books, so the
        // library contains ISBN 9780137463602.
        let app = baseApp()
        app.launchEnvironment["UI_TEST_PENDING_SCANS"] = pendingScansSeed
        app.launch()
        enterLibraryIfNeeded(app)
        addSeededBooks(app)
        app.terminate()

        // Phase 2: relaunch WITHOUT reset — the library persists. Seed a
        // stale (failed) scan entry for a book already imported, then inject
        // a rescan of the same ISBN through handleCode.
        let app2 = XCUIApplication()
        app2.launchEnvironment["UI_TEST_PENDING_ISBNS"] = "9780137463602"
        app2.launchEnvironment["UI_TEST_SCAN_CODE"] = "9780137463602"
        app2.launch()
        enterLibraryIfNeeded(app2)
        openAddSheet(app2)

        // The stale entry is pending before the rescan.
        let banner = app2.buttons.matching(NSPredicate(format: "label CONTAINS 'not yet added'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "stale scan entry missing before rescan")
        openScanner(app2)

        // The duplicate alert appears…
        let alert = app2.alerts["Already in library"]
        XCTAssertTrue(alert.waitForExistence(timeout: 20),
                      "duplicate alert did not appear for already-in-library ISBN")

        // …and OK discards the queued scan instead of leaving it pending.
        alert.buttons["OK"].tap()
        XCTAssertTrue(app2.staticTexts["No books scanned yet"].waitForExistence(timeout: 10),
                      "scan strip should be empty after OK discards the duplicate scan")
        app2.buttons["Close scanner"].tap()
        XCTAssertTrue(app2.navigationBars["Add a book"].waitForExistence(timeout: 10),
                      "did not return to the Add screen")
        XCTAssertFalse(banner.exists, "pending-scan banner must vanish once OK skips the scan")
    }

    /// An assistant-only chat seeded with markdown, matching `[AITurn]` and
    /// the JSONEncoder defaults `LocalTranscriptMemory` writes (seconds since
    /// a reference date, "role"/"text"/"date" keys).
    private var markdownTranscriptSeed: String {
        #"""
        [{"role":"assistant","text":"## Reading Plan\n\nHere are **three** suggestions:\n\n- Dune by Frank Herbert\n- The Handmaid's Tale\n\nLet's narrow it down.","date":700000000}]
        """#
    }
}
