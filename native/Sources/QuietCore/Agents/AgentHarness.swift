import Foundation

public enum AgentRole: Sendable, Equatable { case session, helper }

/// A known agent harness or AI app. `parse` is nil when only detection and resources are supported.
public struct AgentHarness: Sendable {
    public let id: String
    public let label: String
    public let parse: (@Sendable (Data) -> AgentLogLine)?
    public var hasStream: Bool { parse != nil }

    public static let claudeCode = AgentHarness(id: "claude", label: "claude", parse: ClaudeCodeLog.parse)
    public static let codex = AgentHarness(id: "codex", label: "codex", parse: CodexLog.parse)
    public static let detectionOnly: [String: AgentHarness] = Dictionary(uniqueKeysWithValues: [
        ("claude-app", "Claude app"), ("ollama", "ollama"), ("cursor", "cursor"), ("gemini", "gemini"),
        ("lmstudio", "LM Studio"), ("aider", "aider"), ("opencode", "opencode"), ("goose", "goose"),
        ("llama", "llama.cpp"), ("mlx", "mlx")
    ].map { ($0.0, AgentHarness(id: $0.0, label: $0.1, parse: nil)) })

    /// Script-hosted agents are only recognisable from their first argument.
    public static func needsArguments(name: String) -> Bool {
        ["node", "bun", "deno", "python", "python3", "uv"].contains(name.lowercased()) || name.lowercased().hasPrefix("python3.")
    }

    /// `script` is the last path component of the first argument for script-hosted processes.
    public static func classify(name: String, path: String, script: String? = nil) -> (AgentHarness, AgentRole)? {
        let lower = name.lowercased()
        func only(_ id: String) -> AgentHarness { detectionOnly[id]! }
        // The desktop app's main binary is also called "Claude"; the bundle path tells them apart.
        if path.contains("/Claude.app/") { return (only("claude-app"), lower == "claude" ? .session : .helper) }
        if lower == "claude" { return (claudeCode, .session) }
        if lower == "codex" { return (codex, .session) }
        if lower.hasPrefix("codex") || path.contains("/Codex.app/") || path.contains("/.codex/") || path.contains("/codex-cli/") {
            return (codex, .helper)
        }
        if lower == "ollama" || path.contains("/Ollama.app/") { return (only("ollama"), lower == "ollama" ? .session : .helper) }
        if lower == "cursor-agent" { return (only("cursor"), .session) }
        if path.contains("/Cursor.app/") { return (only("cursor"), lower == "cursor" ? .session : .helper) }
        if path.contains("/LM Studio.app/") { return (only("lmstudio"), lower == "lm studio" ? .session : .helper) }
        if lower == "opencode" { return (only("opencode"), .session) }
        if lower == "goose" || lower == "goosed" { return (only("goose"), .session) }
        if lower == "aider" { return (only("aider"), .session) }
        if lower == "gemini" { return (only("gemini"), .session) }
        if lower.hasPrefix("llama-server") || lower.hasPrefix("llama-cli") { return (only("llama"), .session) }
        if let script = script?.lowercased() {
            if script == "gemini" || script.contains("gemini-cli") { return (only("gemini"), .session) }
            if script == "aider" { return (only("aider"), .session) }
            if script == "opencode" { return (only("opencode"), .session) }
            if script == "claude" || script.contains("claude-code") { return (claudeCode, .session) }
            if script == "codex" { return (codex, .session) }
            if script.hasPrefix("mlx_lm") || script.hasPrefix("mlx-lm") { return (only("mlx"), .session) }
        }
        return nil
    }
}

