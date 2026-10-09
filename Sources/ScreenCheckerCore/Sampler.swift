import AppKit
import Foundation
import os

/// Grabs everything we know about the current frontmost context:
/// app + focused window title, the active browser tab URL, and (only when
/// needed for tier-1) a screenshot of just that window.
public final class Sampler: @unchecked Sendable {
    private let log = Logger(subsystem: "dev.screenchecker.app", category: "sampler")
    public init() {}

    /// Full sample (metadata + screenshot). Prefer `sampleMetadata` +
    /// `attachScreenshot` in the hot path so tier-0 verdicts skip the
    /// expensive capture entirely.
    public func sample(excluding excludedBundleID: String?) async -> ScreenSnapshot? {
        guard var snap = await sampleMetadata(excluding: excludedBundleID) else { return nil }
        snap.screenshotPath = await captureTempScreenshot(windowID: snap.windowID)
        return snap
    }

    /// Cheap metadata-only sample: frontmost app/window + tab URL, no capture.
    public func sampleMetadata(excluding excludedBundleID: String?) async -> ScreenSnapshot? {
        let info = await MainActor.run { self.frontmostWindow() }
        guard let info else { return nil }
        if let excluded = excludedBundleID, let bundleID = info.bundleID, bundleID == excluded {
            return nil
        }
        let url = await BrowserContext.activeTabURL(bundleID: info.bundleID, appName: info.name)
        return ScreenSnapshot(
            timestamp: Date(),
            appBundleID: info.bundleID,
            appName: info.name,
            pid: info.pid,
            windowID: info.windowID,
            windowTitle: info.title,
            url: url,
            screenshotPath: nil
        )
    }

    /// Captures the window to a temp PNG; nil on failure (tier 1 still gets
    /// app/title/URL). Caller owns deletion via Monitor.deleteTemp.
    public func captureTempScreenshot(windowID: Int) async -> String? {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("screencheck-\(stamp).png")
        do {
            try await ScreenshotCapture.capture(windowID: windowID, to: destination)
            return destination.path
        } catch {
            log.debug("screenshot capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Attaches a screenshot to an existing metadata snapshot.
    public func attachScreenshot(to snapshot: ScreenSnapshot) async -> ScreenSnapshot {
        var copy = snapshot
        copy.screenshotPath = await captureTempScreenshot(windowID: snapshot.windowID)
        return copy
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
