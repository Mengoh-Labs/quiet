import Foundation
import FoundationModels
import CoreML
import MLX
import MLXLLM
import MLXLMCommon
import QuietCore

public enum SiliconBackend: String, CaseIterable, Sendable, Identifiable {
    case apple = "Apple Intelligence", mlx = "MLX · Metal GPU", coreML = "Core ML · CPU + Neural Engine"
    public var id: String { rawValue }
}
public enum SiliconResponseStyle: Sendable, Equatable {
    case standard, observatory
    /// Caller-supplied instructions, for narration and chat.
    case guided(instructions: String, maximumTokens: Int)
    var instructions: String {
        switch self {
        case .standard: "Be concise and factual. Respond only to the user's request. You have no tools and cannot change system settings or control processes."
        case .observatory: ObservatoryPrompt.instructions
        case .guided(let instructions, _): instructions
        }
    }
    var maximumTokens: Int {
        switch self { case .standard: 128; case .observatory: 240; case .guided(_, let tokens): tokens }
    }
}
public struct SiliconResult: Sendable {
    public let backend: SiliconBackend
    public let model: String
    public let output: String
    public let milliseconds: Double
    public let loadMilliseconds: Double
    public let allocationBytes: Int?
    public let placement: String
}
public struct SiliconSnapshot: Sendable {
    public var busy = false
    public var status = "Ready when you are"
    public var loadedModel: String?
    public var result: SiliconResult?
    public var events: [Activity] = []
    public init() {}
}

/// Which model answers narration and chat. Apple's is the default; a pulled MLX model is opt-in.
public struct GlyphModel: Sendable, Equatable {
    public static let localPromptLimit = 20_000
    public static let apple = GlyphModel(backend: .apple, directory: nil, label: "Apple on-device", promptLimit: 5200)
    public let backend: SiliconBackend
    public let directory: URL?
    public let label: String
    /// UTF-8 bytes of prompt the model is given. Apple's context is roughly 4,000 tokens in total.
    public let promptLimit: Int
    public static func current(library: ModelLibrary = ModelLibrary()) -> GlyphModel {
        guard let entry = library.selected() else { return apple }
        return GlyphModel(backend: .mlx, directory: entry.directory, label: entry.name, promptLimit: localPromptLimit)
    }
}

