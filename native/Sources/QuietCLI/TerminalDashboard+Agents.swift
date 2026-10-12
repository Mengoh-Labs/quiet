import Foundation
import QuietCore
import QuietSilicon

enum DashboardMode { case system, agents }

/// View state for Agents mode. Collection and parsing live in `AgentRegistry`.
struct AgentsState {
    var sessions: [AgentSession] = []
    var selected: ProcessIdentity?
    /// Until the owner picks a row, the selection follows the most active agent.
    var pinned = false
    var offset = 0
    var rowsOnScreen: [ProcessIdentity] = []
    var rowStart = 0
    var rowsRect = TerminalRect(0, 0, 0, 0)
    var streamOpen = false
    var logIndex = 0
    /// Rows above the tail; zero follows new entries.
    var scroll = 0
    var streamRows: [[TerminalMarkdown.Glyph]] = []
    var streamKey = ""
    var streamPage = 1
    var cpuHistory: [Double?] = []
    var tokenHistory: [Double?] = []
    var memoryHistory: [Double?] = []
    var groupFirst = false
    var narration = ""
    var narrationStatus = "waiting"
    var narrationFor: ProcessIdentity?
    var narrationAt: Date?
    var gate = AgentNarrationGate()
    var task: Task<Void, Never>?
}

extension TerminalDashboard {
    var selectedAgent: AgentSession? { agents.sessions.first { $0.id == agents.selected } }
    var streamPath: String? {
        guard let session = selectedAgent, !session.logs.isEmpty else { return nil }
        return session.logs[min(agents.logIndex, session.logs.count - 1)]
    }

    func ingestAgents(at now: Double) {
        agents.sessions = agentRegistry.update(processes: sample.processes, uptime: now)
        let cpu = agents.sessions.compactMap(\.cpu)
        agents.cpuHistory = Array((agents.cpuHistory + [cpu.isEmpty ? nil : min(100, cpu.reduce(0, +) / Double(max(1, sample.cores)))]).suffix(480))
        agents.tokenHistory = Array((agents.tokenHistory + [agents.sessions.reduce(0) { $0 + $1.tokensPerMinute }]).suffix(480))
        let memory = agents.sessions.reduce(UInt64(0)) { $0 + $1.memory }
        agents.memoryHistory = Array((agents.memoryHistory + [sample.ram > 0 ? Double(memory) / Double(sample.ram) * 100 : nil]).suffix(480))
        if !agents.sessions.contains(where: { $0.id == agents.selected }) {
            if agents.streamOpen { closeStream(); notice = "That agent exited; its stream was closed." }
            agents.selected = agents.sessions.first?.id; agents.pinned = false
        } else if !agents.pinned && !agents.streamOpen {
            agents.selected = agents.sessions.first?.id
        }
    }

    func moveAgent(_ delta: Int) {
        guard !agents.sessions.isEmpty else { agents.selected = nil; return }
        agents.pinned = true
        let index = agents.sessions.firstIndex { $0.id == agents.selected } ?? 0
        agents.selected = agents.sessions[max(0, min(agents.sessions.count - 1, index + delta))].id
    }
    func openStream() {
        guard let session = selectedAgent else { return }
        guard session.hasStream else { notice = "\(session.harness) has no readable session log: detection and resource use only."; return }
        agents.streamOpen = true; agents.pinned = true; agents.logIndex = 0; agents.scroll = 0; agents.streamKey = ""
        agentRegistry.open(streamPath)
    }
    func closeStream() {
        agents.streamOpen = false; agents.streamRows = []; agents.streamKey = ""
        agentRegistry.open(nil)
    }

