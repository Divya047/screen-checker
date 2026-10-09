import Foundation

// MARK: - Verdict

public enum Verdict: Equatable, Sendable {
    case productive(reason: String)
    case distraction(reason: String, category: String)
    case ambiguous(reason: String)
}

// MARK: - Classification

public struct Classification: Equatable, Sendable {
    public let verdict: Verdict
    /// 0 = local rules, 1 = LLM (opencode)
    public let tier: Int
    public let confidence: Double?
    public let model: String?
    /// Non-nil when an LLM call failed or produced unparseable output (we fail open).
    public let error: String?

    public init(
        verdict: Verdict,
        tier: Int,
        confidence: Double? = nil,
        model: String? = nil,
        error: String? = nil
    ) {
        self.verdict = verdict
        self.tier = tier
        self.confidence = confidence
        self.model = model
        self.error = error
    }
}

// MARK: - Enforcement

public enum EnforcementAction: String, Sendable {
    case sampled = "sampled"
    case reDetectedCached = "re-detected-cached"
    case warnedOnly = "warned-only"
    case closedTab = "closed-tab"
    case hidApp = "hid-app"
    case skippedGuard = "skipped-guard"
}

// MARK: - Screen snapshot

public struct ScreenSnapshot: Sendable {
    public let timestamp: Date
    public let appBundleID: String?
    public let appName: String
    public let pid: pid_t
    public let windowID: Int
    public let windowTitle: String
    public let url: String?
    public var screenshotPath: String?

    public init(
        timestamp: Date,
        appBundleID: String?,
        appName: String,
        pid: pid_t,
        windowID: Int,
        windowTitle: String,
        url: String?,
        screenshotPath: String?
    ) {
        self.timestamp = timestamp
        self.appBundleID = appBundleID
        self.appName = appName
        self.pid = pid
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.url = url
        self.screenshotPath = screenshotPath
    }
}

// MARK: - Event

public struct ScreenEvent: Codable, Sendable {
    public var ts: Date
    public var app: String
    public var bundleID: String?
    public var title: String
    public var url: String?
    /// productive | distraction | ambiguous
    public var verdict: String
    public var category: String?
    public var confidence: Double?
    public var reason: String?
    public var tier: Int
    public var model: String?
    public var action: String
    public var screenshot: String?
    public var error: String?

    public init(
        ts: Date,
        app: String,
        bundleID: String?,
        title: String,
        url: String?,
        verdict: String,
        category: String? = nil,
        confidence: Double? = nil,
        reason: String? = nil,
        tier: Int = 0,
        model: String? = nil,
        action: String = "sampled",
        screenshot: String? = nil,
        error: String? = nil
    ) {
        self.ts = ts
        self.app = app
        self.bundleID = bundleID
        self.title = title
        self.url = url
        self.verdict = verdict
        self.category = category
        self.confidence = confidence
        self.reason = reason
        self.tier = tier
        self.model = model
        self.action = action
        self.screenshot = screenshot
        self.error = error
    }
}
