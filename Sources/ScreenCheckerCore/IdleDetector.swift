import CoreGraphics
import Foundation

/// Cheap idle check: seconds since last keyboard/mouse activity.
/// Returns 0 when the counter is unavailable. No polling, no overhead —
/// a single CGEventSource query per tick.
public enum IdleDetector {
    private static let probedTypes: [CGEventType] = [
        .keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel,
    ]

    public static func secondsIdle() -> Double {
        var best = Double.greatestFiniteMagnitude
        for t in probedTypes {
            let s = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: t)
            // 1e10+ means "never happened"; ignore those.
            if s.isFinite, s >= 0, s < 1e9 {
                best = min(best, s)
            }
        }
        return best == Double.greatestFiniteMagnitude ? 0 : best
    }
}
