import Foundation
import QuietCore
import QuietSilicon

/// View state for the chat panel. Turns are redacted when created; only the newest are kept in memory.
struct ChatState {
    static let memoryLimit = 40
    var open = false
    var loaded = false
    var input = ""
    var turns: [ChatTurn] = []
    /// Rows above the newest; zero follows the conversation.
    var scroll = 0
    var page = 1
    var rows: [[TerminalMarkdown.Glyph]] = []
    var rowsKey = ""
    var modelLabel = GlyphModel.apple.label
    var task: Task<Void, Never>?

    /// `QUIET_CHAT_DIR` moves the store, so the test harness never touches real history.
    static func store() -> ChatStore {
        guard let override = ProcessInfo.processInfo.environment["QUIET_CHAT_DIR"], !override.isEmpty else { return ChatStore() }
        return ChatStore(directory: URL(fileURLWithPath: override, isDirectory: true))
    }
}

extension TerminalDashboard {
    func openChat() {
        guard review == nil else { return }
        chat.open = true; chat.scroll = 0; searching = false; detailExpanded = false
        chat.modelLabel = GlyphModel.current().label
        if !chat.loaded { chat.turns = chatStore.recent(limit: ChatState.memoryLimit); chat.loaded = true }
    }

    private func remember(_ turn: ChatTurn, save: Bool) {
        chat.turns.append(turn)
        if chat.turns.count > ChatState.memoryLimit { chat.turns.removeFirst(chat.turns.count - ChatState.memoryLimit) }
        chat.scroll = 0
        if save { do { try chatStore.append(turn) } catch { notice = "Chat history was not saved: \(error.localizedDescription)" } }
    }

    /// Every key is text or navigation while chat is open: nothing typed here can trigger a dashboard action.
    func handleChatKey(_ key: String) async {
        switch key {
        case "escape":
            if let task = chat.task { task.cancel(); await intelligence.stop() } else { chat.open = false }
        case "enter": sendChat()
        case "backspace": if !chat.input.isEmpty { chat.input.removeLast() }
        case "up": chat.scroll += 1
        case "down": chat.scroll -= 1
        case "pageUp": chat.scroll += chat.page
        case "pageDown": chat.scroll -= chat.page
        case "home": chat.scroll = Int.max / 2
        case "end": chat.scroll = 0
        default: if key.count == 1, chat.input.count < GlyphChat.inputLimit { chat.input += key }
        }
    }
    func handleChatMouse(button: Int) {
        if button == 64 { chat.scroll += 3 } else if button == 65 { chat.scroll -= 3 }
    }

    private func chatContext() -> ChatContext {
        var context = ChatContext()
        let observatory = ObservatoryEvidence.context(sample, metrics, window: ambientWindow, hotspots: hotspots)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(observatory) { context.telemetry = String(decoding: data, as: UTF8.self) }
        context.agents = agents.sessions.prefix(14).map { session in
            let cpu = session.cpu.map { String(format: "%.0f%%", $0) } ?? "unknown"
            return "\(session.harness) pid \(session.id.pid) | \(session.status.rawValue) | CPU/core \(cpu) | RAM \(bytes(session.memory)) | \(AgentsCommand.count(session.tokensPerMinute)) tokens/min | last log entry \(AgentsCommand.age(session.lastActivity)) ago | \(AgentsCommand.home(session.workingDirectory)) | started from \(session.launcher ?? "unknown")"
        }.joined(separator: "\n")
        // The agent in focus: the one selected in the agent view, or the owner of the selected process.
        let focus = mode == .agents ? selectedAgent
            : selected.flatMap { agentRegistry.membership(of: $0)?.root }.flatMap { root in agents.sessions.first { $0.id == root } }
        if let focus {
            let events = focus.logs.first.flatMap { agentRegistry.tail($0)?.events } ?? focus.recent
            context.focusTitle = "\(focus.harness) pid \(focus.id.pid) in \(AgentsCommand.home(focus.workingDirectory))"
            context.focus = AgentNarration.digest(Array(events.suffix(120)), limit: GlyphModel.localPromptLimit)
        }
        return context
    }