enum AgentLogJSON {
    // Both harnesses write ISO 8601 with fractional seconds; tolerate its absence.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
    /// Tool inputs and outputs arrive as strings, arrays of text parts, or arbitrary JSON.
    static func text(_ value: Any?) -> String {
        switch value {
        case let string as String: return string
        case let parts as [Any]:
            return parts.compactMap { part -> String? in
                if let string = part as? String { return string }
                guard let item = part as? [String: Any] else { return nil }
                return item["text"] as? String ?? (item["type"] as? String).map { "[\($0)]" }
            }.joined(separator: "\n")
        case let dictionary as [String: Any]:
            if let text = dictionary["text"] as? String ?? dictionary["output"] as? String ?? dictionary["content"] as? String { return text }
            return compact(dictionary)
        case .none: return ""
        default: return "\(value!)"
        }
    }
    static func compact(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    /// Harness-injected wrappers are bookkeeping, not something the person typed.
    static func isInjected(_ text: String) -> Bool {
        let trimmed = text.drop(while: { $0 == " " || $0 == "\n" })
        return ["<system-reminder", "<local-command", "<command-name", "<command-message", "<environment_context",
                "<user_instructions", "<task-notification", "<turn_aborted", "<permissions"].contains { trimmed.hasPrefix($0) }
    }
}

public enum ClaudeCodeLog {
    public static let parse: @Sendable (Data) -> AgentLogLine = { line in
        var result = AgentLogLine()
        guard let root = AgentLogJSON.object(line), let type = root["type"] as? String, type == "user" || type == "assistant",
              let message = root["message"] as? [String: Any] else { return result }
        let time = AgentLogJSON.date(root["timestamp"])
        let side = root["isSidechain"] as? Bool == true ? "subagent " : ""
        result.workingDirectory = root["cwd"] as? String
        func user(_ text: String) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let injected = root["isMeta"] as? Bool == true || AgentLogJSON.isInjected(text)
            result.events.append(AgentEvent(injected ? .notice : .user, at: time, title: injected ? "harness" : side + "you", text: text))
        }
        if let text = message["content"] as? String {
            if type == "user" { user(text) } else { result.events.append(AgentEvent(.assistant, at: time, title: side + "agent", text: text)) }
        }
        for case let block as [String: Any] in message["content"] as? [Any] ?? [] {
            switch block["type"] as? String {
            case "text":
                let text = block["text"] as? String ?? ""
                if type == "user" { user(text) }
                else if !text.isEmpty { result.events.append(AgentEvent(.assistant, at: time, title: side + "agent", text: text)) }
            case "thinking":
                // Often stored empty; show it only when the harness kept the text.
                if let text = block["thinking"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.events.append(AgentEvent(.reasoning, at: time, title: side + "thinking", text: text))
                }
            case "tool_use", "server_tool_use":
                let input = block["input"] as? [String: Any] ?? [:]
                let summary = input["command"] as? String ?? input["file_path"] as? String ?? input["pattern"] as? String
                    ?? input["prompt"] as? String ?? input["query"] as? String ?? input["url"] as? String ?? AgentLogJSON.compact(input)
                result.events.append(AgentEvent(.toolCall, at: time, title: side + (block["name"] as? String ?? "tool"), text: summary))
            case "tool_result":
                result.events.append(AgentEvent(.toolResult, at: time, title: side + "result", text: AgentLogJSON.text(block["content"]),
                                                failed: block["is_error"] as? Bool == true))
            default: break
            }
        }
        if type == "assistant", let usage = message["usage"] as? [String: Any] {
            // Cache reads repeat the whole context every turn; counting them would swamp real work.
            let tokens = ["input_tokens", "cache_creation_input_tokens", "output_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            if tokens > 0 {
                result.events.append(AgentEvent(.usage, at: time, tokens: tokens))
                result.usageKey = message["id"] as? String ?? root["requestId"] as? String
            }
        }
        return result
    }
}

public enum CodexLog {
    public static let parse: @Sendable (Data) -> AgentLogLine = { line in
        var result = AgentLogLine()
        guard let root = AgentLogJSON.object(line), let type = root["type"] as? String else { return result }
        let time = AgentLogJSON.date(root["timestamp"])
        let payload = root["payload"] as? [String: Any] ?? [:]
        let kind = payload["type"] as? String
        switch (type, kind) {
        case ("turn_context", _), ("session_meta", _):
            result.workingDirectory = payload["cwd"] as? String
        case ("response_item", "message"):
            let role = payload["role"] as? String
            let text = AgentLogJSON.text(payload["content"])
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, role == "user" || role == "assistant" else { break }
            if role == "assistant" { result.events.append(AgentEvent(.assistant, at: time, title: "agent", text: text)) }
            else if AgentLogJSON.isInjected(text) { result.events.append(AgentEvent(.notice, at: time, title: "harness", text: text)) }
            else { result.events.append(AgentEvent(.user, at: time, title: "you", text: text)) }
        case ("response_item", "agent_message"):
            let text = AgentLogJSON.text(payload["content"])
            if !text.isEmpty { result.events.append(AgentEvent(.assistant, at: time, title: "agent " + (payload["author"] as? String ?? ""), text: text)) }
        case ("response_item", "reasoning"):
            // Only the summary is readable; the full reasoning is stored encrypted.
            let text = AgentLogJSON.text(payload["summary"])
            if !text.isEmpty { result.events.append(AgentEvent(.reasoning, at: time, title: "reasoning summary", text: text)) }
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"), ("response_item", "local_shell_call"):
            let action = payload["action"] as? [String: Any]
            let command = (action?["command"] as? [String])?.joined(separator: " ")
            let input = command ?? AgentLogJSON.text(payload["input"] ?? payload["arguments"])
            result.events.append(AgentEvent(.toolCall, at: time, title: payload["name"] as? String ?? "shell", text: input))
        case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"), ("response_item", "local_shell_call_output"):
            result.events.append(AgentEvent(.toolResult, at: time, title: "result", text: AgentLogJSON.text(payload["output"])))
        case ("event_msg", "token_count"):
            guard let usage = (payload["info"] as? [String: Any])?["last_token_usage"] as? [String: Any] else { break }
            let tokens = max(0, (usage["input_tokens"] as? Int ?? 0) - (usage["cached_input_tokens"] as? Int ?? 0)) + (usage["output_tokens"] as? Int ?? 0)
            if tokens > 0 { result.events.append(AgentEvent(.usage, at: time, tokens: tokens)) }
        case ("event_msg", "task_started"):
            result.events.append(AgentEvent(.notice, at: time, title: "turn", text: "Turn started"))
        case ("event_msg", "task_complete"):
            let seconds = (payload["duration_ms"] as? Double).map { String(format: " after %.0f s", $0 / 1000) } ?? ""
            result.events.append(AgentEvent(.notice, at: time, title: "turn", text: "Turn complete" + seconds))
        default: break
        }
        return result
    }
}
