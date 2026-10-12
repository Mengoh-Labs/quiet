import Darwin
import Foundation

public enum AgentStatus: String, Sendable { case working, waiting, idle, unknown }

/// One running agent: a harness's root process, the helpers folded under it, and its session logs.
public struct AgentSession: Identifiable, Sendable {
    public let id: ProcessIdentity
    public var harnessID: String
    public var harness: String
    public var processCount: Int
    public var workingDirectory: String?
    public var launcher: String?
    public var title: String?
    public var status: AgentStatus
    /// Percent of one core, summed over the group; nil until two samples exist.
    public var cpu: Double?
    public var memory: UInt64
    /// Most recently written first.
    public var logs: [String]
    public var hasStream: Bool
    /// True when the log was matched by working directory and time rather than found open in the process.
    public var logInferred: Bool
    public var lastActivity: Date?
    public var tokensPerMinute: Double
    public var totalTokens: Int
    public var recent: [AgentEvent]
}

public struct AgentHarnessTotal: Sendable {
    public var harness: String
    public var sessions: Int
    public var cpu: Double
    public var memory: UInt64
    public var tokensPerMinute: Double
}

/// Not thread-safe: owned by whoever samples (the dashboard's main actor).
public final class AgentRegistry {
    private struct Facts {
        var refreshed = -Double.infinity
        var workingDirectory: String?
        var launcher: String?
        var title: String?
        var reported: AgentStatus?
        var logs: [String] = []
        var inferred = false
    }
    private let home: URL
    private let probe: any AgentProbing
    private let ownPID: Int32
    private var scripts: [ProcessIdentity: String?] = [:]
    private var facts: [ProcessIdentity: Facts] = [:]
    private var tails: [String: SessionTail] = [:]
    private var members: [ProcessIdentity: (root: ProcessIdentity, harness: String)] = [:]
    private var opened: String?
    private var parsers: [String: @Sendable (Data) -> AgentLogLine] = [:]
    private var confirmed: Set<ProcessIdentity> = []
    private var inferredClaims: [String: ProcessIdentity] = [:]
    private var rolloutDirectories: [String: String?] = [:]
    private func confirmedSession(_ process: ProcessIdentity) -> Bool {
        if confirmed.contains(process) { return true }
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/sessions/\(process.pid).json").path) else { return false }
        confirmed.insert(process); return true
    }
    public private(set) var sessions: [AgentSession] = []

    private let newTailsPerUpdate: Int
    /// Opening a log parses its recent window, so new logs are adopted a few per sample rather
    /// than all at once on the first frame.
    public init(home: URL = InvokingUser.home, probe: any AgentProbing = AgentProcessProbe(),
                ownPID: Int32 = getpid(), newTailsPerUpdate: Int = 2) {
        self.home = home; self.probe = probe; self.ownPID = ownPID; self.newTailsPerUpdate = newTailsPerUpdate
    }

    /// The harness label and session a process belongs to, for badges in the process view.
    public func membership(of process: ProcessIdentity) -> (root: ProcessIdentity, harness: String)? { members[process] }
    public func tail(_ path: String) -> SessionTail? { tails[path] }

    /// Keep a deep ring for the one log shown in the stream; every other tail stays small.
    public func open(_ path: String?, now: Date = Date()) {
        if let previous = opened, previous != path { tails[previous]?.capacity = SessionTail.backgroundCapacity }
        opened = path
        guard let path else { return }
        // The log may not have been adopted yet (adoption is staggered); the stream cannot wait for that.
        if tails[path] == nil, let parse = parsers[path] { tails[path] = SessionTail(path: path, parse: parse) }
        if tails[path] != nil, tails[path]?.capacity != SessionTail.streamCapacity { tails[path]?.deepen(now: now) }
    }

