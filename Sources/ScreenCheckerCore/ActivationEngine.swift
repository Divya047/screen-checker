import AppKit
import Foundation

/// Tracks whether the screen is usable (unlocked, awake) and combines that
/// with the configured time slots to answer "should the monitor sample now?".
public final class ActivationEngine: @unchecked Sendable {
    public var onScreenStateChanged: ((Bool) -> Void)?

    private(set) var screenLocked: Bool
    private(set) var screensAsleep: Bool = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private let distributedCenter = DistributedNotificationCenter.default()

    public init() {
        screenLocked = !Self.userSessionOnConsole()
        observe()
    }

    deinit {
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
        distributedObservers.forEach { distributedCenter.removeObserver($0) }
    }

    private func observe() {
        let queue = OperationQueue.main
        // User session activation (login, unlock, fast-user-switch back).
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: queue
        ) { [weak self] _ in self?.setLocked(false) })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: queue
        ) { [weak self] _ in self?.setLocked(true) })
        // Lock screen / screensaver lock events.
        distributedObservers.append(distributedCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: queue
        ) { [weak self] _ in self?.setLocked(true) })
        distributedObservers.append(distributedCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: queue
        ) { [weak self] _ in self?.setLocked(false) })
        // Display sleep.
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: queue
        ) { [weak self] _ in self?.setAsleep(true) })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: queue
        ) { [weak self] _ in self?.setAsleep(false) })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: queue
        ) { [weak self] _ in self?.setAsleep(false) })
    }

    private func setLocked(_ value: Bool) {
        if screenLocked != value {
            screenLocked = value
            emit()
        }
    }

    private func setAsleep(_ value: Bool) {
        if screensAsleep != value {
            screensAsleep = value
            emit()
        }
    }

    private func emit() {
        onScreenStateChanged?(isScreenUsable)
    }

    public var isScreenUsable: Bool { !screenLocked && !screensAsleep }

    /// Best-effort initial state: the console user's session dict disappears
    /// from this process when the loginwindow owns the screen.
    static func userSessionOnConsole() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() else {
            return false
        }
        let dict = session as NSDictionary
        return (dict[kCGSessionOnConsoleKey as String] as? Bool) ?? false
    }

    /// Pure, testable slot logic.
    public static func isSlotActive(
        _ date: Date,
        config: AppConfig,
        calendar: Calendar,
        screenUsable: Bool
    ) -> Bool {
        guard config.enabled, screenUsable else { return false }
        if config.skipWeekends {
            let weekday = calendar.component(.weekday, from: date)
            if weekday == 1 || weekday == 7 { return false }
        }
        return config.slots.contains { $0.contains(date, calendar: calendar) }
    }

    /// Instance form: current screen state + current time.
    public func slotActive(on date: Date = Date(), config: AppConfig, calendar: Calendar = .current) -> Bool {
        Self.isSlotActive(date, config: config, calendar: calendar, screenUsable: isScreenUsable)
    }
}
