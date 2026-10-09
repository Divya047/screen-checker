import AppKit
import Foundation

/// Simple "check + download" updater (no auto-install).
///
/// Flow: menu -> "Check for Updates..." -> GitHub Releases API
/// (`https://api.github.com/repos/<owner/repo>/releases/latest`) ->
/// compare `tag_name` (e.g. "v0.2.0") to `CFBundleShortVersionString` ->
/// if newer, offer "Download" which opens the release page in the browser.
/// User then drags the new `.app`/`.zip` to /Applications (replacing the old copy).
///
/// Setup (one time, when you publish the repo):
///   1. Push to GitHub, e.g. `github.com/you/screen-checker`.
///   2. Set the repo below OR in app/Info.plist as `SCUpdateRepo = "you/screen-checker"`.
///   3. Tag releases: `git tag v0.2.0 && git push --tags`, attach
///      `ScreenChecker.app.zip` to the GitHub Release.
/// No signing/notarization needed for this mode (unlike Sparkle auto-update).
final class Updater {
    static let shared = Updater()

    /// "owner/repo". Info.plist wins; fallback here for local builds.
    private var repo: String {
        if let v = Bundle.main.infoDictionary?["SCUpdateRepo"] as? String, !v.isEmpty,
           !v.contains("OWNER")
        {
            return v
        }
        return bundledDefaultRepo
    }

    /// Edit this when you publish, or set SCUpdateRepo in app/Info.plist.
    private let bundledDefaultRepo = "Divya047/screen-checker"

    private var lastCheckAt = Date.distantPast
    private var checking = false

    /// Called from the menu bar. `quietIfCurrent` is for future auto-checks.
    func checkFromMenu() {
        guard !checking else { return }
        checking = true
        Task {
            defer { Task { @MainActor in self.checking = false } }
            do {
                let release = try await fetchLatestRelease()
                let current = currentVersion()
                let latest = Self.normalizedVersion(release.tag)
                await MainActor.run {
                    self.checking = false
                    if Self.isNewer(latest: latest, than: current) {
                        self.showUpdateAlert(release: release, current: current, latest: latest)
                    } else {
                        self.showUpToDateAlert(current: current)
                    }
                }
            } catch let error as UpdateError {
                await MainActor.run {
                    self.checking = false
                    self.showErrorAlert(error)
                }
            } catch {
                await MainActor.run {
                    self.checking = false
                    self.showErrorAlert(.network(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Fetch

    private struct Release {
        let tag: String
        let name: String
        let notes: String
        let htmlURL: URL
    }

    private func fetchLatestRelease() async throws -> Release {
        let repo = repo
        guard !repo.isEmpty else { throw UpdateError.notConfigured }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError.network("Bad repo name: \(repo)")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("ScreenChecker/\(currentVersion())", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.network("No response") }
        if http.statusCode == 404 {
            throw UpdateError.noReleases(repo)
        }
        guard (200...299).contains(http.statusCode) else {
            throw UpdateError.network("GitHub API: HTTP \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let htmlString = json["html_url"] as? String,
              let htmlURL = URL(string: htmlString)
        else {
            throw UpdateError.network("Could not parse release info")
        }
        return Release(
            tag: tag,
            name: (json["name"] as? String) ?? tag,
            notes: (json["body"] as? String) ?? "",
            htmlURL: htmlURL
        )
    }

    // MARK: - Versions

    func currentVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    static func normalizedVersion(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("v") { t = String(t.dropFirst()) }
        return t
    }

    /// Numeric dot-separated compare ("0.2.0" > "0.1.0", "0.10.0" > "0.9.0").
    static func isNewer(latest: String, than current: String) -> Bool {
        let l = latest.split(separator: ".").map { Int($0) ?? 0 }
        let c = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(l.count, c.count) {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv != cv { return lv > cv }
        }
        return false
    }

    // MARK: - UI (main thread only)

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showUpdateAlert(release: Release, current: String, latest: String) {
        activate()
        let alert = NSAlert()
        alert.messageText = "Update available: \(latest)"
        var info = "You're on \(current). \(release.name) is ready to download."
        if !release.notes.isEmpty {
            info += "\n\n" + String(release.notes.prefix(800))
        }
        info += "\n\nClick Download, then replace /Applications/ScreenChecker.app with the new copy."
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download…")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func showUpToDateAlert(current: String) {
        activate()
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "ScreenChecker \(current) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showErrorAlert(_ error: UpdateError) {
        activate()
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = error.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private enum UpdateError: Error {
    case notConfigured
    case noReleases(String)
    case network(String)

    var message: String {
        switch self {
        case .notConfigured:
            return "No update feed configured yet.\n\nSet your GitHub repo in app/Info.plist as SCUpdateRepo (e.g. \"you/screen-checker\"), rebuild, and tag a release."
        case let .noReleases(repo):
            return "No published releases found for \(repo).\n\nCreate one on GitHub (tag like v0.2.0 + attach ScreenChecker.app.zip)."
        case let .network(detail):
            return detail + "\n\nCheck your connection and try again."
        }
    }
}
