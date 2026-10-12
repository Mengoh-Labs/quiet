import Foundation
import Testing
@testable import QuietCore

// Fixture credentials are assembled at runtime so no scanner mistakes this file for a leak.
private let fakeKeys: [String] = [
    "sk-ant-" + "api03-" + String(repeating: "Ab3", count: 12),
    "ghp_" + String(repeating: "a1B2", count: 9),
    "glpat-" + String(repeating: "x9Y", count: 7),
    "AKIA" + "IOSFODNN7EXAMPLE",
    "xoxb-" + "1234567890-abcdefghij",
    "eyJhbGciOiJIUzI1NiJ9" + "." + "eyJzdWIiOiIxMjM0NTY3ODkwIn0" + "." + "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV",
]

@Test func redactorMasksCredentialsAndKeepsOrdinaryText() {
    for key in fakeKeys {
        let masked = Redactor.redact("before \(key) after")
        #expect(!masked.contains(key), "leaked \(key.prefix(6))")
        #expect(masked.hasPrefix("before ") && masked.hasSuffix(" after"))
    }
    #expect(Redactor.redact("Authorization: Bearer abc.def-123456") == "Authorization: Bearer [redacted]")
    #expect(Redactor.redact("git clone https://marcus:hunter2secret@example.com/r.git") == "git clone https://[redacted]@example.com/r.git")
    #expect(Redactor.redact("export DB_PASSWORD=\"correct horse battery\" && run") == "export DB_PASSWORD=\"[redacted]\" && run")
    #expect(Redactor.redact("passphrase: 'two words' next") == "passphrase: '[redacted]' next")
    #expect(Redactor.redact("SECRET=plainvalue9 after") == "SECRET=[redacted] after")
    #expect(Redactor.redact("{\"api_key\": \"zzz-not-a-prefix-1\"}") == "{\"api_key\": \"[redacted]\"}")
    let rsaBegin = "-----BEGIN " + "RSA PRIVATE KEY-----", rsaEnd = "-----END " + "RSA PRIVATE KEY-----"
    let sshBegin = "-----BEGIN " + "OPENSSH PRIVATE KEY-----"
    #expect(Redactor.redact("x\n\(rsaBegin)\nMIIabc\ndef\n\(rsaEnd)\ny") == "x\n[redacted]\ny")
    #expect(Redactor.redact("\(sshBegin)\nb3BlbnNzaC1rZXk") == "[redacted]")
    let opaque = String(repeating: "aB3dE6gH9", count: 5)
    #expect(Redactor.redact("blob \(opaque) end") == "blob [redacted] end")
    // Prose, paths, counts, hashes and identifiers stay readable.
    for plain in ["max_tokens: 4096 and tokens=12", "Sources/QuietCore/Agents/AgentRegistry.swift",
                  "commit 63ca0e9f2b1c4d5e6f708192a3b4c5d6e7f80910", "52478dae-fb0d-404a-9f20-2bdde7067e91",
                  "2026-10-10-agents-chat-markdown-design-with-a-very-long-lowercase-name",
                  "the token budget is small", "swift test --package-path native -j 2"] {
        #expect(Redactor.redact(plain) == plain)
    }
}

@Test func agentEventRedactsAndBoundsAtCreation() {
    let event = AgentEvent(.toolResult, title: "result " + fakeKeys[1], text: "TOKEN=" + fakeKeys[0] + "\n" + String(repeating: "x ", count: 6000))
    #expect(!event.text.contains(fakeKeys[0]) && !event.title.contains(fakeKeys[1]))
    #expect(event.text.count <= AgentEvent.textLimit + 20 && event.text.hasSuffix("(truncated)"))
    // A secret straddling the kept boundary must not survive as a readable prefix.
    let straddling = String(repeating: "a", count: AgentEvent.textLimit - 10) + " " + fakeKeys[1] + " tail"
    #expect(!AgentEvent(.assistant, text: straddling).text.contains("ghp_"))
    #expect(AgentEvent(.user, text: "short").text == "short")
}

private func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

