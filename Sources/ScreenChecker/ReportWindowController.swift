import AppKit
import ScreenCheckerCore

/// Today's report: counts by verdict/category/action plus a recent timeline.
final class ReportWindowController: NSWindowController {
    private var viewController: ReportViewController?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScreenChecker — Today"
        self.init(window: window)
        let viewController = ReportViewController()
        self.viewController = viewController
        window.contentViewController = viewController
    }

    func show() {
        viewController?.refresh()
        showWindow(self)
        window?.center()
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
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(refresh)

        view = NSView()
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

    func refresh() {
        let store = MonitorController.shared.eventStore
        textView.string = Self.format(store.summary(on: Date()))
    }

    static func format(_ summary: EventStore.DailySummary) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE, MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        var lines: [String] = []
        lines.append("ScreenChecker — \(dayFormatter.string(from: summary.date))")
        lines.append(
            "Samples: \(summary.total) · Productive: \(summary.productive) · "
                + "Distractions: \(summary.distraction) · LLM-judged: \(summary.llmCalls)"
        )
        if !summary.perCategory.isEmpty {
            let categories = summary.perCategory
                .sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            lines.append("Distractions by category: \(categories)")
        }
        if !summary.perAction.isEmpty {
            let actions = summary.perAction
                .sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            lines.append("Actions: \(actions)")
        }
        lines.append("")
        lines.append("Recent activity (last 40):")
        let icons: [String: String] = ["productive": "🟢", "distraction": "🔴", "ambiguous": "🟡"]
        for event in summary.events.suffix(40) {
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
        if summary.events.isEmpty {
            lines.append("(no events yet — monitoring runs inside your configured slots)")
        }
        return lines.joined(separator: "\n")
    }
}