/// One request at a time, with cancellation drained before model memory is released.
public actor SiliconRuntime {
    private let worker = SiliconWorker()
    private var pending: Task<SiliconResult, Error>?
    private var stopping = false
    private var generation: UInt64 = 0
    private var quiet = false
    private var state = SiliconSnapshot()
    private var lastUse = Date.distantPast
    public init() {}
    public func snapshot() -> SiliconSnapshot { state }
    public static func validate(prompt: String, quiet: Bool, thermal: ThermalLevel, limit: Int = 8000) throws {
        guard !quiet else { throw QuietError("Quiet mode holds local inference.") }
        guard thermal.admitsWork else { throw QuietError("Local inference is held until thermal pressure improves.") }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= limit else {
            throw QuietError("Enter between 1 and \(limit.formatted()) UTF-8 bytes.")
        }
    }
    public func run(backend: SiliconBackend, directory: URL?, prompt: String, responseStyle: SiliconResponseStyle = .standard) async throws -> SiliconResult {
        guard pending == nil, !stopping else { throw QuietError("Wait for the current request or stop it first.") }
        // A guided MLX request may carry a longer transcript than Apple's small context allows.
        let guided = if case .guided = responseStyle { true } else { false }
        try Self.validate(prompt: prompt, quiet: quiet, thermal: .current, limit: backend == .mlx && guided ? GlyphModel.localPromptLimit + 4000 : 8000)
        generation &+= 1
        let token = generation
        state.busy = true; state.status = "Running \(backend.rawValue)"; state.result = nil
        let worker = worker
        let task = Task { try await worker.run(backend: backend, directory: directory, prompt: prompt, responseStyle: responseStyle) }
        pending = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard token == generation, !stopping, !quiet else { throw CancellationError() }
            pending = nil; state.busy = false; state.result = result
            state.loadedModel = backend == .mlx ? result.model : nil
            state.status = "Request complete"; lastUse = Date()
            record("\(backend.rawValue): completed in \(Int(result.milliseconds)) ms. \(result.placement)")
            return result
        } catch {
            if token == generation && !stopping {
                await worker.release()
                guard token == generation, !stopping else { throw error }
                pending = nil; state.busy = false
                state.status = error is CancellationError ? "Cancelled" : "Request failed"
                state.loadedModel = nil
                record(error is CancellationError ? "Local request cancelled." : error.localizedDescription)
            }
            throw error
        }
    }
    public func stop() async {
        if stopping {
            while stopping { try? await Task.sleep(for: .milliseconds(25)) }
            return
        }
        generation &+= 1
        stopping = true; state.busy = true; state.status = "Stopping & releasing"
        let task = pending; task?.cancel()
        _ = try? await task?.value
        await worker.release()
        pending = nil; state.loadedModel = nil; state.busy = false
        state.status = "Stopped · Quiet model memory released"; stopping = false
        record("Quiet’s native request stopped; MLX weights and cache released. Apple manages its system model.")
    }
    public func setQuiet(_ value: Bool) async { quiet = value; if value { await stop() } }

    /// Narration and chat: use the selected local model, and fall back to Apple's model if it
    /// cannot load or run. `prompt` is rebuilt for the fallback because its budget is smaller.
    public func glyph(_ model: GlyphModel, instructions: String, maximumTokens: Int,
                      prompt: @Sendable (Int) -> String) async throws -> (result: SiliconResult, fallback: String?) {
        let style = SiliconResponseStyle.guided(instructions: instructions, maximumTokens: maximumTokens)
        guard model.backend == .mlx else {
            return (try await run(backend: .apple, directory: nil, prompt: prompt(GlyphModel.apple.promptLimit), responseStyle: style), nil)
        }
        do {
            return (try await run(backend: .mlx, directory: model.directory, prompt: prompt(model.promptLimit), responseStyle: style), nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let reason = "\(model.label) failed (\(error.localizedDescription)); used Apple's model."
            return (try await run(backend: .apple, directory: nil, prompt: prompt(GlyphModel.apple.promptLimit), responseStyle: style), reason)
        }
    }
    public func releaseIfIdle() async {
        if state.loadedModel != nil && pending == nil && !stopping && Date().timeIntervalSince(lastUse) > 300 { await stop() }
    }
    private func record(_ text: String) {
        state.events.insert(Activity(text), at: 0)
        state.events = Array(state.events.prefix(50))
    }
}