@Test func claudeLogLinesBecomeEvents() {
    let prompt = ClaudeCodeLog.parse(line(["type": "user", "timestamp": "2026-10-10T11:03:52.123Z", "cwd": "/work/app",
                                           "message": ["role": "user", "content": "add a view"]]))
    #expect(prompt.events.map(\.kind) == [.user] && prompt.events[0].text == "add a view" && prompt.workingDirectory == "/work/app")
    #expect(prompt.events[0].timestamp != nil)
    let injected = ClaudeCodeLog.parse(line(["type": "user", "message": ["role": "user", "content": "<system-reminder>x</system-reminder>"]]))
    #expect(injected.events.map(\.kind) == [.notice])
    let assistant = ClaudeCodeLog.parse(line(["type": "assistant", "timestamp": "2026-10-10T11:03:55Z", "message": [
        "id": "msg_1", "role": "assistant", "usage": ["input_tokens": 10, "cache_read_input_tokens": 90_000, "cache_creation_input_tokens": 5, "output_tokens": 7],
        "content": [["type": "thinking", "thinking": "", "signature": "s"], ["type": "thinking", "thinking": "plan it"],
                    ["type": "text", "text": "Reading."],
                    ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "swift test", "description": "run"]],
                    ["type": "tool_use", "id": "t2", "name": "Read", "input": ["file_path": "/work/app/a.swift"]]]]]))
    #expect(assistant.events.map(\.kind) == [.reasoning, .assistant, .toolCall, .toolCall, .usage])
    #expect(assistant.events[2].title == "Bash" && assistant.events[2].text == "swift test")
    #expect(assistant.events[3].text == "/work/app/a.swift")
    #expect(assistant.events[4].tokens == 22 && assistant.usageKey == "msg_1")
    let result = ClaudeCodeLog.parse(line(["type": "user", "isSidechain": true, "message": ["role": "user", "content": [
        ["type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": [["type": "text", "text": "exit 1"]]]]]]))
    #expect(result.events.map(\.kind) == [.toolResult] && result.events[0].failed && result.events[0].text == "exit 1")
    #expect(result.events[0].title == "subagent result")
    #expect(ClaudeCodeLog.parse(line(["type": "attachment", "message": ["content": "x"]])).events.isEmpty)
    #expect(ClaudeCodeLog.parse(Data("not json".utf8)).events.isEmpty)
}

@Test func codexLogLinesBecomeEvents() {
    func item(_ payload: [String: Any], type: String = "response_item") -> AgentLogLine {
        CodexLog.parse(line(["type": type, "timestamp": "2026-10-10T19:45:52.000Z", "payload": payload]))
    }
    #expect(item(["type": "message", "role": "user", "content": [["type": "input_text", "text": "fix it"]]]).events.map(\.kind) == [.user])
    #expect(item(["type": "message", "role": "developer", "content": [["type": "input_text", "text": "rules"]]]).events.isEmpty)
    #expect(item(["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>x"]]]).events.map(\.kind) == [.notice])
    #expect(item(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "done"]]]).events[0].text == "done")
    let reasoning = item(["type": "reasoning", "encrypted_content": "zzz", "summary": [["type": "summary_text", "text": "Checking tests"]]])
    #expect(reasoning.events.map(\.kind) == [.reasoning] && reasoning.events[0].text == "Checking tests")
    #expect(item(["type": "reasoning", "encrypted_content": "zzz", "summary": []]).events.isEmpty)
    let call = item(["type": "custom_tool_call", "name": "apply_patch", "input": "*** Begin Patch"])
    #expect(call.events[0].kind == .toolCall && call.events[0].title == "apply_patch" && call.events[0].text == "*** Begin Patch")
    #expect(item(["type": "local_shell_call", "action": ["command": ["ls", "-la"]]]).events[0].text == "ls -la")
    #expect(item(["type": "custom_tool_call_output", "output": "ok"]).events.map(\.kind) == [.toolResult])
    let usage = item(["type": "token_count", "info": ["last_token_usage": ["input_tokens": 1000, "cached_input_tokens": 900, "output_tokens": 50]]], type: "event_msg")
    #expect(usage.events.map(\.tokens) == [150])
    #expect(item(["type": "token_count", "info": NSNull()], type: "event_msg").events.isEmpty)
    #expect(CodexLog.parse(line(["type": "turn_context", "payload": ["cwd": "/work/q"]])).workingDirectory == "/work/q")
}