    /// Returns true when the key was consumed by Agents mode.
    func handleAgentKey(_ key: String) async -> Bool {
        switch key {
        case "up", "k": if agents.streamOpen { agents.scroll += 1 } else { moveAgent(-1) }
        case "down", "j": if agents.streamOpen { agents.scroll -= 1 } else { moveAgent(1) }
        case "pageUp": if agents.streamOpen { agents.scroll += agents.streamPage } else { moveAgent(-max(1, agents.rowsOnScreen.count)) }
        case "pageDown": if agents.streamOpen { agents.scroll -= agents.streamPage } else { moveAgent(max(1, agents.rowsOnScreen.count)) }
        case "home": if agents.streamOpen { agents.scroll = Int.max / 2 } else { moveAgent(-agents.sessions.count) }
        case "end", "f": if agents.streamOpen { agents.scroll = 0 } else { moveAgent(agents.sessions.count) }
        case "enter", "o": if agents.streamOpen { closeStream() } else { openStream() }
        case "n":
            // Outside the stream `n` still cycles the network interface shown beside the agents.
            guard agents.streamOpen, let session = selectedAgent, session.logs.count > 1 else { return false }
            agents.logIndex = (agents.logIndex + 1) % session.logs.count; agents.scroll = 0; agents.streamKey = ""
            agentRegistry.open(streamPath)
        case "escape":
            if agents.streamOpen { closeStream() }
            else { agents.task?.cancel(); ambientTask?.cancel(); await intelligence.stop(); notice = "Local inference cancelled." }
        case "i": if let session = selectedAgent { narrate(session, manual: true) }
        // Process-view actions have no meaning here; swallow them rather than act on a hidden panel.
        case "r", "s", "x", "/", "h", "m", "d", "t", "[", "]": break
        default: return false
        }
        return true
    }

    func handleAgentMouse(button: Int, x: Int, y: Int) async {
        if button == 64 { if agents.streamOpen { agents.scroll += 3 } else { moveAgent(-3) }; return }
        if button == 65 { if agents.streamOpen { agents.scroll -= 3 } else { moveAgent(3) }; return }
        guard button == 0 else { return }
        if let button = buttons.first(where: { $0.0.contains(x: x - 1, y: y - 1) }) {
            await handle(.key(button.1))
        } else if !agents.streamOpen, agents.rowsRect.contains(x: x - 1, y: y - 1),
                  y >= agents.rowStart, y < agents.rowStart + agents.rowsOnScreen.count {
            let id = agents.rowsOnScreen[y - agents.rowStart]
            // First click selects, a second click on the same row opens its stream.
            if agents.selected == id && agents.pinned { openStream() } else { agents.selected = id; agents.pinned = true }
        }
    }

    /// From the process view: jump to the agent that owns the selected process and open its stream.
    func openStreamForSelectedProcess() {
        guard let selected, let membership = agentRegistry.membership(of: selected) else {
            notice = "The selected process does not belong to a recognised agent."; return
        }
        mode = .agents; notice = ""; agents.selected = membership.root; agents.pinned = true
        openStream()
    }

    func updateNarration(at now: Double) {
        guard mode == .agents, let session = selectedAgent, session.hasStream else { return }
        let blocked = !ambientEnabled || !glyphReady || !terminalActive || paused || review != nil || working
            || ambientTask != nil || agents.task != nil || !sample.thermal.admitsWork || chat.open
        let evidence = String(session.lastActivity?.timeIntervalSince1970 ?? 0)
        guard agents.gate.shouldRequest(session.id, evidence: evidence, at: now, blocked: blocked) else { return }
        narrate(session, manual: false)
    }

    func narrate(_ session: AgentSession, manual: Bool) {
        guard !working else { return }
        let events = session.logs.first.flatMap { agentRegistry.tail($0)?.events } ?? session.recent
        guard session.hasStream, !events.isEmpty else {
            agents.narration = "No readable session entries for this agent yet."; agents.narrationFor = session.id; return
        }
        let recent = Array(events.suffix(60))
        let request = session.logs.first.flatMap { agentRegistry.tail($0)?.lastRequest }
        let columns = widths.0 - (warpEnabled && widths.0 >= 101 ? 10 : 0)
        let model = GlyphModel.current()
        let previous = [agents.task, ambientTask]
        previous.forEach { $0?.cancel() }
        if manual { agents.gate.recordManual(at: ProcessInfo.processInfo.systemUptime) }
        agents.narrationStatus = "reading session"
        agents.task = Task {
            defer { agents.task = nil; dirty = true }
            do {
                for task in previous { await task?.value }
                try Task.checkCancellation()
                let (result, fallback) = try await intelligence.glyph(model, instructions: AgentNarration.instructions, maximumTokens: 200) { limit in
                    AgentNarration.prompt(session, events: recent, request: request, columns: columns, limit: limit)
                }
                try Task.checkCancellation()
                agents.narration = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                agents.narrationFor = session.id; agents.narrationAt = Date()
                agents.narrationStatus = result.backend == .mlx ? "local model" : "local AI"
                if let fallback { notice = fallback }
            } catch is CancellationError {
                agents.narrationStatus = "waiting"
            } catch {
                agents.gate.failed(at: ProcessInfo.processInfo.systemUptime)
                agents.narrationStatus = "unavailable"
                agents.narration = "**Narration unavailable:** " + TerminalMarkdown.literal(error.localizedDescription)
                agents.narrationFor = session.id
            }
        }
    }

