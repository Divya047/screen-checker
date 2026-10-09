import AppKit
import Foundation

/// Grabs everything we know about the current frontmost context:
/// app + focused window title, the active browser tab URL, and a
/// screenshot of just that window (written to a temp file).
public final class Sampler: @unchecked Sendable {
    public init() {}

    /// Returns nil when there is nothing meaningful to inspect
    /// (no frontmost window, or our own UI is frontmost).
    public func sample(excluding excludedBundleID: String?) async -> ScreenSnapshot? {
        let info = await MainActor.run { self.frontmostWindow() }
        guard let info else { return nil }
        if let excluded = excludedBundleID, let bundleID = info.bundleID, bundleID == excluded {
            return nil
        }

        let url = await BrowserContext.activeTabURL(bundleID: info.bundleID, appName: info.name)

        var screenshotPath: String? = nil
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("screencheck-\(stamp).png")
        do {
            try await ScreenshotCapture.capture(windowID: info.windowID, to: destination)
            screenshotPath = destination.path
        } catch {
            // Keep going without a screenshot; tier 1 still gets app/title/URL.
            screenshotPath = nil
        }

        return ScreenSnapshot(
            timestamp: Date(),
            appBundleID: info.bundleID,
            appName: info.name,
            pid: info.pid,
            windowID: info.windowID,
            windowTitle: info.title,
            url: url,
            screenshotPath: screenshotPath
        )
    }

    typealias FrontmostInfo = (
        bundleID: String?, name: String, pid: pid_t, windowID: Int, title: String
    )

    func frontmostWindow() -> FrontmostInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        let name = app.localizedName ?? bundleID ?? "unknown"
        guard let (windowID, title) = focusedWindow(forPID: pid) else { return nil }
        return (bundleID, name, pid, windowID, title)
    }

    /// Frontmost window of the given process: layer 0 (normal) on-screen window.
    /// Window titles require the Screen Recording permission.
    func focusedWindow(forPID pid: pid_t) -> (Int, String)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) else {
            return nil
        }
        let windows = list as NSArray
        for element in windows {
            guard let entry = element as? [String: Any] else { continue }
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid
            else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            if let number = entry[kCGWindowNumber as String] as? Int {
                let title = entry[kCGWindowName as String] as? String ?? ""
                return (number, title)
            }
        }
        return nil
    }
}