@Test func harnessClassificationSeparatesSessionsHelpersAndApps() {
    func role(_ name: String, _ path: String = "", _ script: String? = nil) -> String? {
        AgentHarness.classify(name: name, path: path, script: script).map { "\($0.0.id)/\($0.1)" }
    }
    #expect(role("claude", "/Users/a/.local/share/claude/versions/2.1/claude") == "claude/session")
    #expect(role("Claude", "/Applications/Claude.app/Contents/MacOS/Claude") == "claude-app/session")
    #expect(role("Claude Helper", "/Applications/Claude.app/Contents/Frameworks/x") == "claude-app/helper")
    #expect(role("codex", "/Users/a/.codex/packages/x/bin/codex") == "codex/session")
    #expect(role("codex-code-mode-host", "/Users/a/.codex/packages/x/bin/codex-code-mode-host") == "codex/helper")
    #expect(role("Codex (Renderer)", "/Applications/Codex.app/Contents/Frameworks/x") == "codex/helper")
    #expect(role("ollama", "/usr/local/bin/ollama") == "ollama/session")
    #expect(role("node", "/opt/homebrew/bin/node", "gemini") == "gemini/session")
    #expect(role("python3.12", "/usr/bin/python3", "mlx_lm.server") == "mlx/session")
    #expect(role("node", "/opt/homebrew/bin/node", "vite") == nil)
    #expect(role("zsh", "/bin/zsh") == nil)
    #expect(AgentHarness.needsArguments(name: "node") && !AgentHarness.needsArguments(name: "claude"))
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-agents-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func append(_ text: String, to url: URL) {
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let handle = try! FileHandle(forWritingTo: url); defer { try! handle.close() }
    try! handle.seekToEnd(); try! handle.write(contentsOf: Data(text.utf8))
}
private func userLine(_ text: String, at time: String = "2026-10-10T11:00:00Z") -> String {
    String(decoding: line(["type": "user", "timestamp": time, "message": ["role": "user", "content": text]]), as: UTF8.self) + "\n"
}
private func usageLine(id: String, tokens: Int, at time: String) -> String {
    String(decoding: line(["type": "assistant", "timestamp": time, "message": ["id": id, "role": "assistant",
        "usage": ["output_tokens": tokens], "content": [["type": "text", "text": "t"]]]]), as: UTF8.self) + "\n"
}

@Test func sessionTailReadsOnlyAppendedCompleteLines() throws {
    let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("s.jsonl")
    append(userLine("one") + userLine("two"), to: file)
    var tail = SessionTail(path: file.path, capacity: 3, parse: ClaudeCodeLog.parse)
    tail.read()
    #expect(tail.events.map(\.text) == ["one", "two"])
    let revision = tail.revision
    tail.read()
    #expect(tail.revision == revision, "an unchanged file must not invalidate cached layout")
    // A line still being written is held back until its newline arrives.
    let third = userLine("three")
    append(String(third.prefix(20)), to: file)
    tail.read()
    #expect(tail.events.map(\.text) == ["one", "two"])
    append(String(third.dropFirst(20)) + userLine("four"), to: file)
    tail.read()
    #expect(tail.events.map(\.text) == ["two", "three", "four"], "ring keeps the newest `capacity` events")
    #expect(tail.lastRequest?.text == "four")
    #expect(tail.revision > revision)
    // Truncation or replacement restarts the tail instead of reading from a stale offset.
    try Data(userLine("fresh").utf8).write(to: file)
    tail.read()
    #expect(tail.events.map(\.text) == ["fresh"])
}

@Test func sessionTailStartsNearTheEndAndBoundsOversizedLines() {
    let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("big.jsonl")
    append((0..<400).map { userLine("entry \($0) " + String(repeating: "p", count: 80)) }.joined(), to: file)
    var tail = SessionTail(path: file.path, capacity: 500, parse: ClaudeCodeLog.parse)
    tail.read(window: 4096)
    #expect(tail.events.count > 5 && tail.events.count < 40, "only the last window is parsed")
    #expect(tail.events.last?.text.hasPrefix("entry 399 ") == true)
    #expect(tail.events.allSatisfy { $0.text.hasPrefix("entry ") }, "the partial first line is dropped, not misparsed")
    // A single line beyond the limit is discarded and following lines still parse.
    append(String(repeating: "z", count: SessionTail.lineLimit + 10), to: file)
    tail.read(window: UInt64(SessionTail.lineLimit) * 2)
    append("\n" + userLine("after"), to: file)
    tail.read(window: UInt64(SessionTail.lineLimit) * 2)
    #expect(tail.events.last?.text == "after")
}

@Test func sessionTailCountsUsageOncePerMessageAndRatesTheLastMinute() {
    let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("u.jsonl")
    let now = ISO8601DateFormatter().date(from: "2026-10-10T11:10:00Z")!
    append(usageLine(id: "m1", tokens: 100, at: "2026-10-10T11:05:00Z")      // older than a minute
         + usageLine(id: "m2", tokens: 40, at: "2026-10-10T11:09:30Z")
         + usageLine(id: "m2", tokens: 40, at: "2026-10-10T11:09:31Z")       // same message, second content block
         + usageLine(id: "m3", tokens: 2, at: "2026-10-10T11:09:50Z"), to: file)
    var tail = SessionTail(path: file.path, parse: ClaudeCodeLog.parse)
    tail.read(now: now)
    #expect(tail.totalTokens == 142)
    #expect(tail.tokensPerMinute(now: now) == 42)
    #expect(tail.events.allSatisfy { $0.kind != .usage }, "usage is accounted, not shown as a stream entry")
    #expect(tail.lastActivity == ISO8601DateFormatter().date(from: "2026-10-10T11:09:50Z"))
}

private struct FakeProbe: AgentProbing {
    var directories: [Int32: String] = [:]
    var logs: [Int32: [String]] = [:]
    var scripts: [Int32: String] = [:]
    var parents: [Int32: AgentAncestor] = [:]
    func workingDirectory(_ pid: Int32) -> String? { directories[pid] }
    func openLogs(_ pid: Int32) -> [String] { logs[pid] ?? [] }
    func script(_ pid: Int32) -> String? { scripts[pid] }
    func ancestor(of pid: Int32) -> AgentAncestor? { parents[pid] }
}
private func process(_ pid: Int32, _ name: String, parent: Int32 = 1, path: String = "", cpu: Double? = 1, memory: UInt64 = 100) -> ProcessSample {
    ProcessSample(id: .init(pid: pid, started: UInt64(pid) * 10), name: name, path: path, uid: 501, cpuNanoseconds: 0, memory: memory, cpu: cpu, parentPID: parent)
}

@Test func registryGroupsProcessesAndLinksSessions() throws {
    let home = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: home) }
    let now = ISO8601DateFormatter().date(from: "2026-10-10T11:10:00Z")!
    // Claude Code: pid file -> session id -> transcript under the dashed project folder.
    let sessions = home.appendingPathComponent(".claude/sessions"), project = home.appendingPathComponent(".claude/projects/-work-my-app")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try line(["pid": 200, "sessionId": "abc-123", "cwd": "/work/my.app", "status": "idle", "name": "my-app-1"]).write(to: sessions.appendingPathComponent("200.json"))
    try line(["pid": 220, "sessionId": "nested-1", "cwd": "/work/nested", "status": "idle"]).write(to: sessions.appendingPathComponent("220.json"))
    append(userLine("build the thing", at: "2026-10-10T11:09:55Z") + usageLine(id: "m1", tokens: 30, at: "2026-10-10T11:09:56Z"), to: project.appendingPathComponent("abc-123.jsonl"))
    // Codex: an app server whose child holds two rollout logs open.
    let rollouts = home.appendingPathComponent(".codex/sessions/2026/10/10")
    try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
    let old = rollouts.appendingPathComponent("rollout-old.jsonl"), new = rollouts.appendingPathComponent("rollout-new.jsonl")
    let codexUser = String(decoding: line(["type": "response_item", "timestamp": "2026-10-10T10:00:00Z",
        "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "review"]]]]), as: UTF8.self) + "\n"
    append(codexUser, to: old); append(codexUser, to: new)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: old.path)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: new.path)
    var probe = FakeProbe()
    probe.directories = [200: "/elsewhere", 300: "/"]
    probe.logs = [301: [old.path, new.path, home.appendingPathComponent("unrelated.jsonl").path]]
    probe.scripts = [400: "gemini", 401: "vite"]
    probe.parents = [200: .init(pid: 190, name: "-zsh", path: "/bin/zsh"), 190: .init(pid: 180, name: "login", path: "/usr/bin/login"),
                     180: .init(pid: 170, name: "stable", path: "/Applications/Warp.app/Contents/MacOS/stable"),
                     300: .init(pid: 1, name: "launchd", path: "/sbin/launchd"), 400: .init(pid: 390, name: "tmux", path: "/opt/homebrew/bin/tmux")]
    let registry = AgentRegistry(home: home, probe: probe, ownPID: 999, newTailsPerUpdate: 99)
    let table = [
        process(200, "claude", parent: 190, cpu: 40, memory: 1000), process(201, "node", parent: 200, cpu: 5, memory: 50),
        process(300, "codex", parent: 1, cpu: 2, memory: 300), process(301, "codex", parent: 300, cpu: 3, memory: 400),
        process(302, "codex-code-mode-host", parent: 301, path: "/Users/a/.codex/bin/codex-code-mode-host", cpu: nil, memory: 100),
        process(350, "Codex (Service)", parent: 1, path: "/Applications/Codex.app/x", cpu: 0, memory: 20),
        process(351, "Codex (Renderer)", parent: 1, path: "/Applications/Codex.app/y", cpu: 0, memory: 30),
        process(400, "node", parent: 390, cpu: 0, memory: 70), process(401, "node", parent: 390, cpu: 90, memory: 900),
        process(999, "claude", parent: 1), process(500, "zsh", parent: 1),
        // Claude Code runs bundled tools through its own binary, usually behind a shell.
        process(210, "zsh", parent: 200, memory: 5), process(211, "claude", parent: 210, cpu: 2, memory: 7),
        // A recorded session started from another agent's shell stays its own agent.
        process(220, "claude", parent: 210, cpu: 1, memory: 13),
        // A headless run writes no session record; it is still a Claude session, without a log.
        process(600, "claude", parent: 500, cpu: 9, memory: 11)]
    let found = registry.update(processes: table, now: now, uptime: 100)
    #expect(found.count == 6, "claude, nested claude, headless claude, codex server, stray codex helpers, gemini; not vite, not Quiet itself")
    let nested = try #require(found.first { $0.id.pid == 220 })
    #expect(nested.processCount == 1 && nested.workingDirectory == "/work/nested" && nested.status == .idle)
    let headless = try #require(found.first { $0.id.pid == 600 })
    #expect(headless.harnessID == "claude" && headless.processCount == 1 && !headless.hasStream && headless.status == .working)
    let claude = try #require(found.first { $0.id.pid == 200 })
    #expect(claude.id.pid == 200 && claude.processCount == 2 && claude.memory == 1007, "its own tool process folds in; unrelated children do not")
    #expect(claude.workingDirectory == "/work/my.app" && claude.launcher == "Warp" && claude.title == "my-app-1")
    #expect(claude.logs == [project.appendingPathComponent("abc-123.jsonl").path] && claude.hasStream)
    #expect(claude.status == .working, "a log entry five seconds old outranks the status file")
    #expect(claude.tokensPerMinute == 30 && claude.recent.map(\.text) == ["build the thing", "t"])
    let codex = try #require(found.first { $0.id.pid == 300 })
    #expect(codex.processCount == 3 && codex.memory == 800 && codex.cpu == 5)
    #expect(codex.logs == [new.path, old.path], "newest log first; unrelated files ignored")
    #expect(codex.launcher == "launchd" && codex.status == .idle)
    let helpers = try #require(found.first { $0.title == "background helpers" })
    #expect(helpers.harnessID == "codex" && helpers.processCount == 2 && !helpers.hasStream)
    let gemini = try #require(found.first { $0.harnessID == "gemini" })
    #expect(gemini.launcher == "tmux" && !gemini.hasStream && gemini.status == .idle)
    #expect(registry.membership(of: table[4].id)?.root.pid == 300)
    #expect(registry.membership(of: table[8].id) == nil)
    // Opening a log deepens only that tail.
    append((0..<40).map { _ in codexUser }.joined(), to: new)
    registry.update(processes: table, now: now, uptime: 101)
    #expect(registry.tail(new.path)?.events.count == SessionTail.backgroundCapacity)
    registry.open(new.path, now: now)
    #expect(registry.tail(new.path)?.capacity == SessionTail.streamCapacity)
    #expect(registry.tail(new.path)?.events.count == 41, "opening re-reads the history the small ring had dropped")
    registry.update(processes: table, now: now, uptime: 102)
    #expect(registry.tail(new.path)?.events.count == 41, "the next sample keeps the deep ring")
    registry.open(nil)
    #expect(registry.tail(new.path)?.capacity == SessionTail.backgroundCapacity)
    // A process that exits disappears along with its tail.
    let later = registry.update(processes: table.filter { ![200, 201, 210, 211, 220, 600].contains($0.id.pid) }, now: now, uptime: 120)
    #expect(!later.contains { $0.harnessID == "claude" } && registry.tail(claude.logs[0]) == nil)
    // Logs are adopted a few per sample so the first frame is not held up parsing all of them.
    let staggered = AgentRegistry(home: home, probe: probe, ownPID: 999, newTailsPerUpdate: 1)
    let first = staggered.update(processes: table, now: now, uptime: 100)
    #expect(first.filter { $0.lastActivity != nil }.count == 1)
    _ = staggered.update(processes: table, now: now, uptime: 101)
    let third = staggered.update(processes: table, now: now, uptime: 102)
    #expect(third.filter { $0.lastActivity != nil }.count == 2)
    // Opening a log that has not been adopted yet must still give the stream its deep history.
    let eager = AgentRegistry(home: home, probe: probe, ownPID: 999, newTailsPerUpdate: 0)
    eager.update(processes: table, now: now, uptime: 100)
    #expect(eager.tail(new.path) == nil)
    eager.open(new.path, now: now)
    #expect(eager.tail(new.path)?.events.count == 41)
    eager.update(processes: table, now: now, uptime: 101)
    #expect(eager.tail(new.path)?.events.count == 41 && eager.tail(old.path) == nil)
    let totals = AgentRegistry.totals(found)
    #expect(totals.first { $0.harness == "codex" }?.sessions == 2)
}

