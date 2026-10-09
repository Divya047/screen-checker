import AppKit
import Foundation
import os

/// Takes action on a distraction verdict. Browsers: close the active tab.
/// Anything else: hide the app (never force-quit — your work stays open).
///
/// Guards:
/// - only in `enforce` mode (warn-only just notifies)
/// - never during a learning break
/// - never for protected title keywords (defense-in-depth; rules already
///   return productive, but a stale cached verdict must not enforce)
/// - LLM confidence must reach the configured threshold
/// - per-target cooldown between actions (same app+URL), plus a short global
///   safety cooldown so a classifier glitch cannot machine-gun windows
public final class Enforcer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActionByTarget: [String: Date] = [:]
    private var lastGlobalActionAt: Date?
    private let log = Logger(subsystem: "dev.screenchecker.app", category: "enforcer")

    public init() {}

    public func enforce(
        snapshot: ScreenSnapshot,
        classification: Classification,
        config: AppConfig,
        learningBreakUntil: Date?
    ) async -> EnforcementAction {
        guard case .distraction = classification.verdict else { return .sampled }
        guard config.mode == .enforce else { return .warnedOnly }
        if let until = learningBreakUntil, Date() < until { return .skippedGuard }
        if Self.isProtected(title: snapshot.windowTitle, config: config) {
            log.info("enforce skipped: protected title")
            return .skippedGuard
        }
        if let confidence = classification.confidence, confidence < config.confidenceThreshold {
            return .skippedGuard
        }

        let target = Self.targetKey(for: snapshot)
        let now = Date()
        lock.lock()
        if let last = lastActionByTarget[target],
           now.timeIntervalSince(last) < max(5, config.enforcementCooldown) {
            lock.unlock()
            return .skippedGuard
        }
        // Global safety net: at most one enforcement per ~15-60s regardless
        // of target, so alternating targets cannot evade the cooldown.
        let globalCooldown = min(60, max(15, config.enforcementCooldown / 4))
        if let lastGlobal = lastGlobalActionAt,
           now.timeIntervalSince(lastGlobal) < globalCooldown {
            lock.unlock()
            return .skippedGuard
        }
        lock.unlock()

        var action: EnforcementAction = .hidApp
        if let bundleID = snapshot.appBundleID,
           await BrowserContext.closeActiveTab(bundleID: bundleID) {
            action = .closedTab
        } else {
            await MainActor.run {
                NSRunningApplication(processIdentifier: snapshot.pid)?.hide()
            }
        }

        lock.lock()
        lastActionByTarget[target] = Date()
        lastGlobalActionAt = Date()
        if lastActionByTarget.count > 200 {
            let cutoff = Date().addingTimeInterval(-3600)
            lastActionByTarget = lastActionByTarget.filter { $0.value > cutoff }
        }
        lock.unlock()
        log.info("enforced \(action.rawValue, privacy: .public) target=\(target, privacy: .public)")
        return action
    }

    /// Stable per-target key: bundleID|normalized-URL or bundleID|title.
    static func targetKey(for s: ScreenSnapshot) -> String {
        let app = (s.appBundleID ?? s.appName).lowercased()
        if let url = s.url, !url.isEmpty {
            return app + "|" + Monitor.normalizeURL(url)
        }
        return app + "|t:" + s.windowTitle.lowercased().prefix(80)
    }

    static func isProtected(title: String, config: AppConfig) -> Bool {
        let lowered = title.lowercased()
        return config.protectedTitleKeywords.contains { !$0.isEmpty && lowered.contains($0.lowercased()) }
    }
}
