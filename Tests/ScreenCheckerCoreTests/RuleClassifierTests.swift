import XCTest
@testable import ScreenCheckerCore

final class RuleClassifierTests: XCTestCase {
    func snapshot(
        app: String = "Safari",
        bundleID: String? = "com.apple.Safari",
        title: String = "Some page",
        url: String? = nil
    ) -> ScreenSnapshot {
        ScreenSnapshot(
            timestamp: Date(),
            appBundleID: bundleID,
            appName: app,
            pid: 1234,
            windowID: 99,
            windowTitle: title,
            url: url,
            screenshotPath: nil
        )
    }

    func classify(_ snapshot: ScreenSnapshot, _ mutate: (inout AppConfig) -> Void = { _ in }) -> Verdict {
        var config = AppConfig()
        mutate(&config)
        return RuleClassifier.verdict(for: snapshot, config: config)
    }

    // MARK: Distractions

    func testYouTubeShortsIsDistraction() {
        let verdict = classify(snapshot(
            title: "30 second car video - YouTube",
            url: "https://www.youtube.com/shorts/abc123"
        ))
        XCTAssertEqual(verdict, .distraction(reason: "URL matched distraction pattern", category: "shorts"))
    }

    func testTikTokIsDistraction() {
        let verdict = classify(snapshot(
            title: "TikTok",
            url: "https://www.tiktok.com/@someone/video/123"
        ))
        XCTAssertEqual(verdict, .distraction(reason: "URL matched distraction pattern", category: "shorts"))
    }

    func testMediaPlayerAppIsDistraction() {
        let verdict = classify(snapshot(app: "VLC", bundleID: "org.videolan.vlc", title: "movie.mkv"))
        XCTAssertEqual(verdict, .distraction(reason: "media/game app", category: "streaming"))
    }

    // MARK: Learning wins over distraction

    func testLearningChannelIsProductive() {
        let verdict = classify(snapshot(
            title: "SwiftUI Full Course - YouTube",
            url: "https://www.youtube.com/@freecodecamp"
        ))
        XCTAssertEqual(verdict, .productive(reason: "learning allowlist (URL)"))
    }

    func testLearningKeywordInTitleIsProductive() {
        let verdict = classify(snapshot(
            title: "WWDC 2026 SwiftUI Deep Dive - YouTube",
            url: "https://www.youtube.com/watch?v=xyz789"
        ))
        XCTAssertEqual(verdict, .productive(reason: "learning keyword in title"))
    }

    func testLearningAllowlistBeatsDistractionPattern() {
        let verdict = classify(snapshot(
            title: "Some page",
            url: "https://www.youtube.com/shorts/abc123"
        )) { config in
            config.learningURLPatterns = ["youtube.com/shorts/abc123"]
        }
        XCTAssertEqual(verdict, .productive(reason: "learning allowlist (URL)"))
    }

    func testProtectedTitleIsNeverEnforced() {
        let verdict = classify(snapshot(
            title: "Q3 Invoice — payment overdue",
            url: "https://www.tiktok.com"
        ))
        XCTAssertEqual(verdict, .productive(reason: "protected title keyword"))
    }

    // MARK: Productive

    func testKnownProductiveApp() {
        let verdict = classify(snapshot(
            app: "Xcode", bundleID: "com.apple.dt.Xcode", title: "main.swift — MyProject"
        ))
        XCTAssertEqual(verdict, .productive(reason: "productive app"))
    }

    func testKnownProductiveURL() {
        let verdict = classify(snapshot(
            app: "Google Chrome", bundleID: "com.google.Chrome",
            title: "GitHub", url: "https://github.com/some/repo"
        ))
        XCTAssertEqual(verdict, .productive(reason: "URL matched productive pattern"))
    }

    func testUnknownAppFailsOpen() {
        let verdict = classify(snapshot(app: "AcmeTool", bundleID: "com.acme.tool", title: "work stuff"))
        XCTAssertEqual(verdict, .productive(reason: "unknown app (fail-open)"))
    }

    // MARK: Ambiguous -> tier 1

    func testUnknownBrowserURLIsAmbiguous() {
        let verdict = classify(snapshot(
            app: "Safari", bundleID: "com.apple.Safari",
            title: "Untitled", url: "https://www.example.com/article"
        ))
        XCTAssertEqual(verdict, .ambiguous(reason: "unknown browser content"))
    }

    func testBrowserWithoutURLIsAmbiguous() {
        let verdict = classify(snapshot(
            app: "Google Chrome", bundleID: "com.google.Chrome",
            title: "New Tab", url: nil
        ))
        XCTAssertEqual(verdict, .ambiguous(reason: "browser tab without URL"))
    }

    // MARK: App matching helpers

    func testBundleIDAndNameAppMatching() {
        XCTAssertTrue(RuleClassifier.matchesApp(bundleID: "com.apple.dt.Xcode", appName: "Xcode", pattern: "Xcode"))
        XCTAssertTrue(RuleClassifier.matchesApp(bundleID: "com.apple.dt.Xcode", appName: "Xcode", pattern: "com.apple.dt.xcode"))
        XCTAssertFalse(RuleClassifier.matchesApp(bundleID: "com.apple.Safari", appName: "Safari", pattern: "Xcode"))
        XCTAssertFalse(RuleClassifier.matchesApp(bundleID: "com.apple.Safari", appName: "Safari", pattern: ""))
    }

    func testBrowserDetection() {
        XCTAssertTrue(BrowserContext.isBrowser(bundleID: "com.apple.Safari", appName: "Safari"))
        XCTAssertTrue(BrowserContext.isBrowser(bundleID: "com.google.Chrome", appName: "Google Chrome"))
        XCTAssertTrue(BrowserContext.isBrowser(bundleID: nil, appName: "Brave Browser"))
        XCTAssertFalse(BrowserContext.isBrowser(bundleID: "com.apple.dt.Xcode", appName: "Xcode"))
    }
}
