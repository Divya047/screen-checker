import AppKit
import ScreenCheckerCore
import UserNotifications

/// One-time permission walkthrough: Screen Recording, Notifications,
/// Automation, and the opencode backend status.
final class OnboardingWindowController: NSWindowController {
    private var viewController: OnboardingViewController?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScreenChecker — Permissions & Onboarding"
        window.level = .floating
        self.init(window: window)
        let viewController = OnboardingViewController()
        self.viewController = viewController
        window.contentViewController = viewController
    }

    func show() {
        viewController?.refresh()
        showWindow(self)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class OnboardingViewController: NSViewController {
    private var screenRecordingStatus = NSTextField(labelWithString: "…")
    private var notificationsStatus = NSTextField(labelWithString: "…")
    private var automationStatus = NSTextField(labelWithString: "…")
    private var opencodeStatus = NSTextField(labelWithString: "…")

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let intro = NSTextField(labelWithString:
            "ScreenChecker watches the frontmost window during your monitoring slots and closes tabs judged distracting (learning content is exempt). It needs these one-time permissions:"
        )
        intro.lineBreakMode = .byWordWrapping
        intro.maximumNumberOfLines = 3
        intro.preferredMaxLayoutWidth = 560
        stack.addArrangedSubview(intro)

        stack.addArrangedSubview(block(
            title: "1 · Screen Recording",
            subtitle: "Reads window titles and captures the frontmost window screenshot.",
            status: screenRecordingStatus,
            buttonTitle: "Grant…",
            buttonAction: #selector(grantScreenRecording(_:))
        ))

        stack.addArrangedSubview(block(
            title: "2 · Notifications",
            subtitle: "Warns you when a distraction is detected or a tab is closed.",
            status: notificationsStatus,
            buttonTitle: "Enable…",
            buttonAction: #selector(enableNotifications(_:))
        ))

        stack.addArrangedSubview(block(
            title: "3 · Automation (browsers)",
            subtitle: "A one-time prompt appears the first time each browser is read or closed. Approve it.",
            status: automationStatus,
            buttonTitle: "Open Settings…",
            buttonAction: #selector(openAutomationSettings(_:))
        ))

        stack.addArrangedSubview(block(
            title: "4 · OpenCode backend (tier 1 vision classifier)",
            subtitle: "Uses the local opencode CLI with the screen-classifier agent (zero tools, deny-all).",
            status: opencodeStatus,
            buttonTitle: "Reinstall agent",
            buttonAction: #selector(reinstallAgent(_:))
        ))

        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow(_:)))
        done.bezelStyle = .rounded
        done.controlSize = .large
        stack.addArrangedSubview(done)

        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 430))
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        refresh()
    }

    // MARK: - Blocks

    private func block(
        title: String,
        subtitle: String,
        status: NSTextField,
        buttonTitle: String,
        buttonAction: Selector
    ) -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 10
        header.alignment = .firstBaseline

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        header.addArrangedSubview(titleLabel)

        status.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        header.addArrangedSubview(status)
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        let button = NSButton(title: buttonTitle, target: self, action: buttonAction)
        header.addArrangedSubview(button)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.preferredMaxLayoutWidth = 560

        let column = NSStackView(views: [header, subtitleLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        return column
    }

    // MARK: - Status refresh

    func refresh() {
        if ScreenshotCapture.hasPermission() {
            screenRecordingStatus.stringValue = "✅ granted"
        } else {
            screenRecordingStatus.stringValue = "⚠️ not granted"
        }

        Task {
            let text = await Notifier.notificationsStatusText()
            await MainActor.run { self.notificationsStatus.stringValue = text }
        }

        automationStatus.stringValue = "prompt on first browser read"

        let monitor = MonitorController.shared.monitor
        if let binary = monitor.classifierBinaryStatus() {
            let suffix = monitor.agentInstalled() ? " · agent installed" : " · agent missing"
            opencodeStatus.stringValue = "✅ \(binary)\(suffix)"
        } else {
            opencodeStatus.stringValue = "⚠️ opencode not found on PATH"
        }
    }

    // MARK: - Actions

    @objc private func grantScreenRecording(_ sender: Any?) {
        if ScreenshotCapture.hasPermission() {
            openPane("Privacy_ScreenCapture")
        } else {
            _ = ScreenshotCapture.requestPermission()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
        }
    }

    @objc private func enableNotifications(_ sender: Any?) {
        Task {
            let result = await Notifier.requestNotifications()
            await MainActor.run {
                self.notificationsStatus.stringValue =
                    result == "enabled" ? "✅ enabled" : "⚠️ \(result)"
            }
        }
    }

    @objc private func openAutomationSettings(_ sender: Any?) {
        openPane("Privacy_Automation")
    }

    @objc private func reinstallAgent(_ sender: Any?) {
        let monitor = MonitorController.shared.monitor
        do {
            try monitor.reinstallAgent()
            opencodeStatus.stringValue = "✅ agent reinstalled"
        } catch {
            opencodeStatus.stringValue = "⚠️ \(error.localizedDescription)"
        }
        refresh()
    }

    @objc private func closeWindow(_ sender: Any?) {
        view.window?.performClose(self)
    }

    private func openPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