    @discardableResult
    public func update(processes: [ProcessSample], now: Date = Date(), uptime: Double) -> [AgentSession] {
        let table = Dictionary(processes.map { ($0.id.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var classified: [Int32: (AgentHarness, AgentRole)] = [:]
        let live = Set(processes.map(\.id))
        var unrecorded: [Int32] = []
        for process in processes where process.id.pid != ownPID {
            var script: String?
            if AgentHarness.needsArguments(name: process.name) {
                if let cached = scripts[process.id] { script = cached }
                else { script = probe.script(process.id.pid); scripts[process.id] = .some(script) }
            }
            guard var match = AgentHarness.classify(name: process.name, path: process.path, script: script) else { continue }
            classified[process.id.pid] = match
            if match.0.id == "claude", match.1 == .session, !confirmedSession(process.id) { unrecorded.append(process.id.pid) }
        }
        // Claude Code runs its bundled tools (search, shells) through its own binary, under the
        // session that started them. A `claude` with no session record and no Claude ancestor is
        // still its own session (a headless run), just without a log to read.
        for pid in unrecorded {
            var current = pid
            for _ in 0..<32 {
                guard let parent = table[current]?.parentPID, parent > 1, table[parent] != nil else { break }
                current = parent
                if classified[parent]?.0.id == "claude" { classified[pid]?.1 = .helper; break }
            }
        }
        confirmed = confirmed.filter { live.contains($0) }
        scripts = scripts.filter { live.contains($0.key) }

        // Fold every process under the topmost ancestor of the same harness.
        var groups: [Int32: [ProcessSample]] = [:]
        var helperOnly: [String: [ProcessSample]] = [:]
        for (pid, match) in classified {
            guard let process = table[pid] else { continue }
            // Tools are often started through a shell, so look past unrelated ancestors for the
            // topmost session of the same harness.
            var root = pid, current = pid
            // A process with its own session record is its own agent even when another agent
            // started it (an agent running `claude -p`, or a session opened from an agent's shell).
            let standalone = match.0.id == "claude" && match.1 == .session && confirmed.contains(process.id)
            for _ in 0..<(standalone ? 0 : 32) {
                guard let parent = table[current]?.parentPID, parent > 1, table[parent] != nil else { break }
                current = parent
                if let above = classified[parent], above.0.id == match.0.id, above.1 == .session || match.1 == .helper && root == pid { root = parent }
            }
            groups[root, default: []].append(process)
        }
        for (root, group) in groups where !group.contains(where: { classified[$0.id.pid]?.1 == .session }) {
            // Stray helpers (updaters, crash handlers) become one line per harness instead of one each.
            helperOnly[classified[root]!.0.id, default: []].append(contentsOf: group)
            groups[root] = nil
        }
        for (_, group) in helperOnly {
            guard let first = group.min(by: { $0.id.pid < $1.id.pid }) else { continue }
            groups[first.id.pid] = group
        }

        members = [:]
        var result: [AgentSession] = []
        var wanted: Set<String> = []
        var adopted = 0
        for (rootPID, group) in groups {
            guard let root = table[rootPID], let harness = classified[rootPID]?.0 else { continue }
            for process in group { members[process.id] = (root.id, harness.label) }
            let sessionPIDs = group.filter { classified[$0.id.pid]?.1 == .session }.map(\.id.pid)
            var known = facts[root.id] ?? Facts()
            if uptime - known.refreshed >= 10 {
                known = refresh(root: root, harness: harness, sessionPIDs: sessionPIDs, previous: known)
                known.refreshed = uptime
                facts[root.id] = known
            }
            // Read only the newest few logs per agent; an app server can hold many stale ones open.
            let logs = Array(known.logs.prefix(3))
            if let parse = harness.parse {
                for path in logs {
                    wanted.insert(path)
                    parsers[path] = parse
                    if tails[path] == nil { guard adopted < newTailsPerUpdate else { continue }; adopted += 1 }
                    var tail = tails[path] ?? SessionTail(path: path, parse: parse)
                    tail.read(now: now)
                    tails[path] = tail
                }
            }
            let primary = logs.first.flatMap { tails[$0] }
            let cpuValues = group.compactMap(\.cpu)
            let cpu = cpuValues.isEmpty ? nil : cpuValues.reduce(0, +)
            let activity = logs.compactMap { tails[$0]?.lastActivity }.max()
            let recent = primary?.events ?? []
            result.append(AgentSession(
                id: root.id, harnessID: harness.id, harness: harness.label, processCount: group.count,
                workingDirectory: known.workingDirectory ?? primary?.workingDirectory,
                launcher: known.launcher, title: sessionPIDs.isEmpty ? "background helpers" : known.title,
                status: Self.status(reported: known.reported, cpu: cpu, lastActivity: activity, last: recent.last, hasLog: primary != nil, now: now),
                cpu: cpu, memory: group.reduce(0) { $0 + $1.memory }, logs: logs, hasStream: harness.hasStream && !logs.isEmpty,
                logInferred: known.inferred,
                lastActivity: activity, tokensPerMinute: logs.reduce(0) { $0 + (tails[$1]?.tokensPerMinute(now: now) ?? 0) },
                totalTokens: logs.reduce(0) { $0 + (tails[$1]?.totalTokens ?? 0) }, recent: Array(recent.suffix(SessionTail.backgroundCapacity))))
        }
        tails = tails.filter { wanted.contains($0.key) }
        parsers = parsers.filter { wanted.contains($0.key) }
        facts = facts.filter { key, _ in result.contains { $0.id == key } }
        inferredClaims = inferredClaims.filter { _, owner in result.contains { $0.id == owner } }
        if rolloutDirectories.count > 2000 { rolloutDirectories = [:] }
        if let opened, tails[opened] == nil { self.opened = nil }
        let order: [AgentStatus: Int] = [.working: 0, .waiting: 1, .idle: 2, .unknown: 3]
        sessions = result.sorted {
            if order[$0.status] != order[$1.status] { return order[$0.status]! < order[$1.status]! }
            if ($0.cpu ?? -1) != ($1.cpu ?? -1) { return ($0.cpu ?? -1) > ($1.cpu ?? -1) }
            return $0.id.pid < $1.id.pid
        }
        return sessions
    }

    private func refresh(root: ProcessSample, harness: AgentHarness, sessionPIDs: [Int32], previous: Facts) -> Facts {
        var next = Facts()
        next.launcher = previous.launcher ?? Self.launcher(of: root.id.pid, probe: probe)
        next.workingDirectory = probe.workingDirectory(root.id.pid)
        var logs: [String] = []
        switch harness.id {
        case "claude":
            for pid in sessionPIDs {
                let file = home.appendingPathComponent(".claude/sessions/\(pid).json")
                guard let data = AgentLogFile.read(file.path, maximum: 65_535),
                      let record = AgentLogJSON.object(data), let session = record["sessionId"] as? String,
                      session.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { continue }
                let directory = record["cwd"] as? String
                if pid == root.id.pid {
                    next.workingDirectory = directory ?? next.workingDirectory
                    next.title = record["name"] as? String
                    switch record["status"] as? String {
                    case "busy": next.reported = .working
                    case "idle": next.reported = .idle
                    case "waiting": next.reported = .waiting
                    default: break
                    }
                }
                if let path = claudeTranscript(session: session, directory: directory) { logs.append(path) }
            }
        case "codex":
            for pid in sessionPIDs {
                logs += probe.openLogs(pid).filter { $0.contains("/sessions/") && URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("rollout-") }
            }
            if logs.isEmpty, !sessionPIDs.isEmpty, let directory = next.workingDirectory,
               let match = codexRollout(directory: directory, startedAfter: Date(timeIntervalSince1970: Double(root.id.started) / 1_000_000), owner: root.id) {
                logs = [match]; next.inferred = true
            }
        default: break
        }
        func modified(_ path: String) -> Date {
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        }
        var seen: Set<String> = []
        next.logs = logs.filter { seen.insert($0).inserted }.sorted { modified($0) > modified($1) }
        return next
    }

    /// The Codex CLI appends to its rollout and closes it, so nothing shows in its open files.
    /// Match instead on what the log records: the newest rollout for this working directory that
    /// was written after the process started and is not already attributed to another process.
    private func codexRollout(directory: String, startedAfter start: Date, owner: ProcessIdentity) -> String? {
        let sessions = home.appendingPathComponent(".codex/sessions")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        var candidates: [(path: String, modified: Date)] = []
        let wanted = Self.resolved(directory)
        // Rollouts are filed by local start date; a session can only be in a folder from the day
        // its process started onward. Bounded to two weeks of folders.
        var day = calendar.startOfDay(for: start)
        let today = Date()
        for _ in 0..<14 where day <= today {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let path = folder.appendingPathComponent(name).path
                guard let modified = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date,
                      modified >= start.addingTimeInterval(-2) else { continue }
                if let claimant = inferredClaims[path], claimant != owner { continue }
                // A log another process demonstrably holds open is that process's, whatever its directory.
                if facts.contains(where: { $0.key != owner && !$0.value.inferred && $0.value.logs.contains(path) }) { continue }
                if rolloutDirectory(path) == wanted { candidates.append((path, modified)) }
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }
        guard let best = candidates.max(by: { $0.modified < $1.modified })?.path else { return nil }
        inferredClaims[best] = owner
        return best
    }
    private static func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
    /// The working directory a rollout was started in, from its first line, with links resolved
    /// (the process reports a resolved path; the log may record the same place through a link).
    /// Cached, so each file is read and resolved once rather than on every refresh.
    private func rolloutDirectory(_ path: String) -> String? {
        if let cached = rolloutDirectories[path] { return cached }
        guard let file = AgentLogFile(path) else { return nil }
        let handle = file.handle
        // The first line carries the base instructions and can run to tens of kilobytes.
        guard let head = try? handle.read(upToCount: 512 * 1024), let end = head.firstIndex(of: 10),
              let root = AgentLogJSON.object(Data(head[head.startIndex..<end])), root["type"] as? String == "session_meta" else {
            rolloutDirectories[path] = .some(nil); return nil
        }
        let directory = ((root["payload"] as? [String: Any])?["cwd"] as? String).map(Self.resolved)
        rolloutDirectories[path] = .some(directory)
        return directory
    }

    /// Claude Code names a project folder after the working directory with every other character dashed.
    private func claudeTranscript(session: String, directory: String?) -> String? {
        let projects = home.appendingPathComponent(".claude/projects")
        if let directory {
            let slug = String(directory.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            let direct = projects.appendingPathComponent(slug).appendingPathComponent(session + ".jsonl").path
            if FileManager.default.fileExists(atPath: direct) { return direct }
        }
        // The session may have changed directory since it started; fall back to a search.
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let candidate = projects.appendingPathComponent(folder).appendingPathComponent(session + ".jsonl").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// First ancestor that says where the agent was started: an app, a multiplexer, or launchd.
    public static func launcher(of pid: Int32, probe: any AgentProbing) -> String? {
        let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "nu", "login", "sudo", "env", "node", "bun", "su"]
        var current = pid
        for _ in 0..<16 {
            guard let parent = probe.ancestor(of: current) else { return nil }
            let name = parent.name.hasPrefix("-") ? String(parent.name.dropFirst()) : parent.name
            if parent.pid == 1 { return "launchd" }
            if let app = parent.path.components(separatedBy: "/").first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
            if ["tmux", "screen", "zellij", "sshd", "mosh-server"].contains(where: { name.lowercased().hasPrefix($0) }) { return name }
            if !shells.contains(name.lowercased()) && !name.isEmpty { return name }
            current = parent.pid
        }
        return nil
    }

    static func status(reported: AgentStatus?, cpu: Double?, lastActivity: Date?, last: AgentEvent?, hasLog: Bool, now: Date) -> AgentStatus {
        let age = lastActivity.map { now.timeIntervalSince($0) }
        // The log is fresher evidence than a status file the harness updates at its own pace.
        if let age, age < 20 { return .working }
        if let reported { return reported }
        guard hasLog else { return cpu.map { $0 >= 5 ? .working : .idle } ?? .unknown }
        if (cpu ?? 0) >= 25 { return .working }
        // A tool call with no result yet is either long-running or blocked on approval.
        if last?.kind == .toolCall { return .waiting }
        return .idle
    }

    public static func totals(_ sessions: [AgentSession]) -> [AgentHarnessTotal] {
        var result: [String: AgentHarnessTotal] = [:]
        for session in sessions {
            var total = result[session.harness] ?? AgentHarnessTotal(harness: session.harness, sessions: 0, cpu: 0, memory: 0, tokensPerMinute: 0)
            total.sessions += 1; total.cpu += session.cpu ?? 0; total.memory += session.memory; total.tokensPerMinute += session.tokensPerMinute
            result[session.harness] = total
        }
        return result.values.sorted { $0.memory == $1.memory ? $0.harness < $1.harness : $0.memory > $1.memory }
    }
}
