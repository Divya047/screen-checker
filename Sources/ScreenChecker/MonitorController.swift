import AppKit
import ScreenCheckerCore
import ServiceManagement

/// Owns the Core objects, drives the sample timer, and backs the menu bar.
final class MonitorController {
    static let shared = MonitorController()

    let supportDirectory: URL
    let configStore: ConfigStore
    let eventStore: EventStore
    let monitor: Monitor
    let notifier = Notifier()

    private var timer: Timer?
    private var lastTickAt = Date.distantPast

    var statusItem: StatusItemController?
    var settingsWindow: SettingsWindowController?
    var reportWindow: ReportWindowController?
    var onboardingWindow: OnboardingWindowController?

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        supportDirectory = base.appendingPathComponent("ScreenChecker", isDirectory: true)
        configStore = ConfigStore(directory: supportDirectory)
        eventStore = EventStore(directory: supportDirectory)
        monitor = Monitor(
            configStore: configStore,
            eventStore: eventStore,
            supportDirectory: supportDirectory
        )
        eventStore.prune(retentionDays: configStore.get().screenshotRetentionDays)
    }

    func start() {
        notifier.wire(configStore: configStore, eventStore: eventStore)
        notifier.reopenHandler = { [weak self] in
            self?.monitor.reopenLastClosedTab() ?? false
        }
        monitor.onEvent = { [weak self] event in
            self?.notifier.handle(event: event)
        }
        monitor.onStatus = { [weak self] status in
            self?.statusItem?.update(status)
        }

        statusItem = StatusItemController()
        statusItem?.start()
        monitor.refreshStatus()

        if !UserDefaults.standard.bool(forKey: "onboarded.v1") {
            showOnboarding()
        }

        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MonitorController.shared.fire()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Called once a second on the main run loop. Decides whether it is time
    /// for a sample; the heavy work happens off-main inside Monitor.tick().
    /// The per-second work here is two cheap in-memory checks; status UI
    /// refreshes only when the detail text changes (see StatusItemController).
    @objc func fire() {
        let active = monitor.isMonitoringActive()
        statusItem?.updateIfChanged(monitoring: active)
        let now = Date()
        guard active else {
            lastTickAt = .distantPast
            return
        }
        let config = configStore.get()
        guard now.timeIntervalSince(lastTickAt) >= max(5, config.sampleInterval) else { return }
        lastTickAt = now
        Task.detached(priority: .utility) {
            await self.monitor.tick()
        }
    }

    // MARK: - Windows

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.show()
    }

    func showReport() {
        if reportWindow == nil {
            reportWindow = ReportWindowController()
        }
        reportWindow?.show()
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController()
        }
        onboardingWindow?.show()
        UserDefaults.standard.set(true, forKey: "onboarded.v1")
    }

    // MARK: - Login item

    func loginItemEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    func toggleLoginItem() -> Bool {
        if loginItemEnabled() {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        return loginItemEnabled()
    }
}
