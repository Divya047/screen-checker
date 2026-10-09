import AppKit
import Foundation
import ScreenCheckerCore
import UserNotifications

/// Posts distraction notifications with a "This was productive" action that
/// feeds the learning allowlist — the human-in-the-loop correction for
/// misjudged learning content.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let markProductiveAction = "MARK_PRODUCTIVE"
    static let reopenAction = "REOPEN_TAB"
    static let categoryID = "DISTRACTION"

    private var configStore: ConfigStore?
    private var eventStore: EventStore?
    var reopenHandler: (() -> Bool)?

    func wire(configStore: ConfigStore, eventStore: EventStore) {
        self.configStore = configStore
        self.eventStore = eventStore

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let productive = UNNotificationAction(
            identifier: Self.markProductiveAction,
            title: "This was productive",
            options: []
        )
        let reopen = UNNotificationAction(
            identifier: Self.reopenAction,
            title: "Reopen tab",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [productive, reopen],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        // NOTE: no auto-request here. For an accessory (menu-bar) app the
        // one-time system prompt is easily missed/suppressed if fired at
        // launch in the background. Authorization is requested from the
        // onboarding "Enable…" button instead, where the user expects it.
    }

    // MARK: - Authorization (used by onboarding UI)

    /// Human-readable status for the onboarding row.
    static func notificationsStatusText() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized:
            return "✅ enabled"
        case .denied:
            return "⚠️ denied — allow in System Settings → Notifications → ScreenChecker"
        case .ephemeral:
            return "✅ enabled (ephemeral)"
        case .provisional:
            return "✅ enabled (provisional)"
        case .notDetermined:
            return "⚠️ not enabled"
        @unknown default:
            return "⚠️ unknown status"
        }
    }

    /// Requests authorization; returns "enabled" or a human-readable reason.
    /// Must be called from user action (button), not at launch.
    static func requestNotifications() async -> String {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            if granted {
                return "enabled"
            }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .denied {
                return "denied — allow in System Settings → Notifications → ScreenChecker"
            }
            return "not granted (status: \(settings.authorizationStatus.rawValue))"
        } catch {
            return "request failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Events -> notifications

    func handle(event: ScreenEvent) {
        guard event.verdict == "distraction" else { return }
        // Guard-skips (cooldown / low confidence) stay log-only.
        guard event.action != EnforcementAction.skippedGuard.rawValue else { return }

        let content = UNMutableNotificationContent()
        let subject = event.title.isEmpty ? (event.url ?? event.app) : event.title
        content.title = "Distraction: \(String(subject.prefix(60)))"

        var body = event.reason ?? "Distraction detected"
        switch event.action {
        case EnforcementAction.warnedOnly.rawValue:
            body += " — warn-only mode (not closing)"
        case EnforcementAction.closedTab.rawValue:
            body += " — tab closed"
        case EnforcementAction.hidApp.rawValue:
            body += " — app hidden"
        default:
            body += " — detected"
        }
        if let category = event.category, !category.isEmpty, category != "none" {
            body += " [\(category)]"
        }
        content.body = body
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [
            "eventURL": event.url ?? "",
            "eventBundleID": event.bundleID ?? "",
        ]

        let request = UNNotificationRequest(
            identifier: "screencheck-\(Int(event.ts.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == Self.markProductiveAction {
            DispatchQueue.main.async { self.applyLearningFeedback() }
        } else if response.actionIdentifier == Self.reopenAction {
            DispatchQueue.main.async {
                if self.reopenHandler?() == true { return }
                // Fallback: reopen the URL carried by the notification.
                let urlString = response.notification.request.content.userInfo["eventURL"] as? String ?? ""
                if let url = URL(string: urlString), !urlString.isEmpty {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Learning feedback

    func applyLearningFeedback() {
        guard let store = eventStore, let configStore else { return }
        guard let event = store.recentDistraction(within: 30 * 60) else {
            post(title: "ScreenChecker", body: "No recent distraction event found.")
            return
        }

        var added = ""
        configStore.mutate { config in
            if let url = event.url {
                let pattern = Self.learningPattern(from: url)
                if !pattern.isEmpty, !config.learningURLPatterns.contains(pattern) {
                    config.learningURLPatterns.append(pattern)
                    added = pattern
                }
            } else if let bundleID = event.bundleID {
                if !config.productiveApps.contains(bundleID) {
                    config.productiveApps.append(bundleID)
                    added = bundleID
                }
            }
        }

        post(
            title: added.isEmpty ? "Nothing to add" : "Added to learning allowlist",
            body: added.isEmpty
                ? "This distraction was already allowlisted."
                : "\(added) — future checks treat it as productive."
        )
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: "feedback-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Pins the pattern tightly enough to be useful but loosely enough to
    /// cover the session: YouTube watch URLs pin to the specific video,
    /// other sites pin to host+path.
    static func learningPattern(from url: String) -> String {
        guard let parsed = URL(string: url), let host = parsed.host else {
            return url.lowercased()
        }
        let lowered = host.lowercased()
        if lowered.contains("youtube.com"), parsed.path.lowercased().contains("/watch") {
            if let videoID = URLComponents(string: url)?.queryItems?
                .first(where: { $0.name == "v" })?.value {
                return "\(lowered)/watch?v=\(videoID)"
            }
            return "\(lowered)/watch"
        }
        var pattern = lowered + parsed.path
        if pattern.count > 120 {
            pattern = String(pattern.prefix(120))
        }
        return pattern
    }
}
