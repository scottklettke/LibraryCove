import XCTest

final class GreetingRenameTests: XCTestCase {
    @MainActor
    func testGreetingFollowsRename() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_DATA"] = "1"
        app.launch()

        // Fresh-install path (no members): run the welcome flow. The welcome
        // is a 5-page TabView — pages 0–2 show "Continue", page 3 is the
        // setup form where "Create My Library" appears. When the store
        // already has a member, skip to the rename step.
        if app.buttons["Continue"].waitForExistence(timeout: 4) {
            for _ in 0..<4 {
                let cont = app.buttons["Continue"]
                guard cont.waitForExistence(timeout: 3) else { break }
                cont.tap()
                if app.textFields["Your name"].waitForExistence(timeout: 2) { break }
            }
            let nameField = app.textFields["Your name"]
            XCTAssertTrue(nameField.waitForExistence(timeout: 4), "setup form never appeared")
            nameField.tap()
            nameField.typeText("Alex")
            app.buttons["Create My Library"].tap()
        }

        let currentGreeting = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Hi, '")).firstMatch
        XCTAssertTrue(currentGreeting.waitForExistence(timeout: 8), "no greeting on empty library")

        app.tabBars.buttons["Settings"].tap()
        let profileField = app.textFields.firstMatch
        XCTAssertTrue(profileField.waitForExistence(timeout: 8), "profile field missing")
        profileField.clearText(in: app)
        profileField.typeText("Bob Marley")
        if app.keyboards.count > 0 {
            app.keyboards.buttons["Return"].tap()
        }

        app.tabBars.buttons["Library"].tap()
        let updated = app.staticTexts["Hi, Bob Marley"]
        if !updated.waitForExistence(timeout: 8) {
            let texts = app.staticTexts.allElementsBoundByIndex.prefix(12).map(\.label)
            XCTFail("greeting did not update after rename; visible texts: \(texts)")
            return
        }
    }
}

extension XCUIElement {
    func clearText(in app: XCUIApplication) {
        guard let value = value as? String, !value.isEmpty else { return }
        tap()
        press(forDuration: 1)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 2) { selectAll.tap() }
        let del = app.keys["delete"]
        if del.waitForExistence(timeout: 2) {
            for _ in 0..<value.count { del.tap() }
        }
    }
}
