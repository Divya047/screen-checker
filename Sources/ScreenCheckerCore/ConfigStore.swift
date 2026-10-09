import Foundation

/// Thread-safe holder for AppConfig, persisted as pretty JSON in the app
/// support directory. Loading merges user edits over defaults so new
/// fields added by app updates keep their default values.
public final class ConfigStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var cached: AppConfig

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent("config.json")
        self.cached = Self.load(from: url)
    }

    public func get() -> AppConfig {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    public func save(_ config: AppConfig) {
        lock.lock()
        cached = config
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func mutate(_ transform: (inout AppConfig) -> Void) {
        var config = get()
        transform(&config)
        save(config)
    }

    static func load(from url: URL) -> AppConfig {
        let defaults = AppConfig()
        let fm = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard fm.fileExists(atPath: url.path),
              let rawData = try? Data(contentsOf: url)
        else {
            // First run: write defaults so the user can find and edit them.
            if let data = try? encoder.encode(defaults) {
                try? data.write(to: url, options: .atomic)
            }
            return defaults
        }

        // Shallow-merge the loaded document over the defaults, so missing
        // fields fall back instead of failing the whole decode.
        guard let loadedObject = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any],
              let defaultsData = try? encoder.encode(defaults),
              let defaultsObject = (try? JSONSerialization.jsonObject(with: defaultsData)) as? [String: Any]
        else { return defaults }

        let merged = defaultsObject.merging(loadedObject) { _, loaded in loaded }

        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: mergedData)
        else { return defaults }

        return decoded
    }
}