    private func place(_ path: String?) -> String { AgentsCommand.home(path) }
    /// Keep the end of a path: the last components say more than the first.
    private func tail(_ text: String, width: Int) -> String {
        text.count <= width ? text : width <= 2 ? String(text.suffix(max(0, width))) : ".." + text.suffix(width - 2)
    }
    private func right(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - text.count)) + String(text.suffix(max(0, width)))
    }
    private func ceiling(_ values: [Double?], cells: Int, floor: Double) -> Double {
        max(floor, (values.suffix(cells * 2).compactMap { $0 }.max() ?? 0) * 1.15)
    }

    func renderAgents(_ canvas: inout TerminalCanvas, w: Int, height: Int) {
        let textInk = MengohPalette.foreground(0xBCC0C6), border = MengohPalette.foreground(0x4D535C)
        let dim = MengohPalette.foreground(0x999EA7)
        let sessions = agents.sessions
        let totals = AgentRegistry.totals(sessions)
        // On a short terminal an open stream replaces the summary panel rather than squeezing into five rows.
        let streamOnly = agents.streamOpen && height < 40
        let cpuHeight = streamOnly ? 0 : height <= 34 ? 9 : max(9, min(18, height / 3 + 1))
        if !streamOnly { renderAgentSummary(&canvas, w: w, cpuHeight: cpuHeight, sessions: sessions, totals: totals) }
        let bodyY = top + cpuHeight
        let footerHeight = 6, footerY = height - footerHeight - 1, bodyHeight = footerY - bodyY
        if agents.streamOpen {
            renderStream(&canvas, rect: TerminalRect(0, bodyY, w, bodyHeight))
        } else {
            let leftWidth = max(29, w * 34 / 100)
            let netHeight = bodyHeight >= 14 ? max(9, bodyHeight * 42 / 100) : 0
            renderAgentMemory(&canvas, rect: TerminalRect(0, bodyY, leftWidth, bodyHeight - netHeight), totals: totals)
            if netHeight > 0 { renderNetwork(&canvas, rect: TerminalRect(0, bodyY + bodyHeight - netHeight, leftWidth, netHeight)) }
            renderAgentRows(&canvas, rect: TerminalRect(leftWidth, bodyY, w - leftWidth, bodyHeight))
        }

        let checked = agents.narrationAt.map { " / as of " + $0.formatted(date: .omitted, time: .standard) } ?? ""
        let state = paused ? "paused" : !sample.thermal.admitsWork ? "waiting for thermal recovery" : agents.narrationStatus
        canvas.box(TerminalRect(0, footerY, w, footerHeight), title: "**INTELLIGENCE** / agent narration / \(state)\(checked)",
                   style: border, titleStyle: textInk, markdownTitle: true)
        var insightX = 2
        if w >= 110, warpEnabled {
            canvas.header(whoCard(state: state, checked: agents.narrationAt, model: glyphLabel), in: TerminalRect(2, footerY + 1, Self.whoWidth, 3))
            insightX = Self.whoWidth + 4
        } else if w >= 100, warpEnabled, let portrait = GlyphPortrait.data, canvas.portrait(portrait, in: TerminalRect(2, footerY + 1, 8, 3)) { insightX = 12 }
        let session = selectedAgent
        let text: String
        if let session, agents.narrationFor == session.id, !agents.narration.isEmpty { text = agents.narration }
        else if let session {
            text = session.hasStream
                ? "Watching \(TerminalMarkdown.literal(session.harness)) \(session.id.pid) in \(TerminalMarkdown.literal(tail(place(session.workingDirectory), width: 48))). Press **i** for a read of what it is doing, or **o** to open its stream."
                : "\(TerminalMarkdown.literal(session.harness)) \(session.id.pid): detection and resource use only. No session log is available to read."
        } else { text = "No agent sessions are running for this user." }
        canvas.markdown(text, in: TerminalRect(insightX, footerY + 1, w - insightX - 2, 3), style: textInk)
        let selection = "SELECTED " + TerminalText.fit(session.map { String($0.id.pid) } ?? "--", width: 10) + " | "
        canvas.text(selection, x: 2, y: footerY + 4, width: selection.count, style: dim)
        var x = 2 + selection.count
        for (label, key) in [(agents.streamOpen ? "Close stream" : "Open stream", "o"), (w >= 109 ? "Narrate locally" : "Narrate", "i"), ("System view", "g"), ("Chat", "c")] {
            if let rect = control(&canvas, label, key: key, x: x, y: footerY + 4, limit: w - 2,
                                  color: key == "i" ? MengohPalette.signal : 0xBCC0C6) { x += rect.width + 2 }
        }
        if !notice.isEmpty, x + 4 < w - 2 { canvas.text(notice, x: x, y: footerY + 4, width: w - 2 - x, style: dim) }
    }

    func renderAgentSummary(_ canvas: inout TerminalCanvas, w: Int, cpuHeight: Int, sessions: [AgentSession], totals: [AgentHarnessTotal]) {
        let textInk = MengohPalette.foreground(0xBCC0C6), border = MengohPalette.foreground(0x4D535C)
        let dim = MengohPalette.foreground(0x999EA7)
        let working = sessions.filter { $0.status == .working }.count
        let processCount = sessions.reduce(0) { $0 + $1.processCount }
        canvas.box(TerminalRect(0, top, w, cpuHeight), title: "**AGENTS** \(sessions.count) sessions / \(processCount) processes / \(working) working",
                   style: border, titleStyle: textInk, markdownTitle: true)
        let gpuText = "GPU \(percent(metrics.gpu)) machine-wide"
        canvas.text(gpuText, x: max(46, w - gpuText.count - 3), y: top, width: gpuText.count, style: textInk)
        let split = max(28, w * 54 / 100)
        let bandHeight = max(3, (cpuHeight - 2) / 2)
        let gaugeWidth = split - 4 >= 48 ? 13 : 9
        let chartX = gaugeWidth + 4, chartWidth = split - chartX - 2
        let share = agents.cpuHistory.last ?? nil
        let cpuScale = min(100, ceiling(agents.cpuHistory, cells: chartWidth, floor: 10))
        canvas.gauge(share, in: TerminalRect(2, top + 1 + (bandHeight - min(5, bandHeight)) / 2, gaugeWidth, min(5, bandHeight)),
                     style: MengohPalette.foreground(MengohPalette.signal))
        canvas.markdownLabel("**CPU**  agent share / scale \(Int(cpuScale))%", x: chartX, y: top + 1, width: chartWidth, style: textInk)
        canvas.chart(agents.cpuHistory, in: TerminalRect(chartX, top + 2, chartWidth, bandHeight - 1), maximum: cpuScale, color: MengohPalette.signal)
        let tokenY = top + 1 + bandHeight, tokenRows = cpuHeight - 2 - bandHeight
        let tokens = agents.tokenHistory.last.flatMap { $0 } ?? 0
        let tokenScale = ceiling(agents.tokenHistory, cells: chartWidth, floor: 1000)
        let tokenText = AgentsCommand.count(tokens)
        canvas.text(tokenText, x: 2 + (gaugeWidth - tokenText.count) / 2, y: tokenY + max(0, tokenRows / 2 - 1), width: gaugeWidth,
                    style: "1;" + MengohPalette.foreground(MengohPalette.research))
        canvas.text("tok/min", x: 2 + (gaugeWidth - 7) / 2, y: tokenY + max(1, tokenRows / 2), width: 7, style: dim)
        canvas.markdownLabel("**TOKENS**/min  all agents / scale \(AgentsCommand.count(tokenScale))", x: chartX, y: tokenY, width: chartWidth, style: textInk)
        canvas.chart(agents.tokenHistory, in: TerminalRect(chartX, tokenY + 1, chartWidth, tokenRows - 1), maximum: tokenScale, color: MengohPalette.research)
        // Right side: one line per harness, then how agents compare with the rest of the machine.
        let rightWidth = w - split - 2, nameWidth = max(6, min(14, rightWidth - 25))
        canvas.text(TerminalText.fit("HARNESS", width: nameWidth) + "   N  CPU/c    RAM  TOK/M", x: split, y: top + 1, width: rightWidth, style: "1;" + textInk)
        let harnessRows = max(0, cpuHeight - 5)
        for (index, total) in totals.prefix(harnessRows).enumerated() {
            let row = TerminalText.fit(total.harness, width: nameWidth) + " " + right(String(total.sessions), 3) + " "
                + right(String(format: "%.0f%%", total.cpu), 6) + " " + right(bytes(total.memory), 6) + " " + right(AgentsCommand.count(total.tokensPerMinute), 6)
            canvas.text(row, x: split, y: top + 2 + index, width: rightWidth, style: textInk)
        }
        if totals.isEmpty { canvas.text("No agent sessions for this user.", x: split, y: top + 2, width: rightWidth, style: dim) }
        let rest = sample.cpu.flatMap { whole in share.map { max(0, whole - $0) } }
        canvas.text("Rest of machine CPU \(percent(rest))", x: split, y: top + cpuHeight - 2, width: rightWidth, style: dim)
    }

    private func renderAgentMemory(_ canvas: inout TerminalCanvas, rect r: TerminalRect, totals: [AgentHarnessTotal]) {
        panel(&canvas, r, "**AGENT MEMORY**")
        let x = r.x + 2, w = r.width - 4, end = r.y + r.height - 1
        var y = r.y + 1
        let memory = totals.reduce(UInt64(0)) { $0 + $1.memory }
        let share = sample.ram > 0 ? Double(memory) / Double(sample.ram) * 100 : nil
        if y < end { canvas.text("Agents \(bytes(memory)) / \(bytes(sample.ram))  \(percent(share))", x: x, y: y, width: w); y += 1 }
        if y < end { canvas.bar(share, x: x, y: y, width: w, style: MengohPalette.foreground(MengohPalette.moss)); y += 1 }
        let colors = [MengohPalette.research, MengohPalette.amber, MengohPalette.iris, MengohPalette.ion, MengohPalette.moss]
        for (index, total) in totals.enumerated() where y < end - (r.height >= 14 ? 4 : 0) {
            canvas.text(TerminalText.fit(total.harness, width: 10) + " " + right(bytes(total.memory), 6), x: x, y: y, width: 17)
            // Bars compare harnesses with each other; the line above compares agents with the machine.
            canvas.bar(memory > 0 ? Double(total.memory) / Double(memory) * 100 : nil, x: x + 18, y: y, width: w - 18,
                       style: MengohPalette.foreground(colors[index % colors.count])); y += 1
        }
        if end - y >= 3 {
            let scale = min(100, ceiling(agents.memoryHistory, cells: w, floor: 5))
            canvas.text("Share of physical RAM / scale \(Int(scale))%", x: x, y: y, width: w, style: MengohPalette.foreground(0x999EA7)); y += 1
            canvas.chart(agents.memoryHistory, in: TerminalRect(x, y, w, end - y), maximum: scale, color: MengohPalette.moss)
        }
    }

    private func renderAgentRows(_ canvas: inout TerminalCanvas, rect r: TerminalRect) {
        let textInk = MengohPalette.foreground(0xBCC0C6), dim = MengohPalette.foreground(0x999EA7)
        let selectedStyle = MengohPalette.foreground(0xF0F1F3) + ";" + MengohPalette.background(0x303640)
        let sessions = agents.sessions
        canvas.box(r, title: "**AGENT SESSIONS** \(sessions.count)", style: MengohPalette.foreground(0x4D535C), titleStyle: textInk, markdownTitle: true)
        let x = r.x + 2, inner = r.width - 4
        let wide = inner >= 70
        let fixed = wide ? "HARNESS         PID STATUS  CPU/c    MEM  TOK/M LAST " : "HARNESS      PID STATUS  CPU/c "
        canvas.text(fixed + "WHERE", x: x, y: r.y + 1, width: inner, style: "1;" + textInk)
        let capacity = max(1, r.height - 3)
        if let index = sessions.firstIndex(where: { $0.id == agents.selected }) {
            if index < agents.offset { agents.offset = index }
            if index >= agents.offset + capacity { agents.offset = index - capacity + 1 }
        }
        agents.offset = max(0, min(agents.offset, max(0, sessions.count - capacity)))
        let visible = Array(sessions.dropFirst(agents.offset).prefix(capacity))
        agents.rowsOnScreen = visible.map(\.id); agents.rowsRect = r; agents.rowStart = r.y + 3
        for (index, session) in visible.enumerated() {
            let y = r.y + 2 + index
            let isSelected = session.id == agents.selected
            if isSelected { canvas.fill(TerminalRect(x - 1, y, r.width - 2, 1), style: selectedStyle) }
            let name = session.harness + (session.processCount > 1 ? " x\(session.processCount)" : "")
            let cpu = session.cpu.map { String(format: "%.1f", $0) } ?? "--"
            var row = TerminalText.fit(name, width: wide ? 12 : 9) + " " + right(String(session.id.pid), 6) + " "
                + TerminalText.fit(session.status.rawValue, width: 7) + " " + right(cpu, 5) + " "
            if wide {
                row += right(bytes(session.memory), 6) + " " + right(AgentsCommand.count(session.tokensPerMinute), 6) + " "
                    + right(AgentsCommand.age(session.lastActivity), 4) + " "
            }
            let via = session.launcher.map { " via " + $0 } ?? ""
            let room = inner - row.count
            let whereText = session.title == "background helpers" ? "background helpers" : place(session.workingDirectory)
            row += room - via.count >= 12 ? tail(whereText, width: room - via.count) + via : tail(whereText, width: max(0, room))
            canvas.text(row, x: x, y: y, width: inner, style: isSelected ? selectedStyle : "0")
            if !isSelected {
                let color: UInt32 = session.status == .working ? MengohPalette.signal : session.status == .waiting ? MengohPalette.warning : 0x999EA7
                let statusX = x + (wide ? 12 : 9) + 8
                canvas.text(TerminalText.fit(session.status.rawValue, width: 7), x: statusX, y: y, width: 7, style: MengohPalette.foreground(color))
            }
        }
        if sessions.isEmpty { canvas.text("No agent sessions found for this user.", x: x, y: r.y + 2, width: inner, style: dim) }
        let position = " \(sessions.isEmpty ? 0 : agents.offset + 1)-\(agents.offset + visible.count)/\(sessions.count) "
        let limit = " per-agent GPU/network not measured "
        if limit.count + position.count + 6 <= r.width { canvas.text(limit, x: r.x + 2, y: r.y + r.height - 1, width: limit.count, style: dim) }
        canvas.text(position, x: r.x + r.width - position.count - 2, y: r.y + r.height - 1, width: position.count, style: textInk)
    }

    private func renderStream(_ canvas: inout TerminalCanvas, rect r: TerminalRect) {
        let dim = MengohPalette.foreground(0x999EA7)
        guard let session = selectedAgent else { closeStream(); return }
        let path = streamPath
        let tail = path.flatMap { agentRegistry.tail($0) }
        let inner = TerminalRect(r.x + 2, r.y + 1, r.width - 4, r.height - 2)
        let key = "\(path ?? "")|\(tail?.revision ?? -1)|\(inner.width)"
        if key != agents.streamKey {
            let before = agents.streamRows.count
            agents.streamRows = AgentStreamLayout.rows(tail?.events ?? [], width: inner.width)
            // While scrolled back, keep the same entries in view as new ones arrive below.
            if agents.scroll > 0, agents.streamKey.hasPrefix((path ?? "") + "|") { agents.scroll += max(0, agents.streamRows.count - before) }
            agents.streamKey = key
        }
        let total = agents.streamRows.count
        agents.streamPage = max(1, inner.height - 1)
        agents.scroll = max(0, min(agents.scroll, max(0, total - inner.height)))
        var controls = [("Close", "o")]
        if session.logs.count > 1 { controls.append(("Next log", "n")) }
        if agents.scroll > 0 { controls.append(("Follow", "f")) }
        let log = session.logs.count > 1 ? " / log \(min(agents.logIndex, session.logs.count - 1) + 1) of \(session.logs.count)" : ""
            + (session.logInferred ? " / matched by directory" : "")
        let whereText = TerminalMarkdown.literal(self.tail(place(tail?.workingDirectory ?? session.workingDirectory), width: max(8, r.width / 4)))
        panel(&canvas, r, "**STREAM** \(TerminalMarkdown.literal(session.harness)) \(session.id.pid) / \(agents.scroll == 0 ? "following" : "scrolled back")\(log) / \(whereText)",
              controls: controls)
        if total == 0 {
            canvas.text(tail == nil ? "Opening the session log..." : "No readable entries in the recent part of this log yet.",
                        x: inner.x, y: inner.y, width: inner.width, style: dim)
            return
        }
        let start = max(0, total - inner.height - agents.scroll)
        canvas.glyphs(agents.streamRows[start..<min(total, start + inner.height)], in: inner)
        let position = " \(start + 1)-\(min(total, start + inner.height))/\(total) rows | secrets masked "
        canvas.text(position, x: r.x + r.width - position.count - 2, y: r.y + r.height - 1, width: position.count, style: dim)
    }
}
