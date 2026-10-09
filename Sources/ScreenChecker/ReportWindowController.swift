import AppKit
import ScreenCheckerCore

/// Report: today's counts plus a 7-day trend and recent timeline.
/// Includes one-click corrections (mark productive / reopen closed tab).
final class ReportWindowController: NSWindowController {
    private var viewController: ReportViewController?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
            styleMask: [.titled, .closable],
             backing: .buffered,
            defer: false
        )
        window.title = "ScreenChecker — Report"
        self.init(window: window)
        let viewController = ReportViewController()
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

private final class ReportViewController: NSViewController {
    private let textView = NSTextView()

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshAction(_:)))
        let productive = NSButton(title: "Last distraction was productive", target: self, action: #selector(markProductive(_:)))
        let reopen = NSButton(title: "Reopen closed tab", target: self, action: #selector(reopenClosed(_:)))
        let buttons = NSStackView(views: [refresh, productive, reopen])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(buttons)

        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 560))
        view.addSubview(stack)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.topAnchor.constraint(equalTo: stack.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
    }

    @objc private func refreshAction(_ sender: Any?) { refresh() }

    @objc private func markProductive(_ sender: Any?) {
        MonitorController.shared.notifier.applyLearningFeedback()
        refresh()
    }

    @objc private func reopenClosed(_ sender: Any?) {
        if !MonitorController.shared.monitor.reopenLastClosedTab() {
            NSSound.beep()
        }
    }

    func refresh() {
        let controller = MonitorController.shared
        let store = controller.eventStore
        textView.string = Self.format(today: store.summary(on: Date()), week: store.lastDays(7))
    }

    static func format(today: EventStore.DailySummary, week: [EventStore.DailySummary]) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE, MMM d"
        let shortFormatter = DateFormatter()
        shortFormatter.dateFormat = "EEE MM/dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        var lines: [String] = []
        lines.append("ScreenChecker — \(dayFormatter.string(from: today.date))")
        lines.append(
            "Samples: \(today.total) · Productive: \(today.productive) · "
                + "Distractions: \(today.distraction) · LLM-judged: \(today.llmCalls)"
        )
        if !today.perCategory.isEmpty {
            let categories = today.perCategory
                .sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            lines.append("Distractions by category: \(categories)")
        }
        if !today.perAction.isEmpty {
            let actions = today.perAction
                .sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            lines.append("Actions: \(actions)")
        }
        lines.append("")
        lines.append("Last 7 days:")
        for day in week {
            lines.append(
                "\(shortFormatter.string(from: day.date)): "
                    + "\(day.total) samples · \(day.productive) productive · "
                    + "\(day.distraction) distractions · \(day.llmCalls) LLM"
            )
        }
        let configProblems = MonitorController.shared.configStore.get().validationErrors()
        if !configProblems.isEmpty {
            lines.append("")
            lines.append("Config issues:")
            for p in configProblems { lines.append("  ! \(p)") }
        }
        lines.append("")
        lines.append("Recent activity (last 40):")
        let icons: [String: String] = ["productive": "🟢", "distraction": "🔴", "ambiguous": "🟡"]
        for event in today.events.suffix(40) {
            let icon = icons[event.verdict] ?? "⚪"
            let subject = event.title.isEmpty ? (event.url ?? event.app) : event.title
            var extra = ""
            if event.tier == 1 {
                if let confidence = event.confidence {
                    extra = String(format: " (llm %.2f)", confidence)
                } else {
                    extra = " (llm)"
                }
            }
            if let error = event.error, !error.isEmpty {
                extra += " [error: \(String(error.prefix(80)))]"
            }
            lines.append(
                "\(timeFormatter.string(from: event.ts)) \(icon) \(event.verdict)\(extra) — "
                    + "\(String(subject.prefix(70))) [\(event.action)]"
            )
        }
        if today.events.isEmpty {
            lines.append("(no events yet — monitoring runs inside your configured slots)")
        }
        return lines.joined(separator: "\n")
    }
}
