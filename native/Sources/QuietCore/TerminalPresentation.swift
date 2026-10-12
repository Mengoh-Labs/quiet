import Foundation

public enum QuietVersion { public static let current = "0.12.0" }

public enum TerminalSynchronizedOutput {
    public static let query = "\u{1b}[?2026$p"
    public static let begin = "\u{1b}[?2026h"
    public static let end = "\u{1b}[?2026l"

    /// Encode the entire frame before holding the terminal's display. Never hold it while sampling.
    public static func frame(_ content: String, enabled: Bool) -> String {
        guard !content.isEmpty else { return "" }
        return enabled ? begin + content + end : content
    }
}

/// Deadline-based pacing: rendering time is part of the frame budget, not added to it.
/// Slow output lowers the rate rather than queuing stale frames or trying to catch up.
public struct TerminalFramePacer {
    private var nextFrame = 0.0
    private var framePeriod = 1.0 / 60
    public init() {}
    public var framesPerSecond: Double { 1 / framePeriod }
    public func due(at now: Double) -> Bool { now >= nextFrame }
    public mutating func reset() { nextFrame = 0; framePeriod = 1.0 / 60 }
    public mutating func completed(started: Double, ended: Double) {
        let cost = max(0, ended - started)
        // Keep headroom for input and sampling; recover gradually after a slow frame.
        framePeriod = max(1.0 / 60, min(0.1, max(cost * 1.25, framePeriod * 0.9)))
        nextFrame = max(ended, started + framePeriod)
    }
    public func sleepMilliseconds(at now: Double, animating: Bool) -> Int {
        guard animating else { return 50 }
        return max(1, min(50, Int(ceil(max(0, nextFrame - now) * 1000))))
    }
}
