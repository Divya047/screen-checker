import Foundation

/// Tolerant extraction of the LLM verdict from `opencode run --format json`
/// output (NDJSON event stream) or any raw text containing the verdict JSON.
public enum OpenCodeOutputParser {
    public struct LLMVerdict: Equatable, Sendable {
        public var isDistraction: Bool
        public var confidence: Double?
        public var category: String?
        public var reason: String?

        public init(isDistraction: Bool, confidence: Double? = nil, category: String? = nil, reason: String? = nil) {
            self.isDistraction = isDistraction
            self.confidence = confidence
            self.category = category
            self.reason = reason
        }
    }

    /// Concatenates the text parts of an NDJSON event stream, e.g.
    /// {"type":"text","part":{"type":"text","text":"..."}}
    public static func text(fromJSONEvents output: String) -> String {
        var texts: [String] = []
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            if let part = obj["part"] as? [String: Any],
               (part["type"] as? String) == "text",
               let t = part["text"] as? String {
                texts.append(t)
            }
        }
        return texts.joined(separator: "\n")
    }

    /// Finds the first parseable `{"is_distraction": ...}` object.
    public static func extractVerdict(from text: String) -> LLMVerdict? {
        verdictIn(text, level: 0)
    }

    static func verdictIn(_ text: String, level: Int) -> LLMVerdict? {
        let objects = jsonObjects(in: text)
        for candidate in objects where candidate.lowercased().contains("is_distraction") {
            if let verdict = decode(candidate) { return verdict }
        }
        // The verdict JSON may be nested inside another JSON object the
        // model produced; look one level inside each candidate.
        guard level < 2 else { return nil }
        for candidate in objects {
            let interior = String(candidate.dropFirst().dropLast())
            if let verdict = verdictIn(interior, level: level + 1) {
                return verdict
            }
        }
        return nil
    }

    static func decode(_ s: String) -> LLMVerdict? {
        guard let data = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        guard let flag = boolValue(obj["is_distraction"]) ?? boolValue(obj["isDistraction"]) else {
            return nil
        }
        return LLMVerdict(
            isDistraction: flag,
            confidence: doubleValue(obj["confidence"]),
            category: obj["category"] as? String,
            reason: obj["reason"] as? String
        )
    }

    static func boolValue(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil // e.g. "maybe" — not a verdict, reject it
            }
        default: return nil
        }
    }

    static func doubleValue(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String, let d = Double(s) { return d }
        return nil
    }

    /// Returns the outermost `{...}` spans (string-aware, escape-aware).
    public static func jsonObjects(in text: String) -> [String] {
        var results: [String] = []
        var depth = 0
        var start: String.Index? = nil
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if ch == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let s = start {
                        results.append(String(text[s...index]))
                    }
                }
            }
            index = text.index(after: index)
        }
        return results
    }
}
