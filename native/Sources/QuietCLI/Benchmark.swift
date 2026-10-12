import Darwin
import Foundation
import QuietCore
import QuietSilicon

/// Explicit opt-in, synthetic fixtures, owned runtimes only. No changes to the default Ollama store.
enum QuietBenchmark {
    struct Row: Codable {
        var backend: String; var round: Int; var fixture: Int
        var milliseconds: Double; var cpuSeconds: Double?
        var aggregateRSS: UInt64; var output: String
        var passesCheck: Bool; var thermalBefore: String; var thermalAfter: String
        var temperatureBefore: CPUTemperature?; var temperatureAfter: CPUTemperature?
        var reportedTokens: Int?; var loadMilliseconds: Double?
    }
    struct Report: Codable {
        var date = Date(); var model = "Qwen2.5-0.5B-Instruct"
        var mlxQuantization = "MLX affine 4-bit, group size 64"
        var ollamaQuantization = "GGUF Q4_K_M"
        var notes = "Practical shipping-path comparison, not identical quantization/templates or a runtime-only benchmark. Fresh MLX chat sessions; Ollama may reuse prompt prefixes. 128 output-token cap, greedy decoding, serial requests, warm-up excluded. Background workloads remain running. CPU seconds include benchmark process and owned Ollama group; Apple shared service CPU excluded, reported as null. RSS sums may double-count shared mappings. No watts or fan RPM measured."
        var rows: [Row] = []
        var warmups: [Row] = []
        var systemSamples: [Telemetry] = []
    }
    static let prompts = [
        "Extract the care mode from this sentence: The user chose Quiet mode. Reply with only the lowercase word quiet.",
        "Summarize in one short sentence: A compiler uses CPU while building code. A GPU can accelerate compatible neural networks. Moving arbitrary application processes to the GPU is not possible. Include the words CPU and GPU.",
        "Read these synthetic CPU percentages: alpha 15, beta 75, gamma 30. Return only the name of the process with the largest value."
    ]
    static func check(_ index: Int, _ output: String) -> Bool {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch index {
        case 0: return text == "quiet" || text == "quiet."
        case 1: return text.contains("cpu") && text.contains("gpu")
        default: return text == "beta" || text == "beta."
        }
    }
    static func seconds(_ duration: Duration) -> Double {
        let c = duration.components; return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
    static func run(output: URL) async throws {
        let root = QuietSupport.directory
        let folder = root.appendingPathComponent("Models/Qwen2.5-0.5B-Instruct-4bit")
        let native = SiliconRuntime()
        let ollama = OllamaRuntime(modelsDirectory: root.appendingPathComponent("BenchmarkOllama"))
        let sampler = Sampler()
        var report = Report()
        func save() throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(report).write(to: output, options: .atomic)
        }
        do {
            for round in 0..<2 {
                let order = round == 0 ? ["MLX GPU", "Ollama GPU", "Ollama CPU", "Apple on-device"] : ["Apple on-device", "Ollama CPU", "Ollama GPU", "MLX GPU"]
                for backend in order {
                    await native.stop(); await ollama.stop()
                    let deadline = Date().addingTimeInterval(60)
                    while !ThermalLevel.current.admitsWork && Date() < deadline { try await Task.sleep(for: .seconds(2)) }
                    guard ThermalLevel.current.admitsWork else { throw QuietError("Benchmark held by thermal pressure; partial results saved.") }
                    print("Round \(round + 1): \(backend)"); fflush(stdout)
                    if backend.hasPrefix("Ollama") { _ = try await ollama.perform(.start) }
                    // Separate warm-up loads weights and kernels before measured requests.
                    for index in -1..<prompts.count {
                        print("  Fixture \(index)"); fflush(stdout)
                        let prompt = index < 0 ? "Say hello in one short sentence." : prompts[index]
                        let group = await ollama.ownedProcessGroup()
                        let inventory = await sampler.sample()
                        let identities = inventory.processes.filter { $0.id.pid == getpid() || (group != nil && getpgid($0.id.pid) == group!) }.map(\.id)
                        let before = identities.compactMap { NativeProcess.read($0.pid) }.filter { identities.contains($0.id) }
                        let thermalBefore = ThermalLevel.current.label
                        let temperatureBefore = TemperatureReader.read()
                        let started = ContinuousClock.now
                        let text: String; let load: Double?; let tokens: Int?
                        if backend.hasPrefix("Ollama") {
                            let state = try await ollama.perform(.run("qwen2.5:0.5b-instruct-q4_K_M", backend == "Ollama GPU" ? .gpu : .cpu, prompt))
                            guard let result = state.result, state.observed?.device == (backend == "Ollama GPU" ? .gpu : .cpu) else { throw QuietError("Benchmark placement not verified.") }
                            text = result.output; tokens = result.tokens; load = nil
                        } else {
                            let result = try await native.run(backend: backend == "MLX GPU" ? .mlx : .apple, directory: folder, prompt: prompt)
                            text = result.output; tokens = nil; load = result.loadMilliseconds
                        }
                        let elapsed = seconds(started.duration(to: .now)) * 1000
                        let after = identities.compactMap { NativeProcess.read($0.pid) }.filter { identities.contains($0.id) }
                        let cpu = after.reduce(0.0) { total, process in
                            guard let previous = before.first(where: { $0.id == process.id }), process.cpuNanoseconds >= previous.cpuNanoseconds else { return total }
                            return total + Double(process.cpuNanoseconds - previous.cpuNanoseconds) / 1e9
                        }
                        let row = Row(backend: backend, round: round, fixture: index, milliseconds: elapsed,
                            cpuSeconds: backend == "Apple on-device" ? nil : cpu,
                            aggregateRSS: after.reduce(0) { $0 + $1.memory }, output: text,
                            passesCheck: index < 0 || check(index, text), thermalBefore: thermalBefore,
                            thermalAfter: ThermalLevel.current.label, temperatureBefore: temperatureBefore, temperatureAfter: TemperatureReader.read(), reportedTokens: tokens, loadMilliseconds: load)
                        if index < 0 { report.warmups.append(row) } else { report.rows.append(row) }
                        try save()
                    }
                    var sample = await sampler.sample()
                    sample.processes = [] // no unrelated process names/paths in the artifact
                    report.systemSamples.append(sample)
                    try save()
                }
            }
            await native.stop(); await ollama.stop()
            print("Benchmark complete: \(report.rows.count) measured requests. Owned runtimes stopped. \(output.path)")
        } catch { await native.stop(); await ollama.stop(); try? save(); throw error }
    }
}