@Test func agentStatusPrefersFreshLogEvidence() {
    let now = Date()
    func status(_ reported: AgentStatus?, cpu: Double?, age: Double?, last: AgentEvent.Kind?, hasLog: Bool = true) -> AgentStatus {
        AgentRegistry.status(reported: reported, cpu: cpu, lastActivity: age.map { now.addingTimeInterval(-$0) },
                             last: last.map { AgentEvent($0) }, hasLog: hasLog, now: now)
    }
    #expect(status(.idle, cpu: 0, age: 5, last: .assistant) == .working)
    #expect(status(.working, cpu: 0, age: 300, last: .assistant) == .working)
    #expect(status(nil, cpu: 0, age: 300, last: .toolCall) == .waiting)
    #expect(status(nil, cpu: 0, age: 300, last: .assistant) == .idle)
    #expect(status(nil, cpu: 60, age: 300, last: .assistant) == .working)
    #expect(status(nil, cpu: 8, age: nil, last: nil, hasLog: false) == .working)
    #expect(status(nil, cpu: nil, age: nil, last: nil, hasLog: false) == .unknown)
}

@Test func streamLayoutLabelsEntriesAndBoundsToolOutput() {
    let time = ISO8601DateFormatter().date(from: "2026-10-10T11:03:52Z")!
    let utc = TimeZone(identifier: "UTC")!
    let events = [
        AgentEvent(.user, at: time, title: "you", text: "Add **bold** widget"),
        AgentEvent(.toolCall, at: time, title: "Bash_[x]", text: "ls -la\n~~~~~~~~\necho **raw**"),
        AgentEvent(.toolResult, at: time, title: "result", text: (1...20).map { "line \($0)" }.joined(separator: "\n"), failed: true),
        AgentEvent(.reasoning, title: "thinking", text: "consider\noptions"),
        AgentEvent(.usage, tokens: 5),
        AgentEvent(.notice, title: "turn", text: "\nTurn complete after 3 s\nextra")]
    let rows = AgentStreamLayout.rows(events, width: 30, zone: utc)
    let text = rows.map { String($0.map(\.character)) }
    #expect(rows.allSatisfy { $0.count <= 30 })
    #expect(text[0] == "YOU  11:03:52" && text[1] == "Add bold widget")
    #expect(text.contains("TOOL  Bash_[x]  11:03:52"), "a tool name is literal text, not Markdown")
    // Tool text is verbatim: Markdown inside it is not interpreted and cannot close its own block.
    #expect(text.contains { $0.contains("echo **raw**") } && text.contains { $0.contains("~~~~") && !$0.contains("~~~~~~~~") })
    #expect(text.contains("RESULT failed  11:03:52"))
    #expect(text.contains { $0.contains("line 8") } && !text.contains { $0.contains("line 9") } && text.contains { $0.contains("... 12 more lines") })
    #expect(text.contains("THINKING  --:--:--") && text.contains("│ consider") && text.contains("│ options"))
    #expect(text.contains("Turn complete after 3 s") && !text.contains("extra"))
    #expect(text.filter(\.isEmpty).count == 4, "one blank row between five entries: the usage record is not one")
    #expect(AgentStreamLayout.rows(events, width: 0).isEmpty)
}

