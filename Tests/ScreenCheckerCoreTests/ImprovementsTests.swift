import XCTest
@testable import ScreenCheckerCore

final class ImprovementsTests: XCTestCase {
    // MARK: URL normalization

    func testNormalizeStripsFragmentAndTrailingSlash() {
        XCTAssertEqual(
            Monitor.normalizeURL("https://Example.COM/docs/Guide/#section"),
            "example.com/docs/Guide"
        )
        XCTAssertEqual(
            Monitor.normalizeURL("https://www.example.com/a/"),
            "www.example.com/a"
        )
    }

    func testNormalizeDropsQueryExceptYouTubeID() {
        XCTAssertEqual(
            Monitor.normalizeURL("https://www.example.com/search?q=swift&utm_source=x"),
            "www.example.com/search"
        )
        XCTAssertTrue(
            Monitor.normalizeURL("https://www.youtube.com/watch?v=ABC123&list=xyz&t=30").hasSuffix("/watch?v=abc123")
        )
    }

    func testCacheKeyStableForSameURLDifferentTitle() {
        let a = ScreenSnapshot(timestamp: Date(), appBundleID: "com.apple.Safari", appName: "Safari", pid: 1, windowID: 1, windowTitle: "Title A — 1:23", url: "https://example.com/article?utm_medium=x", screenshotPath: nil)
        let b = ScreenSnapshot(timestamp: Date(), appBundleID: "com.apple.Safari", appName: "Safari", pid: 1, windowID: 1, windowTitle: "Title A — 4:56", url: "https://example.com/article", screenshotPath: nil)
        let store = ConfigStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let monitor = Monitor(configStore: store, eventStore: EventStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), supportDirectory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(monitor.cacheKey(for: a), monitor.cacheKey(for: b))
    }

    // MARK: Config validation

    func testValidDefaults() {
        XCTAssertTrue(AppConfig().validationErrors().isEmpty)
    }

    func testInvalidConfigReportsErrors() {
        var c = AppConfig()
        c.sampleInterval = 1
        c.slots = [TimeSlot(start: "25:00", end: "26:00")]
        c.confidenceThreshold = 5
        c.opencodeModel = ""
        let errors = c.validationErrors()
        XCTAssertGreaterThanOrEqual(errors.count, 4)
    }

    func testFreeTierDetection() {
        XCTAssertTrue(AppConfig.isFreeTierModel("opencode/muse-spark-1.3-contributor-free"))
        XCTAssertTrue(AppConfig.isFreeTierModel("opencode/mimo-v2.6-flash-free"))
        XCTAssertFalse(AppConfig.isFreeTierModel("opencode-go/mimo-v2.6-pro"))
        XCTAssertFalse(AppConfig.isFreeTierModel("opencode/muse-spark-1.3"))
    }

    // MARK: Enforcer helpers

    func testProtectedGuard() {
        var c = AppConfig()
        c.protectedTitleKeywords = ["bank"]
        XCTAssertTrue(Enforcer.isProtected(title: "My Bank — login", config: c))
        XCTAssertFalse(Enforcer.isProtected(title: "GitHub PR", config: c))
    }

    func testTargetKeyStable() {
        let s = ScreenSnapshot(timestamp: Date(), appBundleID: "com.google.Chrome", appName: "Chrome", pid: 1, windowID: 1, windowTitle: "x", url: "https://github.com/a/b?utm=x", screenshotPath: nil)
        XCTAssertEqual(Enforcer.targetKey(for: s), "com.google.chrome|github.com/a/b")
    }

    // MARK: Evidence disabled

    func testEvidenceSavingDisabled() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = EventStore(directory: dir)
        XCTAssertNil(store.saveEvidence(from: "/nonexistent.png"))
        XCTAssertFalse(AppConfig().keepScreenshots)
    }
}
