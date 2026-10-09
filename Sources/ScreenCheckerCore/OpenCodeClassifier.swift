import Foundation

/// Tier 1: vision LLM classification via the local `opencode` CLI.
///
/// The agent lives in `<supportDir>/.opencode/agents/screen-classifier.md`
/// (auto-installed) with every tool denied and `steps: 1`, so an unattended
/// background invocation can never touch the filesystem or run shell commands —
/// it can only read the prompt + attached screenshot and reply.
///
/// Fail-open policy: any error, timeout, or unparseable reply is classified as
/// productive with an `error` recorded, so a broken backend never closes
/// a real work window.
public final class OpenCodeClassifier: @unchecked Sendable {
    public enum ClassifierError: LocalizedError {
        case binaryNotFound
        case opencodeFailed(exitCode: Int32, output: String)

        public var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "opencode binary not found"
            case .opencodeFailed(let code, let output):
                return "opencode run failed (exit \(code)): \(output)"
            }
        }
    }

    private let configProvider: () -> AppConfig
    private let workingDirectory: URL
    private var cachedBinary: String?
    private let lock = NSLock()

    public init(configProvider: @escaping () -> AppConfig, workingDirectory: URL) {
        self.configProvider = configProvider
        self.workingDirectory = workingDirectory
    }

    // MARK: - Agent

    /// The canonical agent definition (also kept at config/screen-classifier.md
    /// in the repository). Verified end-to-end against mimo-v2.6-pro.
    public static let agentName = "screen-classifier"

    public static let agentMarkdown = """
        ---
        description: Classifies a screenshot of the user's frontmost window as productive or a distraction; replies with JSON only. Has no tools.
        mode: primary
        steps: 1
        permissions:
          - action: "*"
            resource: "*"
            effect: deny
        ---

        You are the classification engine of ScreenChecker, a local productivity watchdog. You receive a screenshot of the user's frontmost window, plus metadata: application name, window title, and browser URL when available.

        Judge whether the on-screen content is PRODUCTIVE (work, study, learning, tools, or neutral) or a DISTRACTION (entertainment during focus time).

        Policy:

        - Learning is NEVER a distraction: tutorials, courses, lectures, documentation, conference talks, coding videos, educational channels — including on YouTube or any other platform.
        - Distractions: short-form video feeds (YouTube Shorts, TikTok, Instagram Reels), social media scrolling, streaming entertainment (Netflix, etc.), casual games, meme or entertainment browsing.
        - Work tools, IDEs, terminals, documents, spreadsheets, email, calendars, work chat, file managers: productive.
        - If the metadata shows the user allowlisted this site, channel, or topic for learning, it is productive.
        - When genuinely uncertain, lean PRODUCTIVE (fail-open) and lower your confidence instead.

        Reply with ONLY one line of JSON, no markdown fences, no extra text:

        {"is_distraction": false, "confidence": 0.0, "category": "none", "reason": "short sentence"}

        category is one of: shorts, social, streaming, game, entertainment, other, none.
        """

    public func agentFileURL() -> URL {
        workingDirectory
            .appendingPathComponent(".opencode/agents", isDirectory: true)
            .appendingPathComponent(Self.agentName + ".md")
    }

    /// Idempotent: (re)installs the agent into the working directory.
    public func installAgent() throws {
        let url = agentFileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == Self.agentMarkdown {
            return
        }
        try Self.agentMarkdown.write(to: url, atomically: true, encoding: .utf8)
    }

    public func agentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: agentFileURL().path)
    }

    // MARK: - Classification

    public func classify(_ snapshot: ScreenSnapshot) async -> Classification {
        let config = configProvider()
        let model = config.opencodeModel
        do {
            let binary = try resolveBinary(config: config)
            try installAgent()
            let output = try await runOpencode(
                binary: binary,
                prompt: Self.prompt(for: snapshot),
                image: snapshot.screenshotPath,
                model: model,
                timeout: config.opencodeTimeout
            )
            let text = OpenCodeOutputParser.text(fromJSONEvents: output)
            guard let verdict = OpenCodeOutputParser.extractVerdict(from: text) else {
                return Classification(
                    verdict: .productive(reason: "fail-open: LLM output unparseable"),
                    tier: 1, model: model, error: "unparseable LLM output"
                )
            }
            let verdictValue: Verdict = verdict.isDistraction
                ? .distraction(reason: verdict.reason ?? "LLM judgment", category: verdict.category ?? "other")
                : .productive(reason: verdict.reason ?? "LLM judgment (productive)")
            return Classification(verdict: verdictValue, tier: 1, confidence: verdict.confidence, model: model)
        } catch {
            return Classification(
                verdict: .productive(reason: "fail-open: LLM error"),
                tier: 1, model: model, error: "\(error)"
            )
        }
    }

    static func prompt(for s: ScreenSnapshot) -> String {
        [
            "App: \(s.appName)",
            "Window title: \(s.windowTitle.isEmpty ? "(none)" : s.windowTitle)",
            "URL: \(s.url ?? "(unavailable)")",
            "Classify the user's current screen per policy. JSON verdict only.",
        ].joined(separator: " | ")
    }

    // MARK: - Binary resolution

    public func resolveBinary(config: AppConfig) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default

        // Re-validate the cache: the binary may have been deleted/upgraded.
        if let b = cachedBinary, config.opencodeBinaryPath == nil,
           fm.isExecutableFile(atPath: b) {
            return b
        }
        cachedBinary = nil
        if let override = config.opencodeBinaryPath,
           !override.isEmpty,
           fm.isExecutableFile(atPath: override) {
            cachedBinary = override
            return override
        }
        for candidate in [
            NSHomeDirectory() + "/.opencode/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
        ] where fm.isExecutableFile(atPath: candidate) {
            cachedBinary = candidate
            return candidate
        }
        // Fall back to whatever a login shell resolves on PATH.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v opencode"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus == 0,
               let path = String(data: data, encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               fm.isExecutableFile(atPath: path) {
                cachedBinary = path
                return path
            }
        } catch {}
        throw ClassifierError.binaryNotFound
    }

    /// For onboarding status display.
    public func binaryStatus(config: AppConfig) -> String? {
        try? resolveBinary(config: config)
    }

    // MARK: - Process execution

    @discardableResult
    func runOpencode(
        binary: String,
        prompt: String,
        image: String?,
        model: String,
        timeout: Double
    ) async throws -> String {
        let fm = FileManager.default
        var arguments = [
            "run",
            "--agent", Self.agentName,
            "--model", model,
            "--format", "json",
            "--title", "screencheck",
        ]
        if let image, fm.fileExists(atPath: image) {
            arguments += ["--file", image]
        }
        arguments.append(prompt)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.currentDirectoryURL = workingDirectory
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Read concurrently so a full pipe buffer can never deadlock the child.
        let stdoutTask = Task.detached(priority: .utility) {
            String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        let stderrTask = Task.detached(priority: .utility) {
            String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }

        try process.run()
        let exitCode = await Self.awaitTermination(process, timeout: max(5, timeout))
        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value

        guard exitCode == 0 else {
            let tail = (stdout + stderr)
                .split(separator: "\n")
                .suffix(3)
                .joined(separator: " | ")
            throw ClassifierError.opencodeFailed(exitCode: exitCode, output: String(tail))
        }
        return stdout
    }

    /// Waits for process exit, terminating it after `timeout` seconds.
    /// Escalates SIGTERM -> SIGKILL so a hung child can never leak.
    static func awaitTermination(_ process: Process, timeout: Double) async -> Int32 {
        await withCheckedContinuation { continuation in
            let gate = ContinuationGate(continuation)
            process.terminationHandler = { terminated in
                gate.resume(terminated.terminationStatus)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                        if process.isRunning {
                            // SIGKILL: terminate() only sends SIGTERM.
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }
        }
    }

    final class ContinuationGate: @unchecked Sendable {
        private let continuation: CheckedContinuation<Int32, Never>
        private let lock = NSLock()
        private var resumed = false

        init(_ continuation: CheckedContinuation<Int32, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Int32) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: value)
        }
    }
}
