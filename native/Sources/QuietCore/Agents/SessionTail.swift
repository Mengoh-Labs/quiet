import Foundation

/// Follows one append-only session log. Reads only bytes added since the last call and keeps a
/// bounded ring of parsed events, so a long session costs the same memory as a short one.
public struct SessionTail: Sendable {
    public static let backgroundCapacity = 12
    public static let streamCapacity = 500
    static let lineLimit = 4 * 1024 * 1024

    public let path: String
    public private(set) var events: [AgentEvent] = []
    public private(set) var workingDirectory: String?
    public private(set) var totalTokens = 0
    public private(set) var lastActivity: Date?
    /// Kept even after it scrolls out of the ring: what the agent was last asked to do.
    public private(set) var lastRequest: AgentEvent?
    /// Bumped whenever `events` changes, so views can cache their layout.
    public private(set) var revision = 0
    public var capacity: Int { didSet { trim() } }

    private let parse: @Sendable (Data) -> AgentLogLine
    private var offset: UInt64 = 0
    private var started = false
    private var skippingLine = false
    private var carry = Data()
    private var fileNumber: UInt64?
    private var usageKeys: [String] = []
    private var usage: [(time: Date, tokens: Int)] = []

    public init(path: String, capacity: Int = SessionTail.backgroundCapacity, parse: @escaping @Sendable (Data) -> AgentLogLine) {
        self.path = path; self.capacity = capacity; self.parse = parse
    }

    /// Re-read a larger window from disk, for the session the owner opens in the stream.
    public mutating func deepen(window: UInt64 = 2 * 1024 * 1024, now: Date = Date()) {
        capacity = Self.streamCapacity
        started = false; events = []; usage = []; usageKeys = []; totalTokens = 0; carry = Data(); skippingLine = false
        read(window: window, now: now)
    }

    public mutating func read(window: UInt64 = 256 * 1024, now: Date = Date()) {
        guard let file = AgentLogFile(path) else { return }
        let size = file.size, number = file.number
        // A replaced or truncated file is a new log: start over rather than read from a stale offset.
        if started, number != fileNumber || size < offset { started = false; events = []; carry = Data(); skippingLine = false; revision += 1 }
        fileNumber = number
        if !started {
            started = true
            offset = size > window ? size - window : 0
            skippingLine = offset > 0   // the window almost certainly opens mid-line
        }
        guard size > offset else { return }
        let handle = file.handle
        // Far behind (the dashboard was paused or the log jumped): skip to the recent window.
        if size - offset > max(window, 1024 * 1024) { offset = size - window; carry = Data(); skippingLine = true }
        guard (try? handle.seek(toOffset: offset)) != nil, let chunk = try? handle.read(upToCount: Int(size - offset)) else { return }
        offset += UInt64(chunk.count)
        var changed = false
        carry.append(chunk)
        while let newline = carry.firstIndex(of: 10) {
            let line = carry[carry.startIndex..<newline]
            carry = Data(carry[carry.index(after: newline)...])
            if skippingLine { skippingLine = false; continue }
            guard !line.isEmpty else { continue }
            ingest(parse(Data(line)), now: now); changed = true
        }
        // One enormous line (a pasted file, a huge tool result) must not grow memory without bound.
        if carry.count > Self.lineLimit { carry = Data(); skippingLine = true }
        if changed { trim(); revision += 1 }
        usage.removeAll { now.timeIntervalSince($0.time) > 600 }
    }

    private mutating func ingest(_ line: AgentLogLine, now: Date) {
        if let directory = line.workingDirectory { workingDirectory = directory }
        for event in line.events {
            if event.kind == .usage {
                if let key = line.usageKey {
                    if usageKeys.contains(key) { continue }
                    usageKeys.append(key); if usageKeys.count > 64 { usageKeys.removeFirst() }
                }
                let tokens = event.tokens ?? 0
                totalTokens += tokens
                usage.append((event.timestamp ?? now, tokens))
            } else {
                events.append(event)
                if event.kind == .user { lastRequest = event }
            }
            if let time = event.timestamp, lastActivity.map({ time > $0 }) ?? true { lastActivity = time }
        }
    }
    private mutating func trim() { if events.count > capacity { events.removeFirst(events.count - capacity) } }

    /// Tokens recorded in the last minute by the log's own timestamps.
    public func tokensPerMinute(now: Date = Date()) -> Double {
        Double(usage.filter { now.timeIntervalSince($0.time) <= 60 && now.timeIntervalSince($0.time) >= -5 }.reduce(0) { $0 + $1.tokens })
    }
}
