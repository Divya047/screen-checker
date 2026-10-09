import Foundation

/// Append-only daily JSONL logs + screenshot evidence, with pruning.
public final class EventStore: @unchecked Sendable {
    public let directory: URL
    public var eventsDirectory: URL { directory.appendingPathComponent("events") }
    public var evidenceDirectory: URL { directory.appendingPathComponent("evidence") }

    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
    }

    // MARK: Events

    public func append(_ event: ScreenEvent) {
        lock.lock()
        defer { lock.unlock() }
        let url = eventsDirectory.appendingPathComponent(dayFormatter.string(from: event.ts) + ".jsonl")
        guard let data = try? encoder.encode(event),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8) ?? Data())
    }

    public func events(on date: Date) -> [ScreenEvent] {
        let url = eventsDirectory.appendingPathComponent(dayFormatter.string(from: date) + ".jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .compactMap { try? decoder.decode(ScreenEvent.self, from: Data($0.utf8)) }
    }

    /// Most recent distraction event within `within` seconds — used by the
    /// "This was productive" notification action.
    public func recentDistraction(within seconds: TimeInterval) -> ScreenEvent? {
        let cutoff = Date().addingTimeInterval(-seconds)
        return events(on: Date())
            .last { $0.verdict == "distraction" && $0.ts >= cutoff }
    }

    // MARK: Evidence (disabled — never saved; see Monitor.tick)

    /// Evidence saving is disabled by default (user never reviews it).
    /// Kept for API compatibility; always returns nil and never writes.
    @discardableResult
    public func saveEvidence(from tempPath: String) -> String? {
        return nil
    }

    /// Deletes any leftover evidence files from older versions.
    public func purgeEvidence() {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: evidenceDirectory, includingPropertiesForKeys: nil) {
            for file in files { try? fm.removeItem(at: file) }
        }
    }

    /// Drops old screenshots (per config) and very old event logs.
    /// Evidence is always purged (saving disabled); event logs keep 90 days.
    public func prune(retentionDays: Int) {
        purgeEvidence()
        let fm = FileManager.default
        let eventCutoff = Date().addingTimeInterval(-90 * 86400)
        if let files = try? fm.contentsOfDirectory(at: eventsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in files {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let date, date < eventCutoff {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }

    // MARK: Summary

    public struct DailySummary: Sendable {
        public let date: Date
        public let total: Int
        public let productive: Int
        public let distraction: Int
        public let ambiguous: Int
        public let llmCalls: Int
        public let perCategory: [String: Int]
        public let perAction: [String: Int]
        public let events: [ScreenEvent]
    }

    public func summary(on date: Date) -> DailySummary {
        let events = events(on: date)
        var perCategory: [String: Int] = [:]
        var perAction: [String: Int] = [:]
        for e in events {
            if e.verdict == "distraction" {
                perCategory[e.category ?? "other", default: 0] += 1
            }
            perAction[e.action, default: 0] += 1
        }
        return DailySummary(
            date: date,
            total: events.count,
            productive: events.filter { $0.verdict == "productive" }.count,
            distraction: events.filter { $0.verdict == "distraction" }.count,
            ambiguous: events.filter { $0.verdict == "ambiguous" }.count,
            llmCalls: events.filter { $0.tier == 1 }.count,
            perCategory: perCategory,
            perAction: perAction,
            events: events
        )
    }

    /// Last N days of daily summaries (today first). Cheap: one small JSONL
    /// read per day.
    public func lastDays(_ n: Int) -> [DailySummary] {
        (0..<max(1, n)).map { offset in
            let date = Date().addingTimeInterval(-Double(offset) * 86400)
            return summary(on: date)
        }
    }
}
