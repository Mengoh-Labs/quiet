import Foundation
import QuietCore
import QuietSilicon

@main struct QuietCLI {
    static func main() async {
        do {
            let command = CommandLine.arguments.dropFirst().first ?? (isatty(STDIN_FILENO) == 1 ? "dashboard" : "sample")
            if command == "dashboard" || command == "top" {
                try await TerminalDashboard.run()
            } else if command == "--help" || command == "help" || command == "-h" {
                print("""
                Quiet — Apple silicon observatory
                quiet                     Interactive dashboard (TTY); JSON snapshot when piped
                quiet dashboard           Live CPU, temperature, RAM, network and process controls
                quiet sample              Machine/process snapshot as JSON
                quiet history [1–24]      App observation history as JSON
                quiet history 1 --terminal  Terminal observation history
                quiet explain             On-demand Apple Intelligence explanation, no control tools
                quiet agents [--json]     Running agent sessions: harness, directory, launcher, load
                quiet agents explain <pid>  On-device read of what one agent is doing (reads its session log)
                quiet models              Local MLX models for narration and chat: pull <owner/model>, use, remove
                quiet chat [clear]        Show or clear the saved chat history (the chat itself is c in the dashboard)
                quiet hardware            GPU, Neural Engine and Apple Intelligence availability
                quiet --version           Version

                Dashboard: arrows/j/k select, / filter, s sort CPU/RAM, i explain,
                r review selected process, y confirm, n/Esc cancel, h history, p pause, q quit.
                Agents: g or Tab switches to the agent view; o or Enter opens an agent's live
                stream (secrets masked), i narrates it, Esc closes. In the process view * marks
                agent processes, t lists them first, o opens the owning agent's stream.
                Chat: c opens a conversation with Glyph about this Mac and its agents. While it
                is open every key is text; Enter sends, Esc cancels or closes. On-device, no tools.
                Click/tap rows and controls in terminals supporting SGR mouse input.
                Graphics are detected automatically. QUIET_RENDERER=text keeps character rendering.
                Ambient on-device commentary follows the data. QUIET_AMBIENT=off disables it.
                Synchronized frames are detected automatically; QUIET_SYNC=off disables them.
                Only reviewed isolated test runners can be stopped. No automatic killing.
                """)
            } else if command == "agents" {
                let arguments = Array(CommandLine.arguments.dropFirst(2))
                if arguments.first == "explain" {
                    guard arguments.count == 2, let pid = Int32(arguments[1]) else { throw QuietError("Usage: quiet agents explain <pid>") }
                    try await AgentsCommand.explain(pid: pid)
                } else {
                    try await AgentsCommand.run(json: arguments.contains("--json"))
                }
            } else if command == "models" {
                try await ModelsCommand.run(Array(CommandLine.arguments.dropFirst(2)))
            } else if command == "chat" {
                try ChatCommand.run(Array(CommandLine.arguments.dropFirst(2)))
            } else if command == "--version" {
                print("Quiet \(QuietVersion.current)")
            } else if command == "explain" {
                let sampler = Sampler()
                var metrics = MachineMetrics(), window = ObservatoryWindow()
                let first = await sampler.sample()
                metrics.read(now: ProcessInfo.processInfo.systemUptime)
                window.observe(at: ProcessInfo.processInfo.systemUptime, values: ObservatoryEvidence.values(first, metrics))
                try await Task.sleep(for: .seconds(2))
                let sample = await sampler.sample()
                metrics.read(now: ProcessInfo.processInfo.systemUptime)
                window.observe(at: ProcessInfo.processInfo.systemUptime, values: ObservatoryEvidence.values(sample, metrics))
                let runtime = SiliconRuntime()
                do {
                    let context = ObservatoryEvidence.context(sample, metrics, window: window, hotspots: [])
                    let prompt = try ObservatoryPrompt.make(context, previous: nil, ambient: false)
                    let result = try await runtime.run(backend: .apple, directory: nil, prompt: prompt, responseStyle: .observatory)
                    var size = winsize()
                    _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
                    let ansi = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["TERM"] != "dumb"
                        && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
                    print(TerminalMarkdown.render("# Apple Intelligence - on-device, advisory\n" + result.output,
                                                  width: size.ws_col > 0 ? max(1, Int(size.ws_col) - 1) : 80, ansi: ansi))
                    await runtime.stop()
                } catch { await runtime.stop(); throw error }
            } else if command == "history" {
                let args = Array(CommandLine.arguments.dropFirst(2))
                guard args.count <= 2 else { throw QuietError("Usage: quiet history [hours: 1–24] [directory]") }
                let hours = args.first.flatMap(Double.init) ?? (args.isEmpty ? 24 : -1)
                let directory = args.count == 2 ? (args[1] == "--terminal" ? ObservationStore.defaultDirectory.appendingPathComponent("Terminal") : URL(fileURLWithPath: args[1])) : ObservationStore.defaultDirectory
                print(try ObservationStore.history(directory: directory, hours: hours))
            } else if command == "benchmark" {
                guard CommandLine.arguments.count == 3 else { throw QuietError("Usage: quiet benchmark /path/to/results.json") }
                try await QuietBenchmark.run(output: URL(fileURLWithPath: CommandLine.arguments[2]))
            } else if command == "hardware" {
                let h = SiliconHardware.read()
                print("Metal: \(h.gpuName); unified memory \(h.unifiedMemory); Neural Engine cores: \(h.neuralEngineCores)")
                print("Apple Intelligence: \(h.appleStatus)")
            } else if command == "verify-apple" || command == "verify-mlx" || command == "verify-coreml" {
                let runtime = SiliconRuntime()
                do {
                    let folder = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil
                    let result = try await runtime.run(backend: command == "verify-mlx" ? .mlx : command == "verify-coreml" ? .coreML : .apple, directory: folder, prompt: command == "verify-coreml" ? "{\"input\":[1,2,3,4]}" : "Say hello in one short sentence.")
                    guard !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw QuietError("Empty native response.") }
                    print("\(result.backend.rawValue): \(result.placement)")
                    print("Load \(result.loadMilliseconds) ms; request \(result.milliseconds) ms; allocations \(result.allocationBytes ?? 0)")
                    print(result.output)
                    if command == "verify-coreml" {
                        guard result.output.contains("[2.0, 3.0, 4.0, 5.0]") else { throw QuietError("Core ML known-answer check failed.") }
                    }
                    if command == "verify-mlx" {
                        let pending = Task { try await runtime.run(backend: .mlx, directory: folder, prompt: "Write a detailed numbered list of twenty ways to organize a desk.") }
                        while await runtime.snapshot().busy == false { try await Task.sleep(for: .milliseconds(1)) }
                        try await Task.sleep(for: .milliseconds(100))
                        async let stop: Void = runtime.stop()
                        async let quiet: Void = runtime.setQuiet(true)
                        _ = await (stop, quiet)
                        do { _ = try await pending.value; throw QuietError("Cancelled MLX request unexpectedly succeeded.") }
                        catch is CancellationError { print("In-flight MLX cancellation drained. PASS") }
                    }
                    await runtime.setQuiet(true)
                    guard await runtime.snapshot().loadedModel == nil else { throw QuietError("Weights not released.") }
                    do { _ = try await runtime.run(backend: .apple, directory: nil, prompt: "Hello"); throw QuietError("Quiet admitted work.") }
                    catch let e as QuietError { guard e.localizedDescription.contains("Quiet") else { throw e } }
                    print("Quiet rejects new work and releases native model. PASS")
                } catch { await runtime.stop(); throw error }
            } else if command == "sample" {
                let sampler = Sampler()
                _ = await sampler.sample()
                try await Task.sleep(for: .seconds(2))
                let sample = await sampler.sample()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(sample), as: UTF8.self))
            } else if command == "verify-switching" || command == "verify-auto" || command == "verify-stop" {
                let runtime = OllamaRuntime()
                do {
                    _ = try await runtime.perform(.start)
                    let name = "nomic-embed-text:latest"
                    let input = "search_document: Quiet verifies native Swift inference placement."
                    if command == "verify-switching" {
                        var vectors: [[Double]] = []
                        for device in [ComputeDevice.cpu, .gpu, .cpu] {
                            let loaded = try await runtime.perform(.load(name, device))
                            guard loaded.observed?.device == device else { throw QuietError("Load verification failed.") }
                            let result = try await runtime.perform(.run(name, device, input))
                            guard let run = result.result, run.dimensions == 768, result.observed?.device == device else { throw QuietError("Inference verification failed.") }
                            vectors.append(try JSONDecoder().decode([Double].self, from: Data(run.output.utf8)))
                            print("\(device.label): \(String(format: "%.2f", run.milliseconds)) ms; GPU allocation \(result.observed?.gpuBytes ?? 0); \(run.dimensions ?? 0) dimensions")
                        }
                        for vector in vectors.dropFirst() {
                            let dot = zip(vectors[0], vector).reduce(0) { $0 + $1.0 * $1.1 }
                            let norm = sqrt(vectors[0].reduce(0) { $0 + $1 * $1 }) * sqrt(vector.reduce(0) { $0 + $1 * $1 })
                            guard dot / norm > 0.999 else { throw QuietError("Cross-device embedding similarity check failed.") }
                        }
                        print("Cross-device cosine similarity > 0.999.")
                    } else if command == "verify-stop" {
                        let pending = Task { try await runtime.perform(.run(name, .gpu, input)) }
                        while await runtime.snapshot().busy == false { try await Task.sleep(for: .milliseconds(1)) }
                        async let quiet: Void = runtime.setQuiet(true)
                        async let stop: Void = runtime.stop()
                        _ = await (quiet, stop)
                        do { _ = try await pending.value; throw QuietError("Cancelled request unexpectedly succeeded.") }
                        catch is CancellationError { }
                        guard await runtime.snapshot().running == false else { throw QuietError("Concurrent stop did not finish.") }
                        print("Concurrent Quiet/Stop interrupted the pending request; runtime stopped. PASS")
                    } else {
                        let result = try await runtime.perform(.compare(name, input))
                        guard let comparison = result.comparison else { throw QuietError("No complete comparison.") }
                        let run = try await runtime.perform(.run(name, .auto, input))
                        guard run.observed?.device == comparison.winner else { throw QuietError("Measured selection mismatch.") }
                        print("CPU \(comparison.cpuMilliseconds) ms / GPU \(comparison.gpuMilliseconds) ms; selected \(comparison.winner.label)")
                    }
                    await runtime.stop()
                    guard await runtime.snapshot().running == false else { throw QuietError("Runtime did not stop.") }
                    print("Owned runtime stopped. PASS")
                } catch { await runtime.stop(); throw error }
            } else { throw QuietError("Usage: quiet history [hours] [directory] | hardware | sample | verify-apple | verify-mlx <folder> | verify-coreml <fixture.mlmodelc> | verify-switching | verify-auto | verify-stop") }
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
