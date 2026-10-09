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
        guard let bundleID else { return nil }
        if bundleID == "com.apple.Safari" {
            return await runAppleScript(#"tell application "Safari" to get URL of front document"#)
        }
        if let appleScriptName = chromiumFamily[bundleID] {
            return await runAppleScript(
                #"tell application "\#(appleScriptName)" to get URL of active tab of front window"#
            )
        }
        // Arc and Firefox have no usable AppleScript tab API: rely on the
        // window title + screenshot instead.
        return nil
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

    // MARK: - AppleScript plumbing

    static func runAppleScript(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let script = NSAppleScript(source: source)
                var error: NSDictionary?
                let result = script?.executeAndReturnError(&error).stringValue
                continuation.resume(
                    returning: result?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }

    static func runAppleScriptBool(_ source: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let script = NSAppleScript(source: source)
                var error: NSDictionary?
                _ = script?.executeAndReturnError(&error)
                continuation.resume(returning: error == nil)
            }
        }
    }
}
