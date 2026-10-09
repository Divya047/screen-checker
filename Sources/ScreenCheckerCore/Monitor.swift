import Foundation

/// Orchestrates the monitoring loop:
///
///   tick (every sampleInterval while active)
///     -> Sampler: frontmost app + window title + tab URL + window screenshot
///     -> RuleClassifier (tier 0, instant, offline)
///     -> if ambiguous: OpenCodeClassifier (tier 1, vision LLM via opencode)
///     -> verdict cache (same app+URL => reuse for verdictCacheTTL)
///     -> Enforcer (close tab / hide app, guarded)
///     -> EventStore (JSONL log + screenshot evidence)
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

    private let stateLock = NSLock()
    private var _learningBreakUntil: Date?
    private var _testOverrideUntil: Date?
    private var _busy = false
    private var verdictCache: [String: (at: Date, classification: Classification)] = [:]

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
            stateLock.unlock()
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

        guard let snapshot = await sampler.sample(excluding: Bundle.main.bundleIdentifier) else {
            publishStatus()
            return
        }

        let key = cacheKey(for: snapshot)

        // Fresh-enough verdict for the same target: reuse it. Cached
        // distractions still re-trigger enforcement (which has its own
        // cooldown), so the nagging stops only when the tab actually closes.
        if let cached = cachedVerdict(key: key, ttl: config.verdictCacheTTL) {
            deleteTemp(snapshot.screenshotPath)
            if case .distraction = cached.verdict {
                let action = await enforcer.enforce(
                    snapshot: snapshot,
                    classification: cached,
                    config: config,
                    learningBreakUntil: learningBreakUntil
                )
                var event = Self.event(for: snapshot, classification: cached)
                event.action = action.rawValue
                eventStore.append(event)
                onEvent?(event)
            }
            publishStatus()
            return
        }

        var classification = rules.classify(snapshot, config: config)
        if case .ambiguous = classification.verdict, config.llmForAmbiguous {
            classification = await llm.classify(snapshot)
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
        // Keep evidence for anything worth reviewing later: LLM judgments
        // (productive or not) and every distraction verdict.
        if (classification.tier == 1 || action != .sampled) && config.keepScreenshots,
           let path = snapshot.screenshotPath {
            event.screenshot = eventStore.saveEvidence(from: path)
        }
        deleteTemp(snapshot.screenshotPath, saved: event.screenshot != nil)

        eventStore.append(event)
        onEvent?(event)
        publishStatus()
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
        let urlKey = snapshot.url.map { Self.normalizeURL($0) } ?? ""
        let titleKey = String(snapshot.windowTitle.prefix(80))
        return (snapshot.appBundleID ?? snapshot.appName) + "|"
            + (urlKey.isEmpty ? titleKey : urlKey)
    }

    static func normalizeURL(_ raw: String) -> String {
        guard let url = URL(string: raw), let host = url.host else {
            return raw.lowercased()
        }
        let lowered = host.lowercased()
        // YouTube watch URLs collapse to the same path; keep the video ID so
        // verdicts stay per-video instead of per-site.
        if lowered.contains("youtube.com"), url.path.lowercased().contains("/watch") {
            let videoID = URLComponents(string: raw)?
                .queryItems?
                .first { $0.name == "v" }?
                .value
            if let videoID {
                return lowered + "/watch?v=" + videoID.lowercased()
            }
        }
        var path = url.path
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
        onStatus?(Status(monitoring: active, detail: detail, breakUntil: learningBreakUntil))
    }

    func deleteTemp(_ path: String?, saved: Bool = false) {
        guard let path, !saved else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
