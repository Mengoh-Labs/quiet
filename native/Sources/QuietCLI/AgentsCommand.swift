import Foundation
import QuietCore
import QuietSilicon

/// `quiet agents`: a one-shot table of running agent sessions, or JSON with `--json`.
enum AgentsCommand {
    /// `QUIET_AGENT_HOME` points session discovery at another home directory, for the test harness.
    /// `eager` reads every session log on the first pass: right for a one-shot command, too slow
    /// for the dashboard's first frame.
    static func registry(eager: Bool = false) -> AgentRegistry {
        let limit = eager ? Int.max : 2
        guard let override = ProcessInfo.processInfo.environment["QUIET_AGENT_HOME"], !override.isEmpty else { return AgentRegistry(newTailsPerUpdate: limit) }
        return AgentRegistry(home: URL(fileURLWithPath: override, isDirectory: true), newTailsPerUpdate: limit)
    }
    static func home(_ path: String?) -> String {
        guard let path else { return "--" }
        let home = InvokingUser.home.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    static func bytes(_ value: UInt64) -> String {
        if value >= 1_073_741_824 { return String(format: "%.1fG", Double(value) / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.0fM", Double(value) / 1_048_576) }
        return String(format: "%.0fK", Double(value) / 1024)
    }
    static func count(_ value: Double) -> String {
        value >= 1_000_000 ? String(format: "%.1fM", value / 1_000_000) : value >= 1000 ? String(format: "%.1fk", value / 1000) : String(format: "%.0f", value)
    }
    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "--" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        return seconds < 60 ? "\(seconds)s" : seconds < 3600 ? "\(seconds / 60)m" : seconds < 86_400 ? "\(seconds / 3600)h" : "\(seconds / 86_400)d"
    }

    /// `quiet agents explain <pid>`: one on-device read of what that agent is doing.
    static func explain(pid: Int32) async throws {
        let sampler = Sampler(), registry = registry(eager: true)
        _ = await sampler.sample()
        try await Task.sleep(for: .seconds(1))
        let sample = await sampler.sample()
        registry.update(processes: sample.processes, uptime: ProcessInfo.processInfo.systemUptime)
        guard let root = sample.processes.first(where: { $0.id.pid == pid }).flatMap({ registry.membership(of: $0.id)?.root }),
              let session = registry.sessions.first(where: { $0.id == root }) else {
            throw QuietError("PID \(pid) does not belong to a recognised agent. Run quiet agents to list them.")
        }
        guard session.hasStream, let path = session.logs.first else {
            throw QuietError("\(session.harness) \(session.id.pid) has no readable session log: detection and resource use only.")
        }
        registry.open(path)
        let events = registry.tail(path)?.events ?? []
        let request = registry.tail(path)?.lastRequest
        let recent = Array(events.suffix(60))
        let model = GlyphModel.current()
        let runtime = QuietSilicon.SiliconRuntime()
        do {
            let (result, fallback) = try await runtime.glyph(model, instructions: AgentNarration.instructions, maximumTokens: 200) { limit in
                AgentNarration.prompt(session, events: recent, request: request, limit: limit)
            }
            if let fallback { FileHandle.standardError.write(Data((fallback + "\n").utf8)) }
            let ansi = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["TERM"] != "dumb"
                && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
            var size = winsize()
            _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
            let title = "# \(TerminalMarkdown.literal(session.harness)) \(session.id.pid) in \(TerminalMarkdown.literal(home(session.workingDirectory))) - \(TerminalMarkdown.literal(result.model)), on-device, advisory\n"
            print(TerminalMarkdown.render(title + result.output, width: size.ws_col > 0 ? max(1, Int(size.ws_col) - 1) : 100, ansi: ansi))
            await runtime.stop()
        } catch { await runtime.stop(); throw error }
    }

    static func run(json: Bool) async throws {
        let sampler = Sampler(), registry = registry(eager: true)
        _ = await sampler.sample()
        try await Task.sleep(for: .seconds(1))
        let sample = await sampler.sample()
        let started = ProcessInfo.processInfo.systemUptime
        var sessions = registry.update(processes: sample.processes, uptime: started)
        if CommandLine.arguments.contains("--timing") {
            let first = ProcessInfo.processInfo.systemUptime
            sessions = registry.update(processes: sample.processes, uptime: first + 1)
            let second = ProcessInfo.processInfo.systemUptime
            sessions = registry.update(processes: sample.processes, uptime: first + 20)
            let third = ProcessInfo.processInfo.systemUptime
            FileHandle.standardError.write(Data(String(format: "registry: first %.1f ms, steady %.1f ms, refresh %.1f ms\n",
                (first - started) * 1000, (second - first) * 1000, (third - second) * 1000).utf8))
        }
        if json {
            let rows = sessions.map { session -> [String: Any] in
                var row: [String: Any] = ["harness": session.harness, "pid": Int(session.id.pid), "processes": session.processCount,
                    "status": session.status.rawValue, "memoryBytes": session.memory, "tokensPerMinute": session.tokensPerMinute,
                    "sessionLogs": session.logs.count, "stream": session.hasStream, "logMatchedByDirectory": session.logInferred]
                if let cpu = session.cpu { row["cpuPercentOfOneCore"] = cpu }
                if let directory = session.workingDirectory { row["workingDirectory"] = directory }
                if let launcher = session.launcher { row["launcher"] = launcher }
                if let title = session.title { row["title"] = title }
                if let activity = session.lastActivity { row["lastActivity"] = ISO8601DateFormatter().string(from: activity) }
                return row
            }
            let data = try JSONSerialization.data(withJSONObject: ["agents": rows], options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        guard !sessions.isEmpty else { print("No agent sessions found for this user."); return }
        var table = "| Harness | PID | Status | CPU/core | RAM | Tok/min | Last | Where | Via |\n| :-- | --: | :-- | --: | --: | --: | --: | :-- | :-- |\n"
        for session in sessions {
            let cpu = session.cpu.map { String(format: "%.1f%%", $0) } ?? "--"
            let name = session.harness + (session.processCount > 1 ? " x\(session.processCount)" : "")
            table += "| \(TerminalMarkdown.literal(name)) | \(session.id.pid) | \(session.status.rawValue) | \(cpu) | \(bytes(session.memory)) | \(count(session.tokensPerMinute)) | \(age(session.lastActivity)) | \(TerminalMarkdown.literal(home(session.workingDirectory))) | \(TerminalMarkdown.literal(session.launcher ?? "--")) |\n"
        }
        var size = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
        let ansi = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["TERM"] != "dumb"
            && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        print(TerminalMarkdown.render("# Agents: \(sessions.count) sessions\n" + table, width: size.ws_col > 0 ? max(1, Int(size.ws_col) - 1) : 140, ansi: ansi))
    }
}
