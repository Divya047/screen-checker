import Foundation

/// Tier 0: instant, offline, fail-open heuristics. Learning allowlists take
/// precedence over distraction patterns, so YouTube works for study.
public struct RuleClassifier: Sendable {
    public init() {}

    public func classify(_ snapshot: ScreenSnapshot, config: AppConfig) -> Classification {
        Classification(
            verdict: Self.verdict(for: snapshot, config: config),
            tier: 0,
            confidence: 1.0,
            model: "rules"
        )
    }

    public static func verdict(for s: ScreenSnapshot, config c: AppConfig) -> Verdict {
        let title = s.windowTitle.lowercased()
        let url = s.url?.lowercased()

        // 1. Protected windows are never enforced against.
        if c.protectedTitleKeywords.contains(where: { !$0.isEmpty && title.contains($0.lowercased()) }) {
            return .productive(reason: "protected title keyword")
        }

        // 2. Learning allowlists win over everything else.
        if let url {
            if c.learningURLPatterns.contains(where: { url.contains($0.lowercased()) })
                || c.learningChannelPatterns.contains(where: { url.contains($0.lowercased()) }) {
                return .productive(reason: "learning allowlist (URL)")
            }
        }
        if !title.isEmpty,
           c.learningTitleKeywords.contains(where: { title.contains($0.lowercased()) }) {
            return .productive(reason: "learning keyword in title")
        }

        // 3. Explicit distraction patterns and apps.
        if let url,
           c.distractionURLPatterns.contains(where: { url.contains($0.lowercased()) }) {
            return .distraction(reason: "URL matched distraction pattern", category: category(forURL: url))
        }
        if c.distractionApps.contains(where: { matchesApp(bundleID: s.appBundleID, appName: s.appName, pattern: $0) }) {
            return .distraction(reason: "media/game app", category: "streaming")
        }

        // 4. Known productive URLs and apps.
        if let url,
           c.productiveURLPatterns.contains(where: { url.contains($0.lowercased()) }) {
            return .productive(reason: "URL matched productive pattern")
        }
        if c.productiveApps.contains(where: { matchesApp(bundleID: s.appBundleID, appName: s.appName, pattern: $0) }) {
            return .productive(reason: "productive app")
        }

        // 5. Browser content the rules cannot judge -> tier 1 (vision LLM).
        if BrowserContext.isBrowser(bundleID: s.appBundleID, appName: s.appName) {
            return .ambiguous(reason: url == nil ? "browser tab without URL" : "unknown browser content")
        }

        // 6. Fail open for unknown apps.
        return .productive(reason: "unknown app (fail-open)")
    }

    /// Patterns containing a dot match bundle IDs; others match app names.
    public static func matchesApp(bundleID: String?, appName: String, pattern: String) -> Bool {
        let p = pattern.lowercased()
        if p.contains(".") {
            return bundleID?.lowercased() == p
        }
        return !p.isEmpty && appName.lowercased().contains(p)
    }

    public static func category(forURL url: String) -> String {
        if ["shorts", "tiktok", "/reel"].contains(where: { url.contains($0) }) {
            return "shorts"
        }
        if ["reddit", "x.com", "twitter", "instagram", "facebook"].contains(where: { url.contains($0) }) {
            return "social"
        }
        if ["netflix", "twitch", "hulu", "disney", "prime video"].contains(where: { url.contains($0) }) {
            return "streaming"
        }
        return "other"
    }
}