@Test func narrationDigestKeepsNewestWithinBudget() {
    let events = (0..<50).map { AgentEvent($0 % 2 == 0 ? .user : .toolCall, title: "Bash", text: "entry \($0)\nsecond line " + String(repeating: "w", count: 300)) }
    let digest = AgentNarration.digest(events, limit: 900)
    #expect(digest.utf8.count <= 900)
    #expect(digest.contains("entry 49") && !digest.contains("entry 0 "))
    let lines = digest.components(separatedBy: "\n")
    #expect(lines.last?.hasPrefix("[tool Bash] entry 49 second line") == true, "oldest first, newest last, one line per entry")
    #expect(AgentNarration.digest([AgentEvent(.usage, tokens: 3)], limit: 100).isEmpty)
    let session = AgentSession(id: .init(pid: 7, started: 1), harnessID: "claude", harness: "claude", processCount: 1,
        workingDirectory: "/work/app", launcher: "Warp", title: nil, status: .waiting, cpu: 3, memory: 1, logs: [], hasStream: true, logInferred: false,
        lastActivity: Date(timeIntervalSince1970: 100), tokensPerMinute: 0, totalTokens: 0, recent: [])
    let secret = "ghp_" + String(repeating: "a1B2", count: 9)
    let prompt = AgentNarration.prompt(session, events: events + [AgentEvent(.toolResult, text: "token " + secret)],
                                       now: Date(timeIntervalSince1970: 160), columns: 100, limit: 5200)
    #expect(prompt.utf8.count <= 5200)
    #expect(prompt.contains("/work/app") && prompt.contains("Warp") && prompt.contains("waiting") && prompt.contains("60 seconds ago"))
    #expect(prompt.contains("[redacted]") && !prompt.contains(secret))
    #expect(prompt.contains("Owner's most recent request: entry 48") && prompt.contains("- ran Bash: entry 49"))
    #expect(AgentNarration.prompt(session, events: []).contains("(no readable entries yet)"))
    // The request has usually scrolled out of the recent ring; the tail remembers it separately.
    let tools = [AgentEvent(.assistant, text: "Wiring the panel"), AgentEvent(.toolCall, title: "Edit", text: "/work/app/Panel.swift"),
                 AgentEvent(.toolResult, text: "boom", failed: true)]
    let remembered = AgentNarration.prompt(session, events: tools, request: AgentEvent(.user, text: "add the\norbital widget"))
    #expect(remembered.contains("Owner's most recent request: add the orbital widget"))
    #expect(remembered.contains("- Wiring the panel") && remembered.contains("- ran Edit: /work/app/Panel.swift") && remembered.contains("- that failed: boom"))
    #expect(AgentNarration.prompt(session, events: tools).contains("(not in the recent log)"))
}

