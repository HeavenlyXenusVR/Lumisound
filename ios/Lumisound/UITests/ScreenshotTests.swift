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
        waitFor(app.staticTexts["Recently Added"], timeout: 120, what: "demo library scan")
        sleep(8)
        app.terminate()

        // Pass 2: the seeded data is on disk, so Home builds with it from the start.
        app.launch()
        waitFor(app.staticTexts["Jump Back In"], timeout: 60, what: "seeded Home")
        sleep(4)
        snap("01-home")

        for name in ["02-home-2", "03-home-3", "04-home-4"] {
            app.swipeUp()
            sleep(1)
            snap(name)
        }

        if tap(app.buttons["tab.1"], what: "Playing tab") {
            sleep(2)
            snap("05-now-playing")
        }
        if tap(app.buttons["tab.2"], what: "Queue tab") {
            sleep(1)
            snap("06-queue")
        }

        if tap(app.buttons["tab.0"], what: "Library tab") {
            for (tab, name) in [("Songs", "07-songs"), ("Albums", "08-albums"), ("Artists", "09-artists"), ("Playlists", "10-playlists")] {
                if tap(app.buttons["libraryTab.\(tab)"], what: "\(tab) library tab") {
                    sleep(2)
                    snap(name)
                }
            }
            if tap(app.buttons["libraryTab.Home"], what: "Home library tab") {
                sleep(1)
                if tap(app.buttons["Customize Home"], what: "Customize Home button") {
                    sleep(1)
                    snap("11-customize-home")
                    app.buttons["Done"].firstMatch.tap()
                }
            }
        }

        if tap(app.buttons["tab.6"], what: "Settings tab") {
            sleep(1)
            snap("12-settings")
        }
    }

    // MARK: Helpers

    @discardableResult
    private func waitFor(_ element: XCUIElement, timeout: TimeInterval, what: String) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("Timed out waiting for \(what)")
            snap("zz-timeout-\(what.replacingOccurrences(of: " ", with: "-"))")
            return false
        }
        return true
    }

    @discardableResult
    private func tap(_ element: XCUIElement, what: String) -> Bool {
        guard waitFor(element, timeout: 10, what: what) else { return false }
        element.tap()
        return true
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
