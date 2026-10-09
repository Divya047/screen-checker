import AppKit
import ScreenCheckerCore

/// Settings: monitoring slots, sampling, strictness, LLM options,
/// plus shortcuts to the config file and evidence folders.
final class SettingsWindowController: NSWindowController {
    private var viewController: SettingsViewController?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScreenChecker — Settings"
        self.init(window: window)
        let viewController = SettingsViewController()
        self.viewController = viewController
        window.contentViewController = viewController
    }

    func show() {
        viewController?.populate()
        showWindow(self)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class SettingsViewController: NSViewController {
    private var modeControl = NSSegmentedControl(
        labels: ["Warn only", "Enforce"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private var intervalField = NSTextField()
    private var slotsField = NSTextField()
    private var weekendsButton = NSButton()
    private var confidenceField = NSTextField()
    private var breakField = NSTextField()
    private var keepShotsButton = NSButton()
    private var retentionField = NSTextField()
    private var llmButton = NSButton()
    private var modelField = NSTextField()
    private var timeoutField = NSTextField()
    private var binaryPathField = NSTextField()

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(row("Mode", modeControl))
        stack.addArrangedSubview(row("Monitoring slots (local time)", slotsField, placeholder: "12:00-13:00, 14:00-15:00"))
        stack.addArrangedSubview(row("Sampling interval (sec)", intervalField))
        stack.addArrangedSubview(row("Skip weekends", weekendsButton, checkbox: true))
        stack.addArrangedSubview(row("LLM confidence threshold (0–1)", confidenceField))
        stack.addArrangedSubview(row("Learning break length (min)", breakField))
        stack.addArrangedSubview(row("Keep screenshot evidence", keepShotsButton, checkbox: true))
        stack.addArrangedSubview(row("Evidence retention (days)", retentionField))
        stack.addArrangedSubview(row("Use LLM for ambiguous screens", llmButton, checkbox: true))
        stack.addArrangedSubview(row("opencode model", modelField, placeholder: "opencode-go/mimo-v2.6-pro"))
        stack.addArrangedSubview(row("opencode timeout (sec)", timeoutField))
        stack.addArrangedSubview(row("opencode binary path (optional)", binaryPathField, placeholder: "auto-detected"))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        buttons.addArrangedSubview(save)
        for (title, action) in [
            ("Reset defaults", #selector(resetDefaults(_:))),
            ("Open config.json", #selector(openConfig(_:))),
            ("Evidence folder", #selector(openEvidence(_:))),
            ("Events folder", #selector(openEvents(_:))),
        ] {
            buttons.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(buttons)

        view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 520))
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Rows

    private func row(_ label: String, _ control: NSView, placeholder: String? = nil, checkbox: Bool = false) -> NSView {
        let textLabel = NSTextField(labelWithString: label)
        textLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        if checkbox, let button = control as? NSButton {
            button.setButtonType(.switch)
            button.title = ""
        }
        if let field = control as? NSTextField, let placeholder {
            field.placeholderString = placeholder
        }
        fieldWidth(control)

        let row = NSStackView(views: [textLabel, control])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    private func fieldWidth(_ control: NSView) {
        if control is NSButton {
            control.widthAnchor.constraint(equalToConstant: 24).isActive = true
            return
        }
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
    }

    // MARK: - Populate / save

    func populate() {
        let config = MonitorController.shared.configStore.get()
        modeControl.setSelected(config.mode == .warnOnly, forSegment: 0)
        modeControl.setSelected(config.mode == .enforce, forSegment: 1)
        intervalField.stringValue = String(format: "%.0f", config.sampleInterval)
        slotsField.stringValue = config.slots
            .map { "\($0.start)-\($0.end)" }
            .joined(separator: ", ")
        weekendsButton.state = config.skipWeekends ? .on : .off
        confidenceField.stringValue = String(format: "%.2f", config.confidenceThreshold)
        breakField.stringValue = String(format: "%.0f", config.learningBreakMinutes)
        keepShotsButton.state = config.keepScreenshots ? .on : .off
        retentionField.stringValue = String(config.screenshotRetentionDays)
        llmButton.state = config.llmForAmbiguous ? .on : .off
        modelField.stringValue = config.opencodeModel
        timeoutField.stringValue = String(format: "%.0f", config.opencodeTimeout)
        binaryPathField.stringValue = config.opencodeBinaryPath ?? ""
    }

    @objc private func save(_ sender: Any?) {
        let controller = MonitorController.shared
        var config = controller.configStore.get()

        guard let interval = Double(intervalField.stringValue), interval >= 5 else {
            return alert("Sampling interval must be a number ≥ 5 seconds.")
        }
        guard let slots = Self.parseSlots(slotsField.stringValue) else {
            return alert("Slots must look like: 12:00-13:00, 14:00-15:00")
        }
        guard let confidence = Double(confidenceField.stringValue), confidence > 0, confidence <= 1 else {
            return alert("Confidence threshold must be between 0 and 1 (e.g. 0.8).")
        }
        guard let breakMinutes = Double(breakField.stringValue), breakMinutes >= 1 else {
            return alert("Learning break must be at least 1 minute.")
        }
        guard let days = Int(retentionField.stringValue), days >= 0 else {
            return alert("Evidence retention must be a whole number ≥ 0 days.")
        }
        guard let timeout = Double(timeoutField.stringValue), timeout >= 10 else {
            return alert("opencode timeout must be at least 10 seconds.")
        }

        config.mode = modeControl.isSelected(forSegment: 1) ? .enforce : .warnOnly
        config.sampleInterval = interval
        config.slots = slots
        config.skipWeekends = weekendsButton.state == .on
        config.confidenceThreshold = confidence
        config.learningBreakMinutes = breakMinutes
        config.keepScreenshots = keepShotsButton.state == .on
        config.screenshotRetentionDays = days
        config.llmForAmbiguous = llmButton.state == .on
        config.opencodeModel = modelField.stringValue.trimmingCharacters(in: .whitespaces)
        config.opencodeTimeout = timeout
        let binaryPath = binaryPathField.stringValue.trimmingCharacters(in: .whitespaces)
        config.opencodeBinaryPath = binaryPath.isEmpty ? nil : binaryPath

        controller.configStore.save(config)
        controller.monitor.refreshStatus()
    }

    @objc private func resetDefaults(_ sender: Any?) {
        let controller = MonitorController.shared
        controller.configStore.save(AppConfig())
        populate()
        controller.monitor.refreshStatus()
    }

    @objc private func openConfig(_ sender: Any?) {
        NSWorkspace.shared.open(MonitorController.shared.configStore.url)
    }

    @objc private func openEvidence(_ sender: Any?) {
        NSWorkspace.shared.open(MonitorController.shared.eventStore.evidenceDirectory)
    }

    @objc private func openEvents(_ sender: Any?) {
        NSWorkspace.shared.open(MonitorController.shared.eventStore.eventsDirectory)
    }

    static func parseSlots(_ raw: String) -> [TimeSlot]? {
        let parts = raw
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var slots: [TimeSlot] = []
        for part in parts {
            let halves = part
                .split(whereSeparator: { $0 == "-" || $0 == "–" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard halves.count == 2,
                  TimeSlot.minutes(from: halves[0]) != nil,
                  TimeSlot.minutes(from: halves[1]) != nil
            else { return nil }
            slots.append(TimeSlot(start: halves[0], end: halves[1]))
        }
        return slots
    }

    private func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't save settings"
        alert.informativeText = message
        alert.runModal()
    }
}