    func sendChat() {
        let question = chat.input.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, chat.task == nil else { return }
        // The same holds that apply to explain apply here; say why instead of silently ignoring Enter.
        if paused { remember(ChatTurn(.note, "Chat is held while sampling is paused. Press Esc, then p to resume."), save: false); return }
        if !sample.thermal.admitsWork { remember(ChatTurn(.note, "Chat is held until thermal pressure improves."), save: false); return }
        if working { remember(ChatTurn(.note, "Wait for the current action to finish."), save: false); return }
        let model = GlyphModel.current()
        chat.modelLabel = model.label
        guard appleAvailable || model.backend == .mlx else {
            remember(ChatTurn(.note, TerminalMarkdown.literal(aiStatus) + ". Chat needs Apple Intelligence or a local model (`quiet models`)."), save: false); return
        }
        let history = chat.turns
        let turn = ChatTurn(.owner, question)
        remember(turn, save: true)
        chat.input = ""
        let context = chatContext()
        let previous = [ambientTask, agents.task]
        previous.forEach { $0?.cancel() }
        chat.task = Task {
            defer { chat.task = nil; dirty = true }
            do {
                for task in previous { await task?.value }
                try Task.checkCancellation()
                // The model is given the redacted turn, never the raw keystrokes.
                let (result, fallback) = try await intelligence.glyph(model, instructions: GlyphChat.instructions,
                                                                      maximumTokens: model.backend == .mlx ? 700 : 450) { limit in
                    GlyphChat.prompt(question: turn.text, history: history, context: context, limit: limit)
                }
                try Task.checkCancellation()
                if let fallback { remember(ChatTurn(.note, TerminalMarkdown.literal(fallback)), save: false) }
                remember(ChatTurn(.glyph, result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                                  model: result.backend == .mlx ? model.label : GlyphModel.apple.label), save: true)
            } catch is CancellationError {
                remember(ChatTurn(.note, "Cancelled."), save: false)
            } catch {
                remember(ChatTurn(.note, "**Chat unavailable:** " + TerminalMarkdown.literal(error.localizedDescription)), save: false)
            }
        }
    }

    func renderChat(_ canvas: inout TerminalCanvas, w: Int, height: Int) {
        let textInk = MengohPalette.foreground(0xBCC0C6), border = MengohPalette.foreground(0x4D535C)
        let dim = MengohPalette.foreground(0x999EA7)
        // Chat takes most of the screen; the summary panel stays only if a useful height is left for it.
        let remaining = height - top - 1 - max(10, height * 60 / 100)
        let summary = remaining >= 9 ? remaining : 0
        if summary > 0 {
            if mode == .agents {
                renderAgentSummary(&canvas, w: w, cpuHeight: summary, sessions: agents.sessions, totals: AgentRegistry.totals(agents.sessions))
            } else {
                renderSystemSummary(&canvas, w: w, cpuHeight: summary)
            }
        }
        let y = top + summary, h = height - 1 - y
        let pending = chat.task != nil
        let state = pending ? "thinking" : paused ? "paused" : !sample.thermal.admitsWork ? "waiting for thermal recovery" : "ready"
        canvas.box(TerminalRect(0, y, w, h), title: "**GLYPH CHAT** / \(TerminalMarkdown.literal(chat.modelLabel)) / \(state)",
                   style: border, titleStyle: textInk, markdownTitle: true)
        let inner = TerminalRect(2, y + 1, w - 4, h - 4)
        let key = "\(chat.turns.count)|\(chat.turns.last?.date.timeIntervalSince1970 ?? 0)|\(pending)|\(inner.width)"
        if key != chat.rowsKey {
            let before = chat.rows.count
            chat.rows = GlyphChat.rows(chat.turns, pending: pending, width: inner.width)
            if chat.scroll > 0 { chat.scroll += max(0, chat.rows.count - before) }
            chat.rowsKey = key
        }
        let total = chat.rows.count
        chat.page = max(1, inner.height - 1)
        chat.scroll = max(0, min(chat.scroll, max(0, total - inner.height)))
        if total == 0 {
            canvas.markdown("Ask about this Mac or the agents running on it. Glyph sees the current measurements, the agent table, and the recent session of the selected agent. It runs on this device, has no tools, and cannot act on anything.",
                            in: inner, style: dim)
        } else {
            let start = max(0, total - inner.height - chat.scroll)
            canvas.glyphs(chat.rows[start..<min(total, start + inner.height)], in: inner)
            if total > inner.height {
                let position = " \(start + 1)-\(min(total, start + inner.height))/\(total) "
                canvas.text(position, x: w - position.count - 2, y: y, width: position.count, style: dim)
            }
        }
        canvas.markdown("---", in: TerminalRect(2, y + h - 3, w - 4, 1), style: dim)
        // Show the end of a long question so the cursor is always visible.
        let room = max(1, w - 4 - 3)
        let shown = String(chat.input.suffix(room))
        canvas.text("> " + shown + "_", x: 2, y: y + h - 2, width: w - 4, style: MengohPalette.foreground(0xF0F1F3))
        let hint = " Enter send | Esc \(pending ? "cancel" : "close") | arrows, PgUp/PgDn scroll | \(chat.input.count)/\(GlyphChat.inputLimit) "
        if hint.count + 4 <= w { canvas.text(hint, x: 2, y: y + h - 1, width: hint.count, style: dim) }
    }
}