@Test func narrationGateDwellsCoolsDownAndBacksOff() {
    var gate = AgentNarrationGate()
    let a = ProcessIdentity(pid: 1, started: 1), b = ProcessIdentity(pid: 2, started: 1)
    // #expect cannot call a mutating method on a captured value directly.
    func ask(_ session: ProcessIdentity, _ evidence: String, at now: Double, blocked: Bool = false) -> Bool {
        gate.shouldRequest(session, evidence: evidence, at: now, blocked: blocked)
    }
    #expect(!ask(a, "1", at: 0), "no request while the selection is still moving")
    #expect(!ask(a, "1", at: 3, blocked: true))
    #expect(ask(a, "1", at: 3))
    #expect(!ask(a, "2", at: 20), "new entries wait out the cooldown")
    #expect(ask(a, "2", at: 49))
    #expect(!ask(a, "2", at: 200), "nothing new, nothing asked")
    #expect(!ask(b, "1", at: 201))
    #expect(ask(b, "1", at: 204), "a different agent only needs the dwell")
    gate.failed(at: 204)
    #expect(!ask(a, "9", at: 260))
    #expect(!ask(a, "9", at: 263), "past the dwell, a failure still backs off, even for another agent")
    #expect(ask(a, "9", at: 510))
}

@Test func codexTerminalSessionsAreMatchedByDirectoryAndStartTime() throws {
    let home = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: home) }
    let now = Date()
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
    func folder(_ date: Date) throws -> URL {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let url = home.appendingPathComponent(String(format: ".codex/sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func rollout(_ name: String, in directory: URL, cwd: String, modified: Date, text: String) throws -> String {
        let url = directory.appendingPathComponent("rollout-\(name).jsonl")
        let meta = String(decoding: line(["type": "session_meta", "payload": ["cwd": cwd, "id": name, "base_instructions": String(repeating: "i", count: 30_000)]]), as: UTF8.self)
        let message = String(decoding: line(["type": "response_item", "timestamp": ISO8601DateFormatter().string(from: modified),
            "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]]), as: UTF8.self)
        try Data((meta + "\n" + message + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url.path
    }
    let started = now.addingTimeInterval(-3600), today = try folder(now)
    // Written before the process existed: a previous session in the same directory.
    _ = try rollout("stale", in: today, cwd: "/work/app", modified: started.addingTimeInterval(-7200), text: "old")
    _ = try rollout("elsewhere", in: today, cwd: "/work/other", modified: now.addingTimeInterval(-10), text: "other project")
    let older = try rollout("first", in: today, cwd: "/work/app", modified: now.addingTimeInterval(-1800), text: "first task")
    let newer = try rollout("second", in: today, cwd: "/work/app", modified: now.addingTimeInterval(-30), text: "second task")
    var probe = FakeProbe()
    // The only log for this directory predates the process: it belongs to an earlier session.
    _ = try rollout("solo-stale", in: today, cwd: "/work/solo", modified: started.addingTimeInterval(-600), text: "earlier run")
    probe.directories = [700: "/work/app", 701: "/work/app", 702: "/work/solo"]
    let micros = UInt64(started.timeIntervalSince1970 * 1_000_000)
    func codex(_ pid: Int32) -> ProcessSample {
        ProcessSample(id: .init(pid: pid, started: micros), name: "codex", path: "/opt/bin/codex", uid: 501, cpuNanoseconds: 0, memory: 10, cpu: 0, parentPID: 1)
    }
    let registry = AgentRegistry(home: home, probe: probe, ownPID: 999, newTailsPerUpdate: 99)
    let found = registry.update(processes: [codex(700), codex(701), codex(702)], now: now, uptime: 100)
    let logs = Dictionary(uniqueKeysWithValues: found.map { ($0.id.pid, $0) })
    // Two sessions in one directory take one log each, never the same one and never the stale one.
    #expect(Set([logs[700]?.logs.first, logs[701]?.logs.first]) == Set([older, newer]))
    #expect(logs[700]?.logInferred == true && logs[700]?.hasStream == true && logs[700]?.lastActivity != nil)
    #expect(logs[702]?.logs.isEmpty == true && logs[702]?.hasStream == false && logs[702]?.logInferred == false)
    // A log that another process holds open is never handed to a terminal session by inference.
    var holder = probe
    holder.directories[703] = "/"; holder.logs[703] = [newer]
    let shared = AgentRegistry(home: home, probe: holder, ownPID: 999, newTailsPerUpdate: 99)
    _ = shared.update(processes: [codex(703)], now: now, uptime: 100)
    let after = shared.update(processes: [codex(703), codex(700)], now: now, uptime: 101)
    #expect(after.first { $0.id.pid == 703 }?.logs == [newer] && after.first { $0.id.pid == 700 }?.logs == [older])
    // The match is stable across refreshes.
    let again = registry.update(processes: [codex(700), codex(701), codex(702)], now: now, uptime: 120)
    #expect(again.first { $0.id.pid == 700 }?.logs == logs[700]?.logs && again.first { $0.id.pid == 701 }?.logs == logs[701]?.logs)
}

@Test func sudoUsesTheInvokingUsersHomeAndNothingElseDoes() {
    let accounts: (uid_t) -> String? = { [501: "/Users/marcus", 0: "/var/root", 502: "relative", 503: "/"][$0] }
    func home(_ uid: uid_t, _ environment: [String: String]) -> String? {
        InvokingUser.home(effectiveUID: uid, environment: environment, lookup: accounts)?.path
    }
    #expect(home(0, ["SUDO_UID": "501", "HOME": "/var/root"]) == "/Users/marcus")
    // Not root: the variable is just an environment variable anyone can set.
    #expect(home(501, ["SUDO_UID": "0"]) == nil && home(502, ["SUDO_UID": "501"]) == nil)
    // Root without sudo, sudo from root, unknown users, and nonsense values keep the default.
    #expect(home(0, [:]) == nil && home(0, ["SUDO_UID": "0"]) == nil && home(0, ["SUDO_UID": "999"]) == nil)
    #expect(home(0, ["SUDO_UID": "marcus"]) == nil && home(0, ["SUDO_UID": "-1"]) == nil && home(0, ["SUDO_USER": "marcus"]) == nil)
    #expect(home(0, ["SUDO_UID": "502"]) == nil && home(0, ["SUDO_UID": "503"]) == nil, "an account with an unusable home is ignored")
}

@Test func redactorMasksNumericShortAndLongQuotedSecrets() {
    for (key, value) in [("password", "123456"), ("ACCESS_TOKEN", "987654321"), ("secret", "x"), ("api_key", "ab")] {
        #expect(Redactor.redact("\(key)=\(value) next") == "\(key)=[redacted] next")
        #expect(AgentEvent(.toolResult, text: "\(key)=\(value)").text == "\(key)=[redacted]")
    }
    #expect(Redactor.redact("Authorization: Bearer ab") == "Authorization: Bearer [redacted]")
    #expect(Redactor.redact("password=\"two\nlines\" end") == "password=\"[redacted]\" end")
    let long = String(repeating: "word ", count: 150)
    #expect(Redactor.redact("password=\"\(long)\" next") == "password=\"[redacted]\" next")
    #expect(AgentEvent(.toolResult, text: "password=\"" + String(repeating: "word ", count: 2000)).text == "password=\"[redacted]\"")
    #expect(Redactor.redact("input_tokens=123 output_tokens: 45 max_tokens=4096") == "input_tokens=123 output_tokens: 45 max_tokens=4096")
}
