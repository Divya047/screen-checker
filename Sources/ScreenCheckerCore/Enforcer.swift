import AppKit
import Foundation

/// Takes action on a distraction verdict. Browsers: close the active tab.
/// Anything else: hide the app (never force-quit — your work stays open).
///
/// Guards:
/// - only in `enforce` mode (warn-only just notifies)
/// - never during a learning break
/// - LLM confidence must reach the configured threshold
/// - global cooldown between actions so a classifier glitch cannot
///   machine-gun through your windows
public final class Enforcer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActionAt: Date?

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
        if let confidence = classification.confidence, confidence < config.confidenceThreshold {
            return .skippedGuard
        }

        lock.lock()
        if let last = lastActionAt,
           Date().timeIntervalSince(last) < config.enforcementCooldown {
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
        lastActionAt = Date()
        lock.unlock()
        return action
    }
}
