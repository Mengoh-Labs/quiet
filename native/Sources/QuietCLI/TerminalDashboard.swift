import Darwin
import Foundation
import QuietCore
import QuietSilicon

@MainActor final class TerminalDashboard {
    var original = termios()
    var originalFlags: Int32 = 0
    var terminalActive = false
    var running = true
    var signals: [DispatchSourceSignal] = []
    var decoder = TerminalInput()
    let sampler = Sampler()
    let controller = ProcessTermination()
    let intelligence = SiliconRuntime()
    let store = ObservationStore(directory: ObservationStore.defaultDirectory.appendingPathComponent("Terminal"))
    var sample = Telemetry()
    var detector = HotspotDetector()
    var hotspots: [Hotspot] = []
    var selectionPinned = false
    var selected: ProcessIdentity?
    var offset = 0
    var query = ""
    var searching = false
    var sortMemory = false
    var paused = false
    var review: TerminationReview?
    var reviewTime = 0.0
    var force = false
    var forceCandidate: ProcessIdentity?
    var detailExpanded = false
    var insightScroll = 0
    var insightPage = 1
    var footerRect = TerminalRect(0, 0, 0, 0)
    var working = false
    var task: Task<Void, Never>?
    var insight = "Watching the next few samples to see what stands out."
    let ambientEnabled = ProcessInfo.processInfo.environment["QUIET_AMBIENT"] != "off"
    var ambientTask: Task<Void, Never>?
    var ambientWindow = ObservatoryWindow()
    var ambientGate = AmbientInsightGate()
    var ambientText = "Watching the next few samples to see what stands out."
    var ambientStatus = "observing"
    var ambientCheckedAt: Date?
    var appleAvailable = false
    /// Narration and chat can run on Apple's model or on a selected local MLX model.
    var glyphReady: Bool { appleAvailable || GlyphModel.current().backend == .mlx }
    var notice = "Select a process, then review. CPU percentages per process use one core."
    var history: [Double?] = []
    var gpuHistory: [Double?] = []
    var networkHistory: [String: ([Double?], [Double?])] = [:]
    var processHistory: [ProcessIdentity: [Double?]] = [:]
    var memoryHistory: [Double?] = []
    var diskReadHistory: [Double?] = []
    var diskWriteHistory: [Double?] = []
    var networkPeaks: [String: (Double, Double)] = [:]
    var showDisks = false
    var sharedNetworkScale = false
    var metrics = MachineMetrics()
    var networkName: String?
    var volumeIndex = 0
    var reversed = false
    var interval = 2.0
    var buttons: [(TerminalRect, String)] = []
    /// What each control says, for the test harness: a rendered label is not on the text screen.
    var controlLabels: [String] = []
    var controlMapWritten = ""
    var processRect = TerminalRect(0, 0, 0, 0)
    var oldRows: [String] = []
    let warpRequested = WarpGraphics.requested(environment: ProcessInfo.processInfo.environment)
    var warpEnabled = false
    var warpProbeStarted = 0.0
    var warpProbeTimedOut = false
    var warpRejected = false
    var warpGraphics = WarpGraphics(animated: false)
    let syncRequested = ProcessInfo.processInfo.environment["QUIET_SYNC"] != "off"
        && WarpGraphics.canQuery(environment: ProcessInfo.processInfo.environment)
    var synchronizedOutput = false
    var pendingImageCleanup = ""
    var framePacer = TerminalFramePacer()
    var collectorMilliseconds = 0.0
    var users: [UInt32: String] = [:]
    var widths = (0, 0)
    var rowsOnScreen: [ProcessIdentity] = []
    var rowStart = 10
    var reviewConfirmRect: TerminalRect?
    var reviewCancelRect: TerminalRect?
    var dirty = true
    var hardware = "Inspecting Apple silicon..."
    var aiStatus = "Checking availability"
    var persisted = "Recording: waiting"
    var mode = DashboardMode.system
    /// Rows above the first panel: three for the text masthead, four when the header is a rendered card.
    var top = 3
    var headerRendered = false
    var glyphLabel = GlyphModel.apple.label
    var chat = ChatState()
    let chatStore = ChatState.store()
    var agents = AgentsState()
    let agentRegistry = AgentsCommand.registry()

    static func run() async throws {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
              ProcessInfo.processInfo.environment["TERM"] != "dumb" else {
            throw QuietError("Quiet's dashboard needs an interactive terminal. Use quiet sample or quiet history for pipes.")
        }
        let dashboard = TerminalDashboard()
        try dashboard.enter()
        defer { dashboard.restore() }
        dashboard.installSignals()
        defer { dashboard.signals.forEach { $0.cancel() } }
        let hw = await Task.detached(priority: .utility) { SiliconHardware.read() }.value
        dashboard.hardware = "\(hw.gpuName) / \(hw.neuralEngineCores)-core Neural Engine"
        dashboard.aiStatus = hw.appleStatus
        dashboard.appleAvailable = hw.appleAvailable
        if !dashboard.ambientEnabled {
            dashboard.ambientText = "Ambient commentary is off. Press i for a fresh read of the available data."
            dashboard.ambientStatus = "manual"
        } else if !hw.appleAvailable {
            dashboard.ambientText = hw.appleStatus + ". Live measurements remain available."
            dashboard.ambientStatus = "unavailable"
        }
        try? await dashboard.store.action("terminal.start", outcome: "started")
        await dashboard.loop()
        dashboard.restore()
        let pending = [dashboard.ambientTask, dashboard.task, dashboard.agents.task, dashboard.chat.task]
        pending.forEach { $0?.cancel() }
        for task in pending { await task?.value }
        await dashboard.intelligence.stop()
    }

