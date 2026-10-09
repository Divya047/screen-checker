import AppKit
import ScreenCheckerCore

/// The menu bar status item: current state, quick toggles, windows.
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var stateLine: NSMenuItem!
    private var breakLine: NSMenuItem!
    private var checkNowLine: NSMenuItem!
    private var testModeLine: NSMenuItem!
    private var warnLine: NSMenuItem!
    private var enforceLine: NSMenuItem!
    private var loginLine: NSMenuItem!
    private var lastSymbol: String?
    private var lastDetail = "starting…"

    func start() {
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "ScreenChecker")
        button.toolTip = "ScreenChecker"

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLine = NSMenuItem(title: "ScreenChecker", action: nil, keyEquivalent: "")
        stateLine.isEnabled = false
        menu.addItem(stateLine)
        menu.addItem(.separator())

        breakLine = NSMenuItem(
            title: "Start learning break", action: #selector(toggleBreak(_:)), keyEquivalent: "b"
        )
        breakLine.target = self
        menu.addItem(breakLine)

        checkNowLine = NSMenuItem(
            title: "Check screen now (test)", action: #selector(checkNow(_:)), keyEquivalent: "t"
        )
        checkNowLine.target = self
        menu.addItem(checkNowLine)

        testModeLine = NSMenuItem(
            title: "Monitor continuously (10 min)", action: #selector(toggleTestMode(_:)), keyEquivalent: "T"
        )
        testModeLine.target = self
        menu.addItem(testModeLine)
        menu.addItem(.separator())

        warnLine = NSMenuItem(
            title: "Mode: Warn only", action: #selector(setWarnMode(_:)), keyEquivalent: "1"
        )
        warnLine.target = self
        menu.addItem(warnLine)
        enforceLine = NSMenuItem(
            title: "Mode: Enforce (close tabs)", action: #selector(setEnforceMode(_:)), keyEquivalent: "2"
        )
        enforceLine.target = self
        menu.addItem(enforceLine)
        menu.addItem(.separator())

        for (title, action, key) in [
            ("Settings…", #selector(openSettings(_:)), ","),
            ("Today's report…", #selector(openReport(_:)), "r"),
            ("Permissions & onboarding…", #selector(openOnboarding(_:)), "o"),
        ] {
            let line = NSMenuItem(title: title, action: action, keyEquivalent: key)
            line.target = self
            menu.addItem(line)
        }

        loginLine = NSMenuItem(
            title: "Launch at login", action: #selector(toggleLoginItem(_:)), keyEquivalent: ""
        )
        loginLine.target = self
        menu.addItem(loginLine)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit ScreenChecker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        menu.addItem(quit)

        item.menu = menu
        refreshLines()
    }

    // MARK: - State

    func update(_ status: Monitor.Status) {
        guard let button = item.button else { return }
        let symbol: String
        if let until = status.breakUntil, Date() < until {
            symbol = "cup.and.saucer.fill"
        } else if status.monitoring {
            symbol = "eye.fill"
        } else {
            symbol = "eye.slash"
        }
        if symbol != lastSymbol {
            lastSymbol = symbol
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: status.detail)
        }
        lastDetail = status.detail
        button.toolTip = "ScreenChecker — \(status.detail)"
        refreshLines()
    }

    private func refreshLines() {
        let controller = MonitorController.shared
        let config = controller.configStore.get()
        stateLine.title = "ScreenChecker — \(lastDetail)"

        if let until = controller.monitor.learningBreakUntil, Date() < until {
            breakLine.title = "Resume early (break active)"
        } else {
            let minutes = Int(config.learningBreakMinutes)
            breakLine.title = "Start \(minutes)-min learning break"
        }

        if controller.monitor.testOverrideUntil != nil {
            testModeLine.title = "Stop test mode"
        } else {
            testModeLine.title = "Monitor continuously (10 min)"
        }

        warnLine.state = config.mode == .warnOnly ? .on : .off
        enforceLine.state = config.mode == .enforce ? .on : .off
        loginLine.state = controller.loginItemEnabled() ? .on : .off
    }

    // MARK: - Actions

    @objc private func toggleBreak(_ sender: Any?) {
        let controller = MonitorController.shared
        let monitor = controller.monitor
        if let until = monitor.learningBreakUntil, Date() < until {
            monitor.endLearningBreak()
        } else {
            let minutes = controller.configStore.get().learningBreakMinutes
            monitor.startLearningBreak(minutes: minutes)
        }
    }

    @objc private func checkNow(_ sender: Any?) {
        let monitor = MonitorController.shared.monitor
        Task.detached(priority: .utility) {
            await monitor.tick(force: true)
        }
    }

    @objc private func toggleTestMode(_ sender: Any?) {
        let monitor = MonitorController.shared.monitor
        if monitor.testOverrideUntil != nil {
            monitor.endTestOverride()
        } else {
            monitor.startTestOverride(minutes: 10)
        }
    }

    @objc private func setWarnMode(_ sender: Any?) {
        MonitorController.shared.configStore.mutate { $0.mode = .warnOnly }
        MonitorController.shared.monitor.refreshStatus()
    }

    @objc private func setEnforceMode(_ sender: Any?) {
        MonitorController.shared.configStore.mutate { $0.mode = .enforce }
        MonitorController.shared.monitor.refreshStatus()
    }

    @objc private func openSettings(_ sender: Any?) { MonitorController.shared.showSettings() }
    @objc private func openReport(_ sender: Any?) { MonitorController.shared.showReport() }
    @objc private func openOnboarding(_ sender: Any?) { MonitorController.shared.showOnboarding() }
    @objc private func toggleLoginItem(_ sender: Any?) { _ = MonitorController.shared.toggleLoginItem() }
}
