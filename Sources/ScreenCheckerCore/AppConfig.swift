import Foundation

// MARK: - Time slot

public struct TimeSlot: Codable, Equatable, Sendable {
    /// "HH:mm" or "H:mm" (local time)
    public var start: String
    public var end: String
    public var label: String?

    public init(start: String, end: String, label: String? = nil) {
        self.start = start
        self.end = end
        self.label = label
    }

    public var startMinutes: Int? { Self.minutes(from: start) }
    public var endMinutes: Int? { Self.minutes(from: end) }

    public static func minutes(from hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              h >= 0, h < 24, m >= 0, m < 60
        else { return nil }
        return h * 60 + m
    }

    /// Inclusive start, exclusive end. A start > end wraps past midnight.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard let s = startMinutes, let e = endMinutes else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        guard let h = comps.hour, let m = comps.minute else { return false }
        let now = h * 60 + m
        if s <= e {
            return now >= s && now < e
        } else {
            return now >= s || now < e
        }
    }
}

// MARK: - Mode

public enum EnforcementMode: String, Codable, Sendable {
    case warnOnly = "warnOnly"
    case enforce = "enforce"
}

// MARK: - Config

public struct AppConfig: Codable, Sendable {
    public var enabled: Bool = true
    public var mode: EnforcementMode = .warnOnly

    /// When monitoring is armed (local time). Default: the lunch danger zone.
    public var slots: [TimeSlot] = [
        TimeSlot(start: "12:00", end: "13:00", label: "Lunch danger zone"),
    ]
    public var skipWeekends: Bool = true

    /// Seconds between samples while active.
    public var sampleInterval: Double = 30
    /// Minimum LLM confidence required to enforce (close/hide).
    public var confidenceThreshold: Double = 0.8
    /// Minimum seconds between two enforcement actions.
    public var enforcementCooldown: Double = 120
    /// Seconds a classification stays cached for the same app+URL.
    public var verdictCacheTTL: Double = 600
    /// Length of the "learning break" started from the menu.
    public var learningBreakMinutes: Double = 30

    /// Send ambiguous samples to the LLM classifier.
    public var llmForAmbiguous: Bool = true
    public var keepScreenshots: Bool = true
    public var screenshotRetentionDays: Int = 7

    public var opencodeModel: String = "opencode-go/mimo-v2.6-pro"
    public var opencodeTimeout: Double = 45
    /// Optional explicit path to the opencode binary.
    public var opencodeBinaryPath: String?

    /// Entries are bundle IDs ("com.apple.dt.Xcode") or app names ("Xcode").
    public var productiveApps: [String] = [
        "com.apple.dt.Xcode",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
        "com.sublimetext.4",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.goland",
        "com.apple.finder",
        "com.apple.Notes",
        "com.apple.mail",
        "md.obsidian",
    ]

    public var productiveURLPatterns: [String] = [
        "developer.apple.com",
        "docs.swift.org",
        "swift.org",
        "developer.mozilla.org",
        "github.com",
        "gitlab.com",
        "stackoverflow.com",
        "docs.python.org",
        "docs.docker.com",
        "kubernetes.io",
        "www.typescriptlang.org",
        "react.dev",
        "www.postgresql.org",
        "sqlite.org",
        "www.w3.org",
        "developer.chrome.com",
        "pypi.org",
    ]

    /// Explicitly fun stuff. Learning on the same sites is handled by the
    /// learning allowlists below, which take precedence.
    public var distractionURLPatterns: [String] = [
        "youtube.com/shorts",
        "tiktok.com",
        "instagram.com/reel",
        "reddit.com",
        "netflix.com",
        "twitch.tv",
        "x.com",
        "twitter.com",
        "facebook.com",
        "9gag.com",
        "imgur.com",
    ]

    /// Media players and games that are rarely work.
    public var distractionApps: [String] = [
        "VLC",
        "IINA",
        "mpv",
        "Steam",
    ]

    /// Added automatically when you tap "This was productive" on a notification.
    public var learningURLPatterns: [String] = []

    /// Learning allowlist: educational channels/sites are never distractions.
    public var learningChannelPatterns: [String] = [
        "youtube.com/@freecodecamp",
        "youtube.com/@3blue1brown",
        "youtube.com/@AppleDeveloper",
        "youtube.com/@GoogleTechTalks",
    ]

    public var learningTitleKeywords: [String] = [
        "tutorial",
        "lecture",
        "course",
        "documentation",
        "deep dive",
        "explained",
        "walkthrough",
        "how to",
        "conference talk",
        "workshop",
        "programming",
        "coding",
        "swiftui",
    ]

    /// Windows matching these are never enforced against.
    public var protectedTitleKeywords: [String] = [
        "meeting",
        "zoom",
        "invoice",
        "payment",
        "bank",
        "password",
        "keychain",
        "verification",
    ]

    public init() {}
}