    func enter() throws {
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw QuietError("Cannot read terminal settings.") }
        originalFlags = fcntl(STDIN_FILENO, F_GETFL)
        var raw = original; cfmakeraw(&raw); raw.c_lflag |= tcflag_t(ISIG)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { throw QuietError("Cannot enter terminal mode.") }
        terminalActive = true
        if fcntl(STDIN_FILENO, F_SETFL, originalFlags | O_NONBLOCK) == -1 { restore(); throw QuietError("Cannot read terminal input.") }
        output("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?2004h")
        warpEnabled = false; warpRejected = false; warpProbeTimedOut = false
        synchronizedOutput = false; framePacer.reset()
        warpProbeStarted = ProcessInfo.processInfo.systemUptime
        if syncRequested { output(TerminalSynchronizedOutput.query) }
        if warpRequested { output(WarpGraphics.probe + "\u{1b}[16t") }
    }
    func restore() {
        guard terminalActive else { return }
        ambientTask?.cancel()
        output(TerminalSynchronizedOutput.end + pendingImageCleanup + warpGraphics.reset())
        pendingImageCleanup = ""; framePacer.reset(); synchronizedOutput = false
        output("\u{1b}[0m\u{1b}[?2004l\u{1b}[?1006l\u{1b}[?1000l\u{1b}[?25h\u{1b}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        _ = fcntl(STDIN_FILENO, F_SETFL, originalFlags)
        terminalActive = false
    }
    func installSignals() {
        for number in [SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if number == SIGTSTP {
                        self.restore(); kill(getpid(), SIGSTOP)
                        // SIGSTOP returns after continuation. Re-enter before the sample loop can
                        // read with restored blocking flags; a queued SIGCONT task can arrive later.
                        if self.running && !self.terminalActive {
                            do { try self.enter(); self.dirty = true; self.oldRows = [] }
                            catch { self.running = false }
                        }
                    } else if number == SIGCONT {
                        if !self.terminalActive {
                            do { try self.enter(); self.dirty = true; self.oldRows = [] } catch { self.running = false }
                        }
                    } else { self.running = false }
                }
            }
            source.resume(); signals.append(source)
        }
    }
    func output(_ text: String) { try? FileHandle.standardOutput.write(contentsOf: Data(text.utf8)) }
    func outputFrame(_ text: String) {
        guard !text.isEmpty else { return }
        output(TerminalSynchronizedOutput.frame(text, enabled: synchronizedOutput))
    }
    func dimensions() -> (Int, Int) {
        var size = winsize(); _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
        return (max(20, min(240, Int(size.ws_col))), max(8, min(100, Int(size.ws_row))))
    }
    var processes: [ProcessSample] {
        let sorted = sample.processes.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.id.pid).contains(query) }
            .sorted {
                let left = sortMemory ? Double($0.memory) : ($0.cpu ?? -1)
                let right = sortMemory ? Double($1.memory) : ($1.cpu ?? -1)
                return left == right ? $0.id.pid < $1.id.pid : left > right
            }
        var ordered = reversed ? Array(sorted.reversed()) : sorted
        // A typed PID means that process: list it before others whose PID merely contains the digits.
        if let exact = Int32(query), let index = ordered.firstIndex(where: { $0.id.pid == exact }), index > 0 {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        guard agents.groupFirst else { return ordered }
        // Agents first, each side keeping the chosen sort.
        return ordered.filter { agentRegistry.membership(of: $0.id) != nil } + ordered.filter { agentRegistry.membership(of: $0.id) == nil }
    }
    func loop() async {
        var nextSample = 0.0
        var lastInput = 0.0
        while running {
            let now = ProcessInfo.processInfo.systemUptime
            if warpRequested && !warpEnabled && !warpRejected && !warpProbeTimedOut && now - warpProbeStarted > 3 {
                warpProbeTimedOut = true; dirty = true
            }
            if !paused && now >= nextSample {
                sample = await sampler.sample()
                hotspots = detector.ingest(sample.processes, at: now)
                history.append(sample.cpu); history = Array(history.suffix(480))
                let metricsStart = ProcessInfo.processInfo.systemUptime
                metrics.read(now: metricsStart)
                collectorMilliseconds = sample.sampleMilliseconds + (ProcessInfo.processInfo.systemUptime - metricsStart) * 1000
                sample.gpuPercent = metrics.gpu; sample.gpuMemory = metrics.gpuMemory
                ambientWindow.observe(at: now, values: ObservatoryEvidence.values(sample, metrics))
                gpuHistory.append(metrics.gpu); gpuHistory = Array(gpuHistory.suffix(480))
                let used = memoryAccounting.occupiedPercent
                memoryHistory.append(used); memoryHistory = Array(memoryHistory.suffix(480))
                diskReadHistory = Array((diskReadHistory + [metrics.diskRead]).suffix(480))
                diskWriteHistory = Array((diskWriteHistory + [metrics.diskWrite]).suffix(480))
                for network in metrics.networks {
                    let peak = networkPeaks[network.name] ?? (0, 0)
                    networkPeaks[network.name] = (max(peak.0, network.download ?? 0), max(peak.1, network.upload ?? 0))
                    let old = networkHistory[network.name] ?? ([], [])
                    networkHistory[network.name] = (Array((old.0 + [network.download]).suffix(480)), Array((old.1 + [network.upload]).suffix(480)))
                }
                networkHistory = networkHistory.filter { name, _ in metrics.networks.contains { $0.name == name } }
                if networkName == nil || !metrics.networks.contains(where: { $0.name == networkName }) {
                    networkName = metrics.networks.filter { $0.name.hasPrefix("en") }.max { $0.received < $1.received }?.name ?? metrics.networks.first?.name
                }
                var next: [ProcessIdentity: [Double?]] = [:]
                for process in sample.processes {
                    next[process.id] = Array(((processHistory[process.id] ?? []) + [process.cpu]).suffix(24))
                }
                processHistory = next
                if selected == nil || !selectionPinned { selected = processes.first?.id }
                let runtime = await intelligence.snapshot()
                do {
                    if try await store.record(sample, hotspots: hotspots, contexts: [:], mode: "Terminal observation", activeJobs: 0, ollamaBusy: false, nativeBusy: runtime.busy, uptime: now) {
                        persisted = "Recording: local, ~24h retention"
                    }
                } catch { persisted = "Recording failed: \(error.localizedDescription)" }
                let agentsStart = ProcessInfo.processInfo.systemUptime
                ingestAgents(at: now)
                glyphLabel = GlyphModel.current().label
                // Counted in the footer's sample time, so a slow agent pass is visible rather than silent.
                collectorMilliseconds += (ProcessInfo.processInfo.systemUptime - agentsStart) * 1000
                // A local model's weights are released after five idle minutes rather than held for the session.
                await intelligence.releaseIfIdle()
                updateAmbient(at: now)
                updateNarration(at: now)
                nextSample = now + interval; dirty = true
            }
            let size = dimensions()
            if size != widths {
                widths = size; oldRows = []
                if warpRequested { output("\u{1b}[16t") }
                dirty = true
            }
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count > 0 {
                lastInput = now
                // Never let a batched click/key sequence confirm a review created in that batch.
                let hadReview = review != nil
                for event in decoder.feed(Array(bytes.prefix(count))) {
                    if review != nil && !hadReview { break }
                    await handle(event)
                }
                dirty = true
            } else if count == 0 { running = false }
            else if errno != EAGAIN && errno != EINTR { running = false }
            if now - lastInput > 0.15 { for event in decoder.flushEscape() { await handle(event); dirty = true } }
            let frameStart = ProcessInfo.processInfo.systemUptime
            if dirty && terminalActive {
                render(); dirty = false
                framePacer.completed(started: frameStart, ended: ProcessInfo.processInfo.systemUptime)
            } else if terminalActive && warpEnabled && warpGraphics.isAnimating && framePacer.due(at: frameStart) {
                outputFrame(warpGraphics.animate(finish: paused))
                framePacer.completed(started: frameStart, ended: ProcessInfo.processInfo.systemUptime)
            }
            try? await Task.sleep(for: .milliseconds(framePacer.sleepMilliseconds(
                at: ProcessInfo.processInfo.systemUptime, animating: warpGraphics.isAnimating)))
        }
    }
    func move(_ delta: Int) {
        selectionPinned = true
        let items = processes
        guard !items.isEmpty else { selected = nil; return }
        let index = items.firstIndex { $0.id == selected } ?? 0
        selected = items[max(0, min(items.count - 1, index + delta))].id
    }
    func handle(_ event: TerminalEvent) async {
        switch event {
        case .synchronizedOutput(let supported):
            if syncRequested { synchronizedOutput = supported; dirty = true }
        case .cellSize(let width, let height):
            if warpRequested {
                pendingImageCleanup += warpGraphics.cellSize(width: width, height: height)
                dirty = true
            }
        case .graphicsResponse(let id, let ok):
            if warpRequested && id == WarpGraphics.probeID {
                warpEnabled = ok; warpRejected = !ok; oldRows = []; dirty = true
            }
        case .paste(let value):
            // Pasted text is only ever text: it can fill the chat box but never send or act.
            if chat.open { chat.input += String(TerminalText.safe(value).prefix(max(0, GlyphChat.inputLimit - chat.input.count))) }
            else if searching { query += String(TerminalText.safe(value).prefix(max(0, 80 - query.count))); selected = nil }
        case .mouse(let button, let x, let y):
            guard widths.0 >= 80, widths.1 >= 26 else { return }
            if chat.open { handleChatMouse(button: button); return }
            if mode == .agents && review == nil { await handleAgentMouse(button: button, x: x, y: y); return }
            if (button == 64 || button == 65) && review == nil && detailExpanded && footerRect.contains(x: x - 1, y: y - 1) {
                insightScroll += button == 64 ? -1 : 1; return
            }
            if button == 64 { if review == nil { move(-3) }; return }
            if button == 65 { if review == nil { move(3) }; return }
            guard button == 0 else { return }
            if review != nil {
                if reviewConfirmRect?.contains(x: x - 1, y: y - 1) == true { confirm() }
                else if reviewCancelRect?.contains(x: x - 1, y: y - 1) == true { review = nil; force = false }
            } else if let button = buttons.first(where: { $0.0.contains(x: x - 1, y: y - 1) }) {
                await handle(.key(button.1))
            } else if processRect.contains(x: x - 1, y: y - 1), y >= rowStart && y < rowStart + rowsOnScreen.count {
                selectionPinned = true; selected = rowsOnScreen[y - rowStart]
            }
        case .key(let key):
            if widths.0 < 80 || widths.1 < 26 { if key == "q" { running = false }; return }
            if chat.open { await handleChatKey(key); return }
            if searching {
                // Select the top match now; otherwise nothing is selected until the next sample.
                if key == "escape" || key == "enter" { searching = false; if selected == nil { selected = processes.first?.id } }
                else if key == "backspace" { if !query.isEmpty { query.removeLast() } }
                else if key.count == 1 && query.count < 80 { query += key; selected = nil }
                return
            }
            if review != nil {
                if key == "escape" || key == "n" { review = nil; force = false }
                else if key == "y" { confirm() }
                return
            }
            if key == "c" { openChat(); return }
            if key == "g" || key == "tab" {
                mode = mode == .system ? .agents : .system
                notice = mode == .agents ? "" : "Select a process, then review. CPU percentages per process use one core."
                searching = false; detailExpanded = false
                return
            }
            if mode == .agents, await handleAgentKey(key) { return }
            switch key {
            case "q": running = false
            case "t": agents.groupFirst.toggle(); selectionPinned = false; selected = processes.first?.id; offset = 0
            case "o": openStreamForSelectedProcess()
            case "up", "k": move(-1)
            case "down", "j": move(1)
            case "pageUp": move(-max(1, rowsOnScreen.count))
            case "pageDown": move(max(1, rowsOnScreen.count))
            case "home": move(-processes.count)
            case "end": move(processes.count)
            case "s": sortMemory.toggle(); reversed = false; selectionPinned = false; selected = processes.first?.id; offset = 0
            case "x": reversed.toggle(); selectionPinned = false; selected = processes.first?.id; offset = 0
            case "n":
                if !metrics.networks.isEmpty {
                    let index = metrics.networks.firstIndex { $0.name == networkName } ?? -1
                    networkName = metrics.networks[(index + 1) % metrics.networks.count].name
                }
            case "d": volumeIndex += 1; showDisks = true
            case "m": showDisks.toggle()
            case "a": sharedNetworkScale.toggle()
            case "+", "=": interval = max(1, interval - 1)
            case "-": interval = min(10, interval + 1)
            case "/": searching = true
            case "[": if detailExpanded { insightScroll -= insightPage }
            case "]": if detailExpanded { insightScroll += insightPage }
            case "escape": detailExpanded = false; insightScroll = 0; query = ""; selectionPinned = false; selected = processes.first?.id; task?.cancel(); ambientTask?.cancel(); await intelligence.stop(); notice = "Filter cleared; local inference cancelled."
            case "p":
                paused.toggle()
                if paused { ambientTask?.cancel() }
            case "i": explain()
            case "h": showHistory()
            case "r", "enter": await inspect()
            default: break
            }
        }
    }
    func inspect() async {
        guard !working, let selected else { return }
        ambientTask?.cancel()
        detailExpanded = true
        do {
            review = try await controller.review(selected)
            force = forceCandidate == selected && review?.canForce == true
            reviewTime = ProcessInfo.processInfo.systemUptime
        } catch { notice = error.localizedDescription }
    }
    func confirm() {
        guard !working, let approved = review, approved.allowed,
              ProcessInfo.processInfo.systemUptime - reviewTime >= 0.5 else { return }
        review = nil; working = true
        let useForce = force
        task = Task {
            defer { working = false; dirty = true }
            do {
                try? await store.action(useForce ? "process.force_stop" : "process.stop", outcome: "requested", process: approved.process)
                let result = try await controller.stop(approved.id, force: useForce)
                switch result {
                case .exited:
                    forceCandidate = nil; notice = "PID \(approved.process.pid) exited."
                    try? await store.action("process.stop", outcome: "exited", process: approved.process)
                case .stillRunning:
                    forceCandidate = useForce ? nil : approved.process
                    notice = "PID \(approved.process.pid) still present. Press r for a separate force-stop review."
                    try? await store.action("process.stop", outcome: "still_present", process: approved.process)
                }
            } catch {
                notice = error.localizedDescription
                try? await store.action("process.stop", outcome: "failed", process: approved.process)
            }
        }
    }
    func showHistory() {
        guard !working else { return }
        detailExpanded = true; insightScroll = 0
        working = true
        task = Task {
            defer { working = false; dirty = true }
            do {
                insight = try await Task.detached(priority: .utility) {
                    let text = try ObservationStore.history(hours: 1)
                    let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                    let records = root?["records"] as? [[String: Any]] ?? []
                    let observations = records.filter { $0["event"] as? String == "quiet.observation" }
                    let values = observations.compactMap { ($0["fields"] as? [String: Any])?["cpu.percent"] as? Double }
                    guard !values.isEmpty else { return "**APP HISTORY**: No CPU observations retained in the last hour. Terminal history: `quiet history 1 --terminal`" }
                    let mean = values.reduce(0, +) / Double(values.count)
                    let last = observations.last?["timestamp"] as? String ?? "unknown"
                    return "**APP HISTORY** / last hour: \(values.count) CPU samples; mean \(String(format: "%.1f", mean))%, peak \(String(format: "%.1f", values.max() ?? 0))%. Latest saved at \(last). Point-sample summary, not time-weighted. Use `quiet history` for process detail."
                }.value
            } catch { insight = "**History unavailable:** " + TerminalMarkdown.literal(error.localizedDescription) }
        }
    }
    func explain() {
        guard !working else { return }
        detailExpanded = true; insightScroll = 0
        working = true; insight = "Taking a closer look at the recent measurements..."
        let ambient = ambientTask; ambient?.cancel()
        task = Task {
            defer { working = false; dirty = true }
            do {
                await ambient?.value
                try Task.checkCancellation()
                let observedAt = sample.timestamp
                let context = ObservatoryEvidence.context(sample, metrics, window: ambientWindow, hotspots: hotspots)
                let prompt = try ObservatoryPrompt.make(context, previous: ambientCheckedAt == nil ? nil : ambientText,
                                                       ambient: false, columns: widths.0 - (warpEnabled && widths.0 >= 101 ? 10 : 0))
                ambientGate.record(context, at: ProcessInfo.processInfo.systemUptime)
                try? await store.action("terminal.explain", outcome: "requested")
                let result = try await intelligence.run(backend: .apple, directory: nil, prompt: prompt, responseStyle: .observatory)
                try Task.checkCancellation()
                insight = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                ambientText = insight; ambientCheckedAt = observedAt; ambientStatus = "local AI"
                try? await store.action("terminal.explain", outcome: "completed")
            } catch is CancellationError { }
            catch { insight = "**Local explanation unavailable:** " + TerminalMarkdown.literal(error.localizedDescription) }
        }
    }
    func updateAmbient(at now: Double) {
        if !sample.thermal.admitsWork { ambientTask?.cancel() }
        // In Agents mode the panel narrates the selected agent instead of the machine.
        let blocked = !ambientEnabled || !appleAvailable || !terminalActive || paused || review != nil || working
            || ambientTask != nil || !sample.thermal.admitsWork || mode == .agents || agents.task != nil || chat.open
        guard !blocked else { return }
        let context = ObservatoryEvidence.context(sample, metrics, window: ambientWindow, hotspots: hotspots)
        guard ambientGate.shouldRequest(context, at: now, blocked: false) else { return }
        let observedAt = sample.timestamp
        ambientStatus = "reading changes"
        ambientTask = Task {
            defer { ambientTask = nil; dirty = true }
            do {
                let prompt = try ObservatoryPrompt.make(context, previous: ambientCheckedAt == nil ? nil : ambientText,
                                                       ambient: true, columns: widths.0 - (warpEnabled && widths.0 >= 101 ? 10 : 0))
                let result = try await intelligence.run(backend: .apple, directory: nil, prompt: prompt, responseStyle: .observatory)
                try Task.checkCancellation()
                guard running, terminalActive, !paused, review == nil else { return }
                let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && text != "UNCHANGED" { ambientText = text }
                ambientCheckedAt = observedAt; ambientStatus = "local AI"
            } catch is CancellationError {
                ambientStatus = ambientCheckedAt == nil ? "observing" : "local AI"
            } catch {
                ambientGate.failed(at: ProcessInfo.processInfo.systemUptime)
                ambientStatus = "unavailable"
                if ambientCheckedAt == nil { ambientText = "On-device commentary is unavailable right now. The measurements are still live." }
            }
        }
    }
    var memoryAccounting: MemoryAccounting { metrics.memoryAccounting(total: sample.ram) }
    func bytesOptional(_ value: UInt64?) -> String { value.map(bytes) ?? "n/a" }
    func rate(_ value: Double?) -> String { value.map { bytes(UInt64(max(0, $0))) + "/s" } ?? "waiting" }
    func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "--" }
    func username(_ uid: UInt32) -> String {
        if let cached = users[uid] { return cached }
        let name = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        users[uid] = name; return name
    }
    func bytes(_ value: UInt64) -> String {
        if value >= 1_073_741_824 { return String(format: "%.1fG", Double(value) / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.1fM", Double(value) / 1_048_576) }
        return String(format: "%.0fK", Double(value) / 1024)
    }
    func render() {
        let (width, height) = widths
        // Leave the last column untouched: writing the bottom-right cell can scroll some terminals.
        var canvas = TerminalCanvas(width: width - 1, height: height, baseStyle: MengohPalette.foreground(0xDADCE0) + ";49", pixelGraphics: warpEnabled)
        let w = width - 1
        let textInk = MengohPalette.foreground(0xBCC0C6)
        let border = MengohPalette.foreground(0x4D535C)
        let cpuColor = MengohPalette.foreground(MengohPalette.moss)
        let dim = MengohPalette.foreground(0x999EA7)
        let selectedStyle = MengohPalette.foreground(0xF0F1F3) + ";" + MengohPalette.background(0x303640)
        let selectedChartStyle = MengohPalette.foreground(MengohPalette.signal) + ";" + MengohPalette.background(0x303640)
        let warning = MengohPalette.foreground(MengohPalette.warning)
        buttons = []; controlLabels = []
        reviewConfirmRect = nil; reviewCancelRect = nil
        if width < 80 || height < 26 {
            canvas.text("QUIET | Resize to at least 80 columns x 26 rows", x: 1, y: 1, width: w - 2, style: textInk)
            canvas.text("q quits. No process actions in this compact view.", x: 1, y: 3, width: w - 2)
            present(canvas); return
        }
        // Keep the masthead calm: identity, live state, then secondary machine details.
        headerRendered = warpEnabled && w >= 100 && height >= 30 && canvas.header(headerCard(), in: TerminalRect(0, 0, w, 3))
        top = headerRendered ? 4 : 3
        if !headerRendered {
            canvas.markdownLabel("**QUIET**", x: 2, y: 0, width: 5, style: MengohPalette.foreground(0xF0F1F3))
            canvas.markdownLabel(mode == .agents ? "*agent observatory*" : "*system observatory*", x: 10, y: 0, width: 20, style: dim)
            let clock = Date().formatted(date: .omitted, time: .standard)
            let graphicsLabel = (ProcessInfo.processInfo.environment["TERM_PROGRAM"] == "WarpTerminal" ? "Warp" : "graphics")
                + (synchronizedOutput ? " sync" : "")
            let status = "\(paused ? "PAUSED" : "LIVE")\(warpEnabled ? " / " + graphicsLabel : warpRequested ? (warpRejected ? " / rejected" : warpProbeTimedOut ? " / no reply" : " / checking") : " / text")  /  \(Int(interval * 1000))ms  /  \(clock)"
            canvas.text(status, x: w - status.count - 2, y: 0, width: status.count, style: textInk)
            // The masthead row repaints with the clock, so its control stays a character keycap.
            control(&canvas, mode == .agents ? "System" : "Agents", key: "g", x: 31, y: 0, limit: w - status.count - 3, graphic: false)
            let ai = "AI: " + aiStatus
            let aiX = max(2, w - ai.count - 2)
            canvas.text(hardware, x: 2, y: 1, width: max(0, aiX - 5), style: dim)
            canvas.text(ai, x: aiX, y: 1, width: w - aiX - 2, style: dim)
        }
        if chat.open {
            canvas.text("Typing goes to the chat. Esc closes it; Ctrl-C quits.", x: 2, y: top - 1, width: w - 4, style: dim)
            renderChat(&canvas, w: w, height: height)
            footerClock(&canvas, w: w, height: height)
            canvas.text("\(persisted) | sample \(String(format: "%.0f", collectorMilliseconds))ms | chat: on-device, no tools, history saved locally (25 MB cap)", x: 1, y: height - 1, width: w - 2, style: dim)
            present(canvas); return
        }
        let commands = mode == .agents
            ? [(agents.streamOpen ? "Close" : "Stream", "o"), ("Narrate", "i"), ("System", "g"), ("", ""),
               (paused ? "Resume" : "Pause", "p"), ("Quit", "q"), ("Slower", "-"), ("", ""), ("Faster", "+")]
            : [("Sort", "s"), ("Filter", "/"), ("Explain", "i"), ("Review", "r"),
               (paused ? "Resume" : "Pause", "p"), ("Quit", "q"), ("History", "h"),
               ("Reverse", "x"), ("Slower", "-"), ("Faster", "+")]
        var bx = 1
        // With a rendered header there is no masthead text row to carry the view switch.
        var toolbarLimit = w - 1
        if headerRendered, mode == .system,
           let rect = control(&canvas, "Agents", key: "g", x: w - 12, y: top - 1, limit: w - 1) { toolbarLimit = rect.x - 1 }
        for (index, command) in commands.enumerated() {
            let (label, key) = command
            if index == 4 || index == 6 { bx += 2 }
            if label.isEmpty { continue }
            // Rendered pills are one cell wider than character keycaps; keep a gap between neighbours.
            let span = max(12, label.count + 5)
            guard bx + label.count + 4 <= toolbarLimit else { break }
            control(&canvas, label, key: key, x: bx, y: top - 1, limit: toolbarLimit,
                    color: key == "i" ? MengohPalette.signal : 0xBCC0C6)
            bx += span
        }
        if mode == .agents {
            renderAgents(&canvas, w: w, height: height)
            canvas.text("\(persisted) | sample \(String(format: "%.0f", collectorMilliseconds))ms | read-only: agents are never signalled or written to", x: 1, y: height - 1, width: w - 2, style: dim)
            footerClock(&canvas, w: w, height: height)
            present(canvas); return
        }
        let cpuHeight = height <= 34 ? 9 : max(9, min(18, height / 3 + 1))
        renderSystemSummary(&canvas, w: w, cpuHeight: cpuHeight)

        let bodyY = top + cpuHeight
        let expanded = review != nil || detailExpanded
        // The panel's identity block: a rendered card when there is room, the bare portrait when
        // there is less, nothing in text mode or during a process review.
        let showWho = review == nil && w >= 110 && warpEnabled
        let portraitShown = !showWho && review == nil && w >= 100 && warpEnabled && GlyphPortrait.data != nil
        let insightX = showWho ? Self.whoWidth + 4 : portraitShown ? 12 : 2
        var footerHeight = expanded ? 7 : 6
        var insightTotal = 0
        if detailExpanded && review == nil {
            // Long answers get room and a scroll position instead of being cut at three rows.
            insightTotal = TerminalMarkdown.lines(insight, width: w - insightX - 2).count
            footerHeight = max(7, min(insightTotal + 4, height * 45 / 100, height - 1 - bodyY - 8))
        }
        insightPage = max(1, footerHeight - 5)
        insightScroll = max(0, min(insightScroll, insightTotal - (footerHeight - 4)))
        let footerY = height - footerHeight - 1
        let bodyHeight = footerY - bodyY
        let leftWidth = max(29, w * (width >= 140 ? 46 : 40) / 100)
        let netHeight = bodyHeight >= 14 ? max(9, bodyHeight * 42 / 100) : 0
        let storageHeight = bodyHeight - netHeight
        if leftWidth >= 64 {
            let half = leftWidth / 2
            renderMemory(&canvas, rect: TerminalRect(0, bodyY, half, storageHeight), compact: false)
            renderDisks(&canvas, rect: TerminalRect(half, bodyY, leftWidth - half, storageHeight), compact: false)
        } else if showDisks {
            renderDisks(&canvas, rect: TerminalRect(0, bodyY, leftWidth, storageHeight), compact: true)
        } else {
            renderMemory(&canvas, rect: TerminalRect(0, bodyY, leftWidth, storageHeight), compact: true)
        }
        if netHeight > 0 {
            renderNetwork(&canvas, rect: TerminalRect(0, bodyY + storageHeight, leftWidth, netHeight))
        }
        processRect = TerminalRect(leftWidth, bodyY, w - leftWidth, bodyHeight)
        let pw = processRect.width, px = leftWidth + 2
        let items = processes
        canvas.box(processRect, title: "**PROCESSES** \(items.count) / unreadable \(sample.unreadableProcesses)", style: border, titleStyle: textInk, markdownTitle: true)
        canvas.text("SORT: \(sortMemory ? "memory" : "CPU/core")\(reversed ? " ascending" : " descending")\(agents.groupFirst ? ", agents first" : "") | * agent: t groups, o stream", x: px, y: bodyY + 1, width: pw - 4, style: dim)
        canvas.text("FILTER: \(query.isEmpty ? "all processes" : query)\(searching ? "_" : "")", x: px, y: bodyY + 2, width: pw - 4, style: textInk)
        let wide = pw >= 78
        let nameWidth = max(8, pw - (wide ? 54 : 33))
        let header = "    PID " + TerminalText.fit("PROGRAM", width: nameWidth) + (wide ? " USER      " : " ") + " THR " + "   MEM " + "CPU/core" + (wide ? "  HISTORY" : "")
        canvas.text(header, x: px, y: bodyY + 3, width: pw - 4, style: "1;" + textInk)
        rowStart = bodyY + 5
        let capacity = max(1, bodyHeight - 5)
        if let index = items.firstIndex(where: { $0.id == selected }) {
            if index < offset { offset = index }
            if index >= offset + capacity { offset = index - capacity + 1 }
        }
        offset = max(0, min(offset, max(0, items.count - capacity)))
        let visible = Array(items.dropFirst(offset).prefix(capacity)); rowsOnScreen = visible.map(\.id)
        for (index, process) in visible.enumerated() {
            let y = bodyY + 4 + index
            let isSelected = process.id == selected
            let style = isSelected ? selectedStyle : "0"
            if isSelected { canvas.fill(TerminalRect(px - 1, y, pw - 2, 1), style: style) }
            let cpuText = process.cpu.map { String(format: "%7.1f", $0) } ?? "     --"
            let threadText = process.threads.map { String(format: "%4d", $0) } ?? "  --"
            let text = String(format: "%7d ", process.id.pid) + TerminalText.fit(process.name, width: nameWidth)
                + (wide ? " " + TerminalText.fit(username(process.uid), width: 9) + " " : " ")
                + threadText + " " + String(repeating: " ", count: max(0, 6 - bytes(process.memory).count)) + bytes(process.memory) + " " + cpuText
            canvas.text(text, x: px, y: y, width: pw - 4, style: style)
            if agentRegistry.membership(of: process.id) != nil {
                canvas.text("*", x: px, y: y, width: 1, style: isSelected ? selectedChartStyle : MengohPalette.foreground(MengohPalette.signal))
            }
            if wide { canvas.graph(processHistory[process.id] ?? [], in: TerminalRect(w - 11, y, 8, 1), maximum: max(100, (processHistory[process.id] ?? []).compactMap { $0 }.max() ?? 100), style: isSelected ? selectedChartStyle : cpuColor) }
        }
        let position = " \(items.isEmpty ? 0 : offset + 1)-\(offset + visible.count)/\(items.count) "
        canvas.text(position, x: w - position.count - 2, y: bodyY + bodyHeight - 1, width: position.count, style: textInk)
        let checked = ambientCheckedAt.map { " / as of " + $0.formatted(date: .omitted, time: .standard) } ?? ""
        let intelligenceTitle = "**INTELLIGENCE** / \(paused ? "paused" : !sample.thermal.admitsWork ? "waiting for thermal recovery" : ambientStatus)\(checked)"
        canvas.box(TerminalRect(0, footerY, w, footerHeight), title: review == nil ? intelligenceTitle : "**PROCESS REVIEW**", style: review == nil ? border : warning, titleStyle: review == nil ? textInk : warning, markdownTitle: true)
        footerRect = TerminalRect(0, footerY, w, footerHeight)
        if portraitShown, let portrait = GlyphPortrait.data { canvas.portrait(portrait, in: TerminalRect(2, footerY + 1, 8, 3)) }
        if showWho {
            let state = paused ? "paused" : !sample.thermal.admitsWork ? "held: thermal" : ambientStatus
            canvas.header(whoCard(state: state, checked: ambientCheckedAt, model: GlyphModel.apple.label), in: TerminalRect(2, footerY + 1, Self.whoWidth, 3))
        }
        if let review {
            canvas.text("REVIEW \(force ? "FORCE-STOP" : "GRACEFUL STOP") PID \(review.process.pid): \(review.name) | \(review.role)", x: 2, y: footerY + 1, width: w - 4, style: warning)
            canvas.text(review.path, x: 2, y: footerY + 2, width: w - 4)
            canvas.text(review.allowed ? "Isolated test: no children/sockets. Shared files or IPC may still be affected." : "BLOCKED: " + review.blockers.joined(separator: "; "), x: 2, y: footerY + 3, width: w - 4, style: warning)
            canvas.text(force ? "SIGKILL prevents cleanup. Separate confirmation; review expires in 60s." : "SIGTERM only this PID. No automatic escalation. Review expires in 60 seconds.", x: 2, y: footerY + 4, width: w - 4)
            let confirmLabel = review.allowed ? "Confirm stop" : "Blocked"
            let confirmRect = control(&canvas, confirmLabel, key: "y", x: 2, y: footerY + 5,
                                      limit: w - 2, color: review.allowed ? MengohPalette.warning : 0x777D86,
                                      enabled: review.allowed, register: false)
            reviewConfirmRect = review.allowed ? confirmRect : nil
            reviewCancelRect = control(&canvas, "Cancel", key: "n", x: 26, y: footerY + 5,
                                       limit: w - 2, register: false)
        } else if !expanded {
            canvas.markdown(ambientText, in: TerminalRect(insightX, footerY + 1, w - insightX - 2, 3), style: textInk)
            let selection = "SELECTED " + TerminalText.fit(selected.map { String($0.pid) } ?? "--", width: 10) + " | "
            canvas.text(selection, x: 2, y: footerY + 4, width: selection.count, style: dim)
            var x = 2 + selection.count
            for (label, key) in [(w >= 109 ? "Explain locally" : "Explain", "i"),
                                 (w >= 109 ? "Review process" : "Review", "r"),
                                 (w >= 109 ? "Saved observations" : "History", "h"), ("Chat", "c")] {
                if let rect = control(&canvas, label, key: key, x: x, y: footerY + 4, limit: w - 2,
                                      color: key == "i" ? MengohPalette.signal : 0xBCC0C6) { x += rect.width + 2 }
            }
        } else {
            let rows = footerHeight - 4
            canvas.markdown(insight, in: TerminalRect(insightX, footerY + 1, w - insightX - 2, rows), style: textInk, scroll: insightScroll)
            if let process = items.first(where: { $0.id == selected }) {
                canvas.text("SELECTED \(process.id.pid)  \(process.path)", x: 2, y: footerY + rows + 1, width: w - 4, style: dim)
            }
            canvas.text((working ? "Working... " : "") + notice, x: 2, y: footerY + rows + 2, width: w - 4, style: textInk)
            if insightTotal > rows {
                let position = " \(insightScroll + 1)-\(min(insightTotal, insightScroll + rows))/\(insightTotal)  [ ] scroll "
                canvas.text(position, x: w - position.count - 2, y: footerY + footerHeight - 1, width: position.count, style: dim)
            }
        }
        let elapsed = collectorMilliseconds
        canvas.text("\(persisted) | sample \(String(format: "%.0f", elapsed))ms | arrows/scroll select | click/tap controls", x: 1, y: height - 1, width: w - 2, style: dim)
        footerClock(&canvas, w: w, height: height)
        present(canvas)
    }

    /// The CPU/GPU panel. Its height is a parameter so the chat screen can show a shorter one.
    func renderSystemSummary(_ canvas: inout TerminalCanvas, w: Int, cpuHeight: Int) {
        let textInk = MengohPalette.foreground(0xBCC0C6), border = MengohPalette.foreground(0x4D535C)
        let cpuColor = MengohPalette.foreground(MengohPalette.moss), gpuColor = MengohPalette.foreground(MengohPalette.research)
        let dim = MengohPalette.foreground(0x999EA7)
        let cpu = TerminalRect(0, top, w, cpuHeight)
        canvas.box(cpu, title: "**CPU** \(percent(sample.cpu)) / \(sample.cores) cores", style: border, titleStyle: textInk, markdownTitle: true)
        let temperature = sample.cpuTemperature.map { String(format: "%.1f C", $0.hottestCelsius) } ?? "unavailable"
        let tempText = "CPU TEMP \(temperature)  \(sample.thermal.label)"
        canvas.text(tempText, x: max(30, w - tempText.count - 3), y: top, width: tempText.count, style: textInk)
        let split = max(28, w * 54 / 100)
        let graphWidth = split - 4
        let bandHeight = max(3, (cpuHeight - 2) / 2)
        func metric(_ label: String, _ subtitle: String, _ value: Double?, _ values: [Double?], _ y: Int, _ rows: Int, _ color: UInt32) {
            let gaugeWidth = graphWidth >= 48 ? 13 : 9
            let gaugeHeight = min(5, rows)
            canvas.gauge(value, in: TerminalRect(2, y + (rows - gaugeHeight) / 2, gaugeWidth, gaugeHeight), style: MengohPalette.foreground(color))
            let chartX = gaugeWidth + 4, chartWidth = split - chartX - 2
            canvas.markdownLabel("**" + label + "**  " + subtitle, x: chartX, y: y, width: chartWidth, style: textInk)
            canvas.chart(values, in: TerminalRect(chartX, y + 1, chartWidth, rows - 1), color: color)
        }
        metric("CPU", "whole machine", sample.cpu, history, top + 1, bandHeight, MengohPalette.signal)
        metric("GPU", "driver utilization", metrics.gpu, gpuHistory, top + 1 + bandHeight, cpuHeight - 2 - bandHeight, MengohPalette.research)
        let availableCoreRows = max(1, cpuHeight - 4)
        let coreColumns = max(1, Int(ceil(Double(sample.cores) / Double(availableCoreRows))))
        let coreRows = Int(ceil(Double(sample.cores) / Double(coreColumns)))
        let coreWidth = max(1, (w - split - 2) / coreColumns)
        for core in 0..<sample.cores {
            let col = core / coreRows, row = core % coreRows
            let x = split + col * coreWidth, y = top + 1 + row
            let value = sample.coreCPU.flatMap { core < $0.count ? $0[core] : nil }
            if coreWidth < 12 {
                canvas.text("C\(core) \(percent(value))", x: x, y: y, width: coreWidth, style: textInk)
                continue
            }
            canvas.text(String(format: "C%-2d", core), x: x, y: y, width: 4, style: dim)
            canvas.bar(value, x: x + 4, y: y, width: max(1, coreWidth - 10), style: cpuColor)
            canvas.text(percent(value), x: x + coreWidth - 5, y: y, width: 5, style: textInk)
        }
        if top + 1 + coreRows < top + cpuHeight - 3 {
            canvas.text("GPU", x: split, y: top + 1 + coreRows, width: 4, style: textInk)
            canvas.bar(metrics.gpu, x: split + 4, y: top + 1 + coreRows, width: w - split - 12, style: gpuColor)
            canvas.text(percent(metrics.gpu), x: w - 6, y: top + 1 + coreRows, width: 4, style: textInk)
        }
        if top + 2 + coreRows < top + cpuHeight - 3 {
            canvas.text("History: 2 samples/cell | \(history.count) collected", x: split, y: top + 2 + coreRows, width: w - split - 2, style: dim)
        }
        if top + 3 + coreRows < top + cpuHeight - 3 {
            let uptime = Int(ProcessInfo.processInfo.systemUptime)
            canvas.text("Uptime \(uptime / 86400)d \(uptime / 3600 % 24)h \(uptime / 60 % 60)m", x: split, y: top + 3 + coreRows, width: w - split - 2, style: dim)
        }
        canvas.text("Load " + metrics.load.map { String(format: "%.2f", $0) }.joined(separator: " "), x: split, y: top + cpuHeight - 3, width: w - split - 2, style: dim)
        canvas.text("GPU RAM \(bytesOptional(metrics.gpuMemory)) shared | NPU n/a", x: split, y: top + cpuHeight - 2, width: w - split - 2, style: textInk)
    }

    /// The rendered header carries no clock (an image on a row that repaints every second would be
    /// resent every second), so the time and renderer state move to the footer line.
    func footerClock(_ canvas: inout TerminalCanvas, w: Int, height: Int) {
        guard headerRendered else { return }
        let label = (ProcessInfo.processInfo.environment["TERM_PROGRAM"] == "WarpTerminal" ? "Warp" : "graphics") + (synchronizedOutput ? " sync" : "")
        let text = " \(label) | \(Date().formatted(date: .omitted, time: .standard)) "
        canvas.text(text, x: w - text.count - 1, y: height - 1, width: text.count, style: MengohPalette.foreground(0x999EA7))
    }
    static let whoWidth = 30
    /// Who is speaking in the intelligence panel: Glyph, the model behind it, and how fresh the read is.
    func whoCard(state: String, checked: Date?, model: String) -> HeaderCard {
        let fresh = checked.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        let rgb = paused ? MengohPalette.warning : state == "unavailable" || !sample.thermal.admitsWork ? MengohPalette.danger : MengohPalette.signal
        return HeaderCard(avatar: GlyphPortrait.data, name: "Glyph", handle: TerminalText.safe(model),
                          status: TerminalText.safe(state) + fresh, statusColor: rgb, detail: "", pills: [])
    }
    func headerCard() -> HeaderCard {
        let warm = !sample.thermal.admitsWork
        let state = paused ? "paused" : "live"
        let cadence = interval == 1 ? "every second" : "every \(Int(interval)) s"
        let view = chat.open ? "chat" : mode == .agents ? "agent view" : "system view"
        let working = agents.sessions.filter { $0.status == .working }.count
        var pills = [HeaderCard.Pill(view, MengohPalette.signal), HeaderCard.Pill(TerminalText.safe(glyphLabel) + " · Glyph", MengohPalette.research)]
        if !agents.sessions.isEmpty { pills.append(.init("\(agents.sessions.count) agents · \(working) working", MengohPalette.amber)) }
        pills.append(.init("thermal " + sample.thermal.label, warm ? MengohPalette.danger : MengohPalette.ion))
        return HeaderCard(avatar: GlyphPortrait.data, name: "Glyph", handle: "@quiet · " + QuietVersion.current,
            status: "\(state) · \(cadence) · " + TerminalText.safe(aiStatus.prefix(1).lowercased() + aiStatus.dropFirst()),
            statusColor: paused ? MengohPalette.warning : warm ? MengohPalette.danger : MengohPalette.signal,
            detail: TerminalText.safe(hardware).replacingOccurrences(of: " / ", with: " · ") + " · " + bytes(sample.ram) + " RAM", pills: pills)
    }

    /// One colour per kind of action, shared by every rendered button with that key.
    static let accents: [String: UInt32] = ["s": MengohPalette.ion, "/": MengohPalette.ion, "x": MengohPalette.ion, "i": MengohPalette.signal,
        "r": MengohPalette.amber, "y": MengohPalette.warning, "p": MengohPalette.iris, "q": MengohPalette.fault, "h": MengohPalette.research,
        "g": MengohPalette.signal, "c": MengohPalette.signal, "o": MengohPalette.research, "n": MengohPalette.ink300, "d": MengohPalette.ink300,
        "m": MengohPalette.ink300, "a": MengohPalette.ink300, "f": MengohPalette.research]

    // Panels draw only within their own interior. Small terminals retain controls and
    // current values; wider/taller terminals add breakdowns and history without overlap.
    @discardableResult
    func control(_ canvas: inout TerminalCanvas, _ label: String, key: String, x: Int, y: Int,
                         limit: Int, color: UInt32 = 0xBCC0C6, enabled: Bool = true, register: Bool = true, graphic: Bool = true) -> TerminalRect? {
        let span = label.count + 4
        guard x >= 0, y >= 0, y < canvas.height, x + span <= min(limit, canvas.width) else { return nil }
        let rect = TerminalRect(x, y, span, 1)
        canvas.fill(rect, style: "0")
        controlLabels.append("\(x),\(y),\(span),\(key),\(label)")
        // Graphics: the whole control is one rendered button. Text mode: character keycap and label.
        let accent: UInt32 = color == 0xBCC0C6 ? (Self.accents[key] ?? MengohPalette.ink300) : color
        if !(graphic && canvas.button(key, label: label, in: rect, accent: accent, enabled: enabled)) {
            canvas.keycap(key, x: x, y: y, foreground: enabled ? 0xE5E9EF : 0x777D86,
                          background: enabled ? 0x303640 : 0x20242A, graphic: false)
            canvas.markdownLabel("**" + label + "**", x: x + 4, y: y, width: label.count,
                                 style: MengohPalette.foreground(color))
        }
        if enabled && register { buttons.append((rect, key)) }
        return rect
    }
    func panel(_ canvas: inout TerminalCanvas, _ rect: TerminalRect, _ title: String,
                       controls: [(String, String)] = []) {
        let controlsWidth = controls.reduce(0) { $0 + $1.0.count + 4 } + max(0, controls.count - 1)
        var x = rect.x + rect.width - 2 - controlsWidth
        canvas.box(rect, title: "", style: MengohPalette.foreground(0x4D535C))
        canvas.markdownLabel(" " + title + " ", x: rect.x + 2, y: rect.y,
                             width: max(0, x - rect.x - 3), style: MengohPalette.foreground(0xBCC0C6))
        for (label, key) in controls {
            if let button = control(&canvas, label, key: key, x: x, y: rect.y, limit: rect.x + rect.width - 2) {
                x += button.width + 1
            }
        }
    }
    func renderMemory(_ canvas: inout TerminalCanvas, rect r: TerminalRect, compact: Bool) {
        panel(&canvas, r, "**MEMORY**", controls: compact ? [("Disks", "m")] : [])
        let x = r.x + 2, w = r.width - 4, end = r.y + r.height - 1
        var y = r.y + 1
        let total = Double(sample.ram)
        func fraction(_ value: UInt64?) -> Double? { value.flatMap { total > 0 ? Double($0) / total * 100 : nil } }
        func line(_ text: String) { if y < end { canvas.text(text, x: x, y: y, width: w); y += 1 } }
        line("Occupied \(bytesOptional(memoryAccounting.occupied)) / \(bytes(sample.ram))  \(percent(memoryAccounting.occupiedPercent))")
        if y < end { canvas.bar(memoryAccounting.occupiedPercent, x: x, y: y, width: w, style: MengohPalette.foreground(MengohPalette.moss)); y += 1 }
        let categories: [(String, UInt64?, UInt32)] = [
            ("Active", metrics.active, MengohPalette.moss),
            ("Wired", metrics.wired, MengohPalette.research),
            ("Compressed", metrics.compressed, MengohPalette.amber),
            ("Inactive", metrics.inactive, MengohPalette.iris),
            ("Other", memoryAccounting.other, MengohPalette.ion),
            ("Free pool", metrics.free, MengohPalette.ion)]
        if end - y >= 7 {
            for (name, value, color) in categories {
                let label = TerminalText.fit(name, width: 10) + " " + TerminalText.fit(bytesOptional(value), width: 6)
                canvas.text(label, x: x, y: y, width: 17)
                canvas.bar(fraction(value), x: x + 18, y: y, width: w - 18, style: MengohPalette.foreground(color)); y += 1
            }
        } else if end - y >= 4 {
            line("Active \(bytesOptional(metrics.active)) | wired \(bytesOptional(metrics.wired))")
            line("Compressed \(bytesOptional(metrics.compressed))")
            line("Inactive \(bytesOptional(metrics.inactive)) | free pool \(bytesOptional(metrics.free))")
        }
        line("Swap \(bytesOptional(metrics.swapUsed)) / \(bytesOptional(metrics.swapTotal))")
        if end - y >= 3 {
            line("Occupied history / scale 100%")
            canvas.chart(memoryHistory, in: TerminalRect(x, y, w, end - y - 1), color: MengohPalette.moss)
            canvas.text("Occupied is not pressure", x: x, y: end - 1, width: w, style: MengohPalette.foreground(0x999EA7))
        }
    }
    func renderDisks(_ canvas: inout TerminalCanvas, rect r: TerminalRect, compact: Bool) {
        panel(&canvas, r, "**DISKS**", controls: compact ? [("RAM", "m"), ("Next", "d")] : [("Next", "d")])
        let x = r.x + 2, w = r.width - 4, end = r.y + r.height - 1
        var y = r.y + 1
        let ioRows = r.height >= 12 ? max(5, r.height / 3) : (r.height >= 8 ? 2 : 0)
        let count = min(metrics.volumes.count, max(1, (end - y - ioRows) / 3))
        if metrics.volumes.isEmpty {
            canvas.text("No local volume data", x: x, y: y, width: w); y += 1
        } else {
            for index in 0..<count where y + 2 < end {
                let volume = metrics.volumes[(volumeIndex + index) % metrics.volumes.count]
                let used = volume.total > volume.free ? volume.total - volume.free : 0
                let value = volume.total > 0 ? Double(used) / Double(volume.total) * 100 : nil
                canvas.text("\(volume.name)  \(percent(value))", x: x, y: y, width: w); y += 1
                canvas.bar(value, x: x, y: y, width: w, style: MengohPalette.foreground(MengohPalette.amber)); y += 1
                canvas.text("\(bytes(volume.free)) free / \(bytes(volume.total))", x: x, y: y, width: w, style: MengohPalette.foreground(0x999EA7)); y += 1
            }
        }
        if end - y >= 2 {
            let graphRows = max(0, (end - y - 3) / 2)
            for (label, current, values, color) in [
                ("R", metrics.diskRead, diskReadHistory, MengohPalette.research),
                ("W", metrics.diskWrite, diskWriteHistory, MengohPalette.fault)] {
                let scale = max(1024, values.suffix(w * 2).compactMap { $0 }.max() ?? 0)
                canvas.text("\(label) \(rate(current))" + (graphRows > 0 ? " / \(rate(scale))" : " all drivers"), x: x, y: y, width: w); y += 1
                if graphRows > 0 {
                    canvas.chart(values, in: TerminalRect(x, y, w, graphRows), maximum: scale, color: color); y += graphRows
                }
            }
            if y < end {
                canvas.text("All drivers / auto-scale", x: x, y: end - 1, width: w, style: MengohPalette.foreground(0x999EA7))
            }
        }
    }

    func renderNetwork(_ canvas: inout TerminalCanvas, rect r: TerminalRect) {
        panel(&canvas, r, "**NET** \(TerminalMarkdown.literal(networkName ?? "n/a"))", controls: [("Next", "n")])
        guard let network = metrics.networks.first(where: { $0.name == networkName }) else {
            canvas.text("No interface data", x: r.x + 2, y: r.y + 1, width: r.width - 4); return
        }
        let values = networkHistory[network.name] ?? ([], [])
        let peaks = networkPeaks[network.name] ?? (0, 0)
        let sideBySide = r.width >= 64
        let laneWidth = sideBySide ? (r.width - 5) / 2 : r.width - 4
        let visibleRX = values.0.suffix(laneWidth * 2).compactMap { $0 }.max() ?? 0
        let visibleTX = values.1.suffix(laneWidth * 2).compactMap { $0 }.max() ?? 0
        let laneHeight = sideBySide ? r.height - 3 : (r.height - 3) / 2
        func lane(_ name: String, _ current: Double?, _ peak: Double, _ total: UInt64, _ history: [Double?], _ maximum: Double, _ x: Int, _ y: Int, _ color: UInt32) {
            let scale = max(1024, maximum)
            let style = MengohPalette.foreground(color)
            canvas.markdownLabel("**\(name)  \(rate(current))**" + (laneHeight == 3 ? " / \(rate(scale))" : ""), x: x, y: y, width: laneWidth, style: style)
            if laneHeight >= 3 {
                canvas.text("Peak \(rate(peak)) | total \(bytes(total))", x: x, y: y + 1, width: laneWidth, style: MengohPalette.foreground(0x999EA7))
                let chartY = laneHeight >= 4 ? y + 3 : y + 2
                if laneHeight >= 4 { canvas.text("Scale \(rate(scale))", x: x, y: y + 2, width: laneWidth, style: MengohPalette.foreground(0x999EA7)) }
                canvas.chart(history, in: TerminalRect(x, chartY, laneWidth, y + laneHeight - chartY), maximum: scale, color: color)
            } else if laneHeight == 2 {
                canvas.chart(history, in: TerminalRect(x, y + 1, laneWidth, 1), maximum: scale, color: color)
            }

        }
        lane("DOWN", network.download, peaks.0, network.received, values.0, sharedNetworkScale ? max(visibleRX, visibleTX) : visibleRX, r.x + 2, r.y + 1, MengohPalette.research)
        lane("UP", network.upload, peaks.1, network.sent, values.1, sharedNetworkScale ? max(visibleRX, visibleTX) : visibleTX, sideBySide ? r.x + 3 + laneWidth : r.x + 2, sideBySide ? r.y + 1 : r.y + 1 + laneHeight, MengohPalette.iris)
        if let button = control(&canvas, sharedNetworkScale ? "Shared" : "Independent", key: "a",
                                x: r.x + 2, y: r.y + r.height - 2, limit: r.x + r.width - 2) {
            let suffix = " auto-scale" + (sideBySide ? " | peak session; total interface" : "")
            canvas.text(suffix, x: button.x + button.width, y: button.y,
                        width: r.x + r.width - 2 - button.x - button.width, style: MengohPalette.foreground(0x999EA7))
        }
    }
    func present(_ canvas: TerminalCanvas) {
        // `QUIET_CONTROL_MAP` names a file that receives "x,y,width,key,label" per control.
        if let path = ProcessInfo.processInfo.environment["QUIET_CONTROL_MAP"], !path.isEmpty {
            let map = controlLabels.joined(separator: "\n")
            if map != controlMapWritten { try? map.write(toFile: path, atomically: true, encoding: .utf8); controlMapWritten = map }
        }
        let rows = canvas.ansiRows
        var update = pendingImageCleanup
        pendingImageCleanup = ""
        if oldRows.count != rows.count { update += warpGraphics.reset() + "\u{1b}[2J" }
        var redrawnRows: Set<Int> = []
        for (i, row) in rows.enumerated() where i >= oldRows.count || row != oldRows[i] {
            update += "\u{1b}[\(i + 1);1H" + row
            redrawnRows.insert(i)
        }
        if warpEnabled {
            update += warpGraphics.update(canvas.graphics, redrawnRows: redrawnRows)
            if paused { update += warpGraphics.animate(finish: true) }
        }
        outputFrame(update)
        oldRows = rows
    }
}
