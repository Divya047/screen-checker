import AppKit
import Foundation
import os

/// Orchestrates the monitoring loop:
///
///   tick (every sampleInterval while active)
///     -> Sampler metadata (cheap, no screenshot)
///     -> idle skip (user away)
///     -> verdict cache (same app+URL => reuse for verdictCacheTTL)
///     -> RuleClassifier (tier 0, instant, offline)
///     -> if ambiguous: capture screenshot + OpenCodeClassifier (tier 1)
///     -> Enforcer (close tab / hide app, guarded, per-target cooldown)
///     -> EventStore (JSONL log; evidence screenshots disabled)
///
/// Evidence is intentionally never saved: temp captures are always deleted.
public final class Monitor: @unchecked Sendable {
    public struct Status: Sendable {
        public let monitoring: Bool
        public let detail: String
        public let breakUntil: Date?
    }

    public let configStore: ConfigStore
    public let eventStore: EventStore
    public let supportDirectory: URL
    private let engine: ActivationEngine
    private let sampler = Sampler()
    private let rules = RuleClassifier()
    private let enforcer = Enforcer()
    private let llm: OpenCodeClassifier
    private let log = Logger(subsystem: "dev.screenchecker.app", category: "monitor")

    private let stateLock = NSLock()
    private var _learningBreakUntil: Date?
    private var _testOverrideUntil: Date?
    private var _busy = false
    private var _droppedTicks = 0
    private var verdictCache: [String: (at: Date, classification: Classification)] = [:]
    private var _lastClosedTab: (url: String, bundleID: String?, at: Date)?

    public var onEvent: ((ScreenEvent) -> Void)?
    public var onStatus: ((Status) -> Void)?

    public init(configStore: ConfigStore, eventStore: EventStore, supportDirectory: URL) {
        self.configStore = configStore
        self.eventStore = eventStore
        self.supportDirectory = supportDirectory
        self.engine = ActivationEngine()
        self.llm = OpenCodeClassifier(
            configProvider: { [configStore] in configStore.get() },
            workingDirectory: supportDirectory
        )
        engine.onScreenStateChanged = { [weak self] _ in self?.publishStatus() }
        try? llm.installAgent()
    }

