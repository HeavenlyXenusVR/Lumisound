import XCTest

/// Drives the app through its main screens and saves a PNG of each.
///
/// Run by .github/workflows/screenshots-ios.yml, which first copies a demo
/// library into the app's Documents folder. Screenshots are written to
/// `SCREENSHOTS_DIR` (passed as `TEST_RUNNER_SCREENSHOTS_DIR` to xcodebuild)
/// and also attached to the test result.
///
/// Each step checks for its element instead of assuming it, and records a
/// failure but carries on, so one missing screen doesn't cost the rest.
final class ScreenshotTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        app.launchArguments += ["-LumisoundScreenshotMode"]
    }

    func testCaptureScreens() {
        // Pass 1: the app scans the demo library and ScreenshotMode seeds
        // play history, favorites and playlists.
        app.launch()
        continueWithoutAccount()
        waitFor(app.staticTexts["Recently Added"], timeout: 120, what: "demo library scan")
        // The Resume card's "Paused" label appears once seeding has loaded a
        // track, which is its last step. Closing the app before that loses
        // the seed data (and once seemed to break the next launch).
        waitFor(app.staticTexts["Paused"], timeout: 60, what: "seeding to finish")
        sleep(4) // the playback snapshot is written on a background task
        app.terminate()
        sleep(3)

        // Pass 2: the seeded data is on disk, so Home builds with it from the start.
        app.launch()
        continueWithoutAccount()
        waitFor(app.staticTexts["Jump Back In"], timeout: 60, what: "seeded Home")
        sleep(4)
        snap("01-home")

        for name in ["02-home-2", "03-home-3", "04-home-4"] {
            app.swipeUp()
            // Tiles fill in their artwork in a `.task` once they appear.
            sleep(3)
            snap(name)
        }

        if tap(tabButton(1, title: "Playing"), what: "Playing tab") {
            sleep(2)
            snap("05-now-playing")
        }
        if tap(tabButton(2, title: "Queue"), what: "Queue tab") {
            sleep(1)
            snap("06-queue")
        }

        if tap(tabButton(0, title: "Library"), what: "Library tab") {
            for (tab, name) in [("Songs", "07-songs"), ("Albums", "08-albums"), ("Artists", "09-artists"), ("Playlists", "10-playlists")] {
                if tap(element("libraryTab.\(tab)", label: tab), what: "\(tab) library tab") {
                    sleep(2)
                    snap(name)
                }
            }
            if tap(element("libraryTab.Home", label: "Home"), what: "Home library tab") {
                sleep(1)
                if tap(app.buttons["Customize Home"], what: "Customize Home button") {
                    sleep(1)
                    snap("11-customize-home")
                    app.buttons["Done"].firstMatch.tap()
                }
            }
        }

        if tap(tabButton(6, title: "Settings"), what: "Settings tab") {
            sleep(1)
            snap("12-settings")
        }
    }

    // MARK: Helpers

    /// The launch screen asks a signed-out user to create an account or log
    /// in, on every launch. It overlays the app (whose content is already
    /// loaded and queryable underneath), so without this every screenshot
    /// is of the prompt.
    private func continueWithoutAccount() {
        let skip = app.buttons["Continue without account"]
        guard skip.waitForExistence(timeout: 45) else { return }
        skip.tap()
        sleep(2)
    }

    private func tabButton(_ tag: Int, title: String) -> XCUIElement {
        element("tab.\(tag)", label: title)
    }

    /// By identifier on any element type first: the main tab bar sits in a
    /// Liquid Glass container, which doesn't always expose its children as
    /// plain buttons. Falls back to a button with the visible label.
    private func element(_ identifier: String, label: String) -> XCUIElement {
        let byID = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if byID.waitForExistence(timeout: 3) { return byID }
        return app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    private var printedHierarchy = false

    @discardableResult
    private func waitFor(_ element: XCUIElement, timeout: TimeInterval, what: String) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("Timed out waiting for \(what)")
            if !printedHierarchy {
                // Lands in the job log, which is easier to get at than the xcresult.
                printedHierarchy = true
                print("ACCESSIBILITY HIERARCHY (first failure):\n\(app.debugDescription)")
            }
            snap("zz-timeout-\(what.replacingOccurrences(of: " ", with: "-"))")
            return false
        }
        return true
    }

    @discardableResult
    private func tap(_ element: XCUIElement, what: String) -> Bool {
        guard waitFor(element, timeout: 10, what: what) else { return false }
        scrollIntoView(element)
        guard element.isHittable else {
            // `tap()` on an unhittable element is a hard error that ends the
            // whole test; record it and move on to the next screen instead.
            XCTFail("\(what) exists but can't be tapped")
            snap("zz-unhittable-\(what.replacingOccurrences(of: " ", with: "-"))")
            return false
        }
        element.tap()
        return true
    }

    /// The library tab row is a horizontal scroller, so later tabs (Albums,
    /// Artists, Playlists) start off-screen. Swipes the row towards the
    /// target, starting from the visible tab furthest from the edge it
    /// swipes towards (run 8 swiped from the leftmost tab, right at the
    /// screen edge, and the row never moved), then falls back to a fast
    /// drag across the row. Logs positions so a miss can be diagnosed.
    private func scrollIntoView(_ element: XCUIElement) {
        guard !element.isHittable else { return }
        let identifier = element.identifier
        guard let dot = identifier.lastIndex(of: ".") else { return }
        let prefix = String(identifier[...dot])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        let width = app.frame.width
        for attempt in 0..<8 where !element.isHittable {
            let target = element.frame
            let towardsLeft = target.midX > width / 2
            let visible = row.allElementsBoundByIndex
                .filter { $0.isHittable }
                .sorted { $0.frame.midX < $1.frame.midX }
            print("scrollIntoView \(identifier) attempt \(attempt): target \(target), visible \(visible.map(\.identifier))")
            if attempt < 4, let anchor = towardsLeft ? visible.last : visible.first {
                if towardsLeft { anchor.swipeLeft() } else { anchor.swipeRight() }
            } else if !target.isEmpty {
                let y = (visible.first?.frame.midY ?? target.midY)
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let from = origin.withOffset(CGVector(dx: towardsLeft ? width * 0.85 : width * 0.15, dy: y))
                let to = origin.withOffset(CGVector(dx: towardsLeft ? width * 0.15 : width * 0.85, dy: y))
                from.press(forDuration: 0.01, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
            }
            sleep(1)
        }
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // Simulator test runners can write straight to the host filesystem.
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"], !dir.isEmpty {
            let folder = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }
}