private actor SiliconWorker {
    private var model: ModelContainer?
    private var modelURL: URL?
    private var mlxInitialized = false
    func release() {
        model = nil; modelURL = nil
        if mlxInitialized { Memory.clearCache() }
    }
    func run(backend: SiliconBackend, directory: URL?, prompt: String, responseStyle: SiliconResponseStyle) async throws -> SiliconResult {
        try Task.checkCancellation()
        switch backend {
        case .apple:
            release()
            guard #available(macOS 26, *) else { throw QuietError("Apple Intelligence needs macOS 26 or later.") }
            guard SystemLanguageModel.default.isAvailable else { throw QuietError(SiliconHardware.read().appleStatus) }
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: responseStyle.instructions)
            let start = ContinuousClock.now
            let response = try await session.respond(to: prompt, options: GenerationOptions(
                temperature: 0, maximumResponseTokens: responseStyle.maximumTokens))
            try Task.checkCancellation()
            return SiliconResult(backend: backend, model: "Apple on-device system model", output: response.content,
                milliseconds: elapsed(start), loadMilliseconds: 0, allocationBytes: nil,
                placement: "Apple-managed on-device execution · processor placement not exposed")
        case .coreML:
            release()
            guard let directory, directory.isFileURL, directory.pathExtension == "mlmodelc" else {
                throw QuietError("Choose a compiled Core ML .mlmodelc model folder.")
            }
            let values = try JSONDecoder().decode([String: [Double]].self, from: Data(prompt.utf8))
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let loadStart = ContinuousClock.now
            let coreModel = try await MLModel.load(contentsOf: directory, configuration: configuration)
            let loadTime = elapsed(loadStart)
            let plan = await CoreMLPlacement.describe(directory: directory, configuration: configuration)
            try Task.checkCancellation()
            var features: [String: MLFeatureValue] = [:]
            let descriptions = coreModel.modelDescription.inputDescriptionsByName
            guard Set(values.keys) == Set(descriptions.keys) else {
                throw QuietError("Input JSON keys must match: \(descriptions.keys.sorted().joined(separator: ", ")).")
            }
            for (name, description) in descriptions {
                guard description.type == .multiArray, let constraint = description.multiArrayConstraint else {
                    throw QuietError("This Core ML runner supports fixed-shape numeric tensor inputs only.")
                }
                let shape = constraint.shape.map(\.intValue)
                guard !shape.isEmpty, shape.allSatisfy({ $0 > 0 && $0 <= 1_000_000 }),
                      shape.reduce(1.0, { $0 * Double($1) }) <= 1_000_000 else { throw QuietError("Unsupported or oversized input shape.") }
                let count = shape.reduce(1, *)
                guard let input = values[name], input.count == count, input.allSatisfy(\.isFinite) else {
                    throw QuietError("Input \(name) needs \(count) finite numbers for shape \(shape).")
                }
                let array = try MLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
                for (index, value) in input.enumerated() { array[index] = NSNumber(value: value) }
                features[name] = MLFeatureValue(multiArray: array)
            }
            let input = try MLDictionaryFeatureProvider(dictionary: features)
            let start = ContinuousClock.now
            let output = try await coreModel.prediction(from: input)
            try Task.checkCancellation()
            let milliseconds = elapsed(start)
            var lines: [String] = []
            for name in output.featureNames.sorted() {
                guard let value = output.featureValue(for: name) else { continue }
                if let tensor = value.multiArrayValue {
                    let preview = (0..<min(tensor.count, 64)).map { tensor[$0].doubleValue }
                    lines.append("\(name): shape \(tensor.shape), \(tensor.count) values; first \(preview.count): \(preview)")
                } else { lines.append("\(name): \(value)") }
            }
            return SiliconResult(backend: backend, model: directory.lastPathComponent, output: lines.joined(separator: "\n"),
                milliseconds: milliseconds, loadMilliseconds: loadTime, allocationBytes: nil,
                placement: plan)
        case .mlx:
            guard let selectedDirectory = directory, selectedDirectory.isFileURL else { throw QuietError("Choose a local MLX model folder first.") }
            guard Device.defaultDevice().deviceType == .gpu else { throw QuietError("MLX GPU backend is not selected.") }
            let directory = selectedDirectory.standardizedFileURL
            for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
                guard FileManager.default.isReadableFile(atPath: directory.appendingPathComponent(name).path) else {
                    throw QuietError("The MLX model folder is missing \(name). GGUF files need Ollama.")
                }
            }
            let loadStart = ContinuousClock.now
            var loadMilliseconds = 0.0
            if modelURL != directory || model == nil {
                release()
                mlxInitialized = true
                Memory.cacheLimit = 64 * 1024 * 1024
                model = try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
                modelURL = directory
                loadMilliseconds = elapsed(loadStart)
            }
            try Task.checkCancellation()
            guard let model else { throw QuietError("MLX model unavailable.") }
            let session = ChatSession(model, instructions: responseStyle == .standard ? nil : responseStyle.instructions,
                generateParameters: GenerateParameters(maxTokens: responseStyle.maximumTokens, temperature: 0),
                additionalContext: ["enable_thinking": false])
            let start = ContinuousClock.now
            let output: String
            do {
                output = try await session.respond(to: prompt)
                await session.synchronize()
            } catch {
                // Cancellation closes the consumer stream before its producer has
                // necessarily finished. Join MLX's cache owner before releasing weights.
                await session.synchronize()
                throw error
            }
            try Task.checkCancellation()
            return SiliconResult(backend: backend, model: directory.lastPathComponent, output: output,
                milliseconds: elapsed(start), loadMilliseconds: loadMilliseconds, allocationBytes: Memory.snapshot().activeMemory,
                placement: "MLX Metal backend · GPU-assisted execution; CPU tokenization")
        }
    }
    private func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: .now).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}
