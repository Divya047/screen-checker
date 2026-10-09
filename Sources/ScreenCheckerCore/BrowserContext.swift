import AppKit
import Foundation

/// Reads (and closes) the active tab of the frontmost browser via AppleScript.
/// Each browser triggers its own one-time Automation permission prompt.
public enum BrowserContext {
    /// bundle ID -> AppleScript application name (Chromium family supports
    /// the same "active tab of front window" dialect).
    static let chromiumFamily: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "org.chromium.Chromium": "Chromium",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave Browser",
    ]

    static let knownBrowserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser", // Arc
        "org.mozilla.firefox",
        "com.operasoftware.Opera",
        "com.duckduckgo.macos.browser",
    ]

    static let knownBrowserNames = [
        "safari", "chrome", "chromium", "edge", "brave", "arc",
        "firefox", "opera", "duckduckgo",
    ]

    public static func isBrowser(bundleID: String?, appName: String) -> Bool {
        if let bundleID, knownBrowserBundleIDs.contains(bundleID.lowercased()) {
            return true
        }
        let name = appName.lowercased()
        return knownBrowserNames.contains { name.contains($0) }
    }

    /// Active tab URL, or nil for unsupported browsers / denied Automation permission.
    public static func activeTabURL(bundleID: String?, appName: String) async -> String? {
        guard let bundleID, let source = readScript(bundleID: bundleID) else { return nil }
        return await runAppleScript(source)
    }

    /// Closes the active tab of the frontmost browser window.
    public static func closeActiveTab(bundleID: String?) async -> Bool {
        guard let bundleID else { return false }
        if bundleID == "com.apple.Safari" {
            return await runAppleScriptBool(
                #"tell application "Safari" to close front document"#
            )
        }
        if let appleScriptName = chromiumFamily[bundleID] {
            return await runAppleScriptBool(
                #"tell application "\#(appleScriptName)" to close active tab of front window"#
            )
        }
        return false
    }

    static func readScript(bundleID: String) -> String? {
        if bundleID == "com.apple.Safari" {
            return #"tell application "Safari" to get URL of front document"#
        }
        if let appleScriptName = chromiumFamily[bundleID] {
            return #"tell application "\#(appleScriptName)" to get URL of active tab of front window"#
        }
        // Arc and Firefox have no usable AppleScript tab API: rely on the
        // window title + screenshot instead.
        return nil
    }

    // MARK: - Warm-up (permission trigger)

    public struct WarmUpResult: Sendable {
        public let granted: Bool
        public let message: String
    }

    /// Runs a harmless tab-URL read against a running browser while this app
    /// is frontmost, so macOS shows the one-time Automation consent prompt.
    /// Background ticks cannot trigger that prompt — that is why "first
    /// browser read" silently fails until this runs once per browser.
    @MainActor
    public static func warmUp() async -> WarmUpResult {
        let workspace = NSWorkspace.shared
        var target: (bundleID: String, name: String)?
        if let front = workspace.frontmostApplication,
           let bid = front.bundleIdentifier,
           readScript(bundleID: bid) != nil {
            target = (bid, front.localizedName ?? bid)
        } else {
            for app in workspace.runningApplications {
                guard let bid = app.bundleIdentifier,
                      readScript(bundleID: bid) != nil
                else { continue }
                target = (bid, app.localizedName ?? bid)
                break
            }
        }
        guard let target, let source = readScript(bundleID: target.bundleID) else {
            return WarmUpResult(
                granted: false,
                message: "No supported browser running — open Safari or Chrome, then retry."
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let (value, errorText) = runAppleScriptSync(source)
        if let errorText {
            let lowered = errorText.lowercased()
            if lowered.contains("-1743") || lowered.contains("not authorized")
                || lowered.contains("not permitted") || lowered.contains("not allowed") {
                return WarmUpResult(
                    granted: false,
                    message: "Denied for \(target.name) — allow in Settings → Privacy → Automation."
                )
            }
            return WarmUpResult(granted: false, message: "\(target.name): \(errorText)")
        }
        guard let value else {
            return WarmUpResult(granted: false, message: "\(target.name): script failed to compile")
        }
        let preview = value.isEmpty ? "(blank tab)" : String(value.prefix(60))
        return WarmUpResult(granted: true, message: "✅ \(target.name) responded: \(preview)")
    }

    // MARK: - AppleScript plumbing

    /// NSAppleScript is main-thread only, and the Automation consent prompt
    /// is only shown while the requesting app is frontmost — so everything
    /// goes through the main actor.
    static func runAppleScript(_ source: String) async -> String? {
        await MainActor.run { runAppleScriptSync(source).value }
    }

    static func runAppleScriptBool(_ source: String) async -> Bool {
        await MainActor.run { runAppleScriptSync(source).error == nil }
    }

    @MainActor
    static func runAppleScriptSync(_ source: String) -> (value: String?, error: String?) {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error).stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let error {
            let code = error["NSAppleScriptErrorNumber"]
            let message = error["NSAppleScriptErrorMessage"] as? String ?? "AppleScript error"
            return (nil, "\(message) (\(code ?? "?"))")
        }
        return (result, nil)
    }
}