    public var droppedTicks: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _droppedTicks
    }

    /// Most recently closed tab (for Undo / Reopen). Expires after 10 min.
    public var lastClosedTab: (url: String, bundleID: String?, at: Date)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let c = _lastClosedTab, Date().timeIntervalSince(c.at) < 600 else { return nil }
        return c
    }

    /// Reopens the last closed tab in the default browser. Returns false when
    /// there is nothing recent to reopen.
    @discardableResult
    public func reopenLastClosedTab() -> Bool {
        guard let closed = lastClosedTab, let url = URL(string: closed.url) else { return false }
        NSWorkspace.shared.open(url)
        log.info("reopened closed tab \(closed.url, privacy: .public)")
        return true
    }

    // MARK: - Learning break

    public var learningBreakUntil: Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _learningBreakUntil
    }

    public func startLearningBreak(minutes: Double) {
        stateLock.lock()
        _learningBreakUntil = Date().addingTimeInterval(minutes * 60)
        stateLock.unlock()
        publishStatus()
    }

    public func endLearningBreak() {
        stateLock.lock()
        _learningBreakUntil = nil
        stateLock.unlock()
        publishStatus()
    }

    // MARK: - Test override (try it now, outside slots)

    /// When set, sampling runs regardless of configured slots (still pauses
    /// for learning breaks, locked screen, or disabled monitoring).
    public var testOverrideUntil: Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let until = _testOverrideUntil, Date() < until {
            return until
        }
        return nil
    }

    public func startTestOverride(minutes: Double = 10) {
        stateLock.lock()
        _testOverrideUntil = Date().addingTimeInterval(minutes * 60)
        stateLock.unlock()
        publishStatus()
    }

    public func endTestOverride() {
        stateLock.lock()
        _testOverrideUntil = nil
        stateLock.unlock()
        publishStatus()
    }

    // MARK: - Activation

    public func isMonitoringActive(at date: Date = Date()) -> Bool {
        if let until = learningBreakUntil, date < until { return false }
        let config = configStore.get()
        guard config.enabled else { return false }
        if testOverrideUntil != nil {
            return engine.isScreenUsable
        }
        return engine.slotActive(on: date, config: config)
    }

    public func refreshStatus() { publishStatus() }

    // MARK: - Agent / classifier plumbing (for onboarding UI)

    public func reinstallAgent() throws {
        try llm.installAgent()
    }

    public func agentInstalled() -> Bool {
        llm.agentInstalled()
    }

    public func classifierBinaryStatus() -> String? {
        llm.binaryStatus(config: configStore.get())
    }

    // MARK: - Tick

    /// - Parameter force: bypass the slot/active gate for a single manual
    ///   "Check screen now" sample. Learning-break still suppresses enforcement
    ///   downstream via the Enforcer; the event is always logged.
    public func tick(force: Bool = false) async {
        stateLock.lock()
        if _busy {
            _droppedTicks += 1
            let dropped = _droppedTicks
            stateLock.unlock()
            if dropped == 1 || dropped % 10 == 0 {
                log.debug("tick dropped (LLM in flight), total dropped=\(dropped)")
            }
            return
        }
        _busy = true
        stateLock.unlock()
        defer {
            stateLock.lock()
            _busy = false
            stateLock.unlock()
        }

        let config = configStore.get()
        guard force || isMonitoringActive() else {
            publishStatus()
            return
        }

        // Idle skip: don't judge a screen nobody is looking at. Cheap
        // CGEventSource query; force-ticks bypass it for manual testing.
        if !force, config.idleSkipSeconds > 0 {
            let idle = IdleDetector.secondsIdle()
            if idle >= config.idleSkipSeconds {
                log.debug("tick skipped: idle \(Int(idle))s")
                publishStatus()
                return
            }
        }

        // 1. Cheap metadata first — no screenshot yet.
        guard var snapshot = await sampler.sampleMetadata(excluding: Bundle.main.bundleIdentifier) else {
            publishStatus()
            return
        }

        let key = cacheKey(for: snapshot)

        // Fresh-enough verdict for the same target: reuse it without any
        // capture or LLM call. Cached distractions still re-trigger
        // enforcement (per-target cooldown), so nagging stops when the tab closes.
        if let cached = cachedVerdict(key: key, ttl: config.verdictCacheTTL) {
            if case .distraction = cached.verdict {
                let action = await enforcer.enforce(
                    snapshot: snapshot,
                    classification: cached,
                    config: config,
                    learningBreakUntil: learningBreakUntil
                )
                var event = Self.event(for: snapshot, classification: cached)
                event.action = action.rawValue
                rememberClosedTab(snapshot: snapshot, action: action)
                eventStore.append(event)
                onEvent?(event)
            }
            publishStatus()
            return
        }

        // 2. Tier-0 rules (instant, offline).
        var classification = rules.classify(snapshot, config: config)

        // 3. Tier-1 only for ambiguous: capture screenshot lazily, then LLM.
        if case .ambiguous = classification.verdict, config.llmForAmbiguous {
            snapshot = await sampler.attachScreenshot(to: snapshot)
            if snapshot.screenshotPath != nil {
                let started = Date()
                classification = await llm.classify(snapshot)
                log.debug("llm verdict \(String(describing: classification.verdict), privacy: .public) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            } else {
                // No capture (e.g. permission missing): stay ambiguous,
                // never enforce.
                classification = Classification(
                    verdict: .ambiguous(reason: "no screenshot available"),
                    tier: 1, model: config.opencodeModel, error: "screenshot unavailable"
                )
            }
        }
        storeVerdict(key: key, classification: classification)

        var action: EnforcementAction = .sampled
        if case .distraction = classification.verdict {
            action = await enforcer.enforce(
                snapshot: snapshot,
                classification: classification,
                config: config,
                learningBreakUntil: learningBreakUntil
            )
        }

        var event = Self.event(for: snapshot, classification: classification)
        event.action = action.rawValue
        rememberClosedTab(snapshot: snapshot, action: action)
        // Evidence disabled: never persist screenshots; always clean temp.
        event.screenshot = nil
        deleteTemp(snapshot.screenshotPath)

        eventStore.append(event)
        onEvent?(event)
        publishStatus()
    }

    private func rememberClosedTab(snapshot: ScreenSnapshot, action: EnforcementAction) {
        guard action == .closedTab, let url = snapshot.url, !url.isEmpty else { return }
        stateLock.lock()
        _lastClosedTab = (url, snapshot.appBundleID, Date())
        stateLock.unlock()
    }

    // MARK: - Event building

    static func event(for snapshot: ScreenSnapshot, classification: Classification) -> ScreenEvent {
        let verdictString: String
        var category: String?
        var reason: String?
        switch classification.verdict {
        case .productive(let r):
            verdictString = "productive"
            reason = r
        case .distraction(let r, let c):
            verdictString = "distraction"
            category = c
            reason = r
        case .ambiguous(let r):
            verdictString = "ambiguous"
            reason = r
        }
        return ScreenEvent(
            ts: snapshot.timestamp,
            app: snapshot.appName,
            bundleID: snapshot.appBundleID,
            title: snapshot.windowTitle,
            url: snapshot.url,
            verdict: verdictString,
            category: category,
            confidence: classification.confidence,
            reason: reason,
            tier: classification.tier,
            model: classification.model,
            action: "sampled",
            screenshot: nil,
            error: classification.error
        )
    }

    // MARK: - Verdict cache

    func cacheKey(for snapshot: ScreenSnapshot) -> String {
        let app = (snapshot.appBundleID ?? snapshot.appName).lowercased()
        if let url = snapshot.url, !url.isEmpty {
            return app + "|" + Self.normalizeURL(url)
        }
        return app + "|t:" + snapshot.windowTitle.lowercased().prefix(80)
    }

    /// Normalizes a URL to host+path for cache keys: lowercased host,
    /// tracking query params stripped, fragment dropped. YouTube watch URLs
    /// keep only the video ID so verdicts stay per-video.
    static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host else {
            return trimmed.lowercased()
        }
        let lowered = host.lowercased()
        if lowered.contains("youtube.com"), url.path.lowercased().contains("/watch") {
            let videoID = URLComponents(string: trimmed)?
                .queryItems?
                .first { $0.name == "v" }?
                .value?
                .lowercased()
            if let videoID, !videoID.isEmpty {
                return lowered + "/watch?v=" + videoID
            }
            return lowered + "/watch"
        }
        var path = url.path
        // Strip trailing slash (except root) so /a and /a/ share a verdict.
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.count > 60 { path = String(path.prefix(60)) }
        return lowered + path
    }

    func cachedVerdict(key: String, ttl: Double) -> Classification? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let entry = verdictCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) < max(60, ttl) else {
            verdictCache[key] = nil
            return nil
        }
        return entry.classification
    }

    func storeVerdict(key: String, classification: Classification) {
        stateLock.lock()
        defer { stateLock.unlock() }
        verdictCache[key] = (Date(), classification)
        // Keep the cache small; entries expire by TTL anyway.
        if verdictCache.count > 100 {
            let cutoff = Date().addingTimeInterval(-600)
            verdictCache = verdictCache.filter { $0.value.at > cutoff }
        }
    }

    // MARK: - Status

    func publishStatus() {
        let config = configStore.get()
        let active = isMonitoringActive()
        var detail: String
        if !config.enabled {
            detail = "Monitoring disabled"
        } else if let until = learningBreakUntil, Date() < until {
            let minutes = Int(until.timeIntervalSinceNow / 60) + 1
            detail = "Learning break — \(minutes) min left"
        } else if let until = testOverrideUntil {
            let minutes = Int(until.timeIntervalSinceNow / 60) + 1
            detail = engine.isScreenUsable
                ? "Test mode — \(minutes) min left"
                : (engine.screenLocked ? "Screen locked" : "Display asleep")
        } else if !engine.isScreenUsable {
            detail = engine.screenLocked ? "Screen locked" : "Display asleep"
        } else if active {
            detail = "Monitoring active"
        } else {
            detail = "Outside monitoring slots"
        }
        let problems = config.validationErrors()
        if !problems.isEmpty, active {
            detail += " (\(problems.count) config issue\(problems.count == 1 ? "" : "s"))"
        }
        onStatus?(Status(monitoring: active, detail: detail, breakUntil: learningBreakUntil))
    }

    func deleteTemp(_ path: String?, saved: Bool = false) {
        guard let path, !saved else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
