import Darwin
import Foundation

public enum ComputeDevice: String, CaseIterable, Codable, Sendable {
    case cpu, gpu, auto
    public var label: String { switch self { case .cpu: "CPU"; case .gpu: "Metal GPU"; case .auto: "Measured auto" } }
    var layers: Int { self == .cpu ? 0 : 999 }
}

public struct LocalModel: Codable, Sendable, Identifiable, Equatable {
    public var name: String
    public var digest: String
    public var size: UInt64
    public var kind: String
    public var id: String { name }
}

public struct Placement: Codable, Sendable {
    public var model: String
    public var device: ComputeDevice
    public var gpuBytes: UInt64
    public var date = Date()
}

public struct InferenceResult: Codable, Sendable {
    public var model: String
    public var device: ComputeDevice
    public var milliseconds: Double
    public var output: String
    public var dimensions: Int?
    public var tokens: Int?
}

public struct Comparison: Codable, Sendable {
    public var model: String
    public var cpuMilliseconds: Double
    public var gpuMilliseconds: Double
    public var winner: ComputeDevice
    public var date = Date()
}

public struct RuntimeSnapshot: Codable, Sendable {
    public var installed: String? = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"].first { FileManager.default.isExecutableFile(atPath: $0) }
    public var running = false
    public var busy = false
    public var operation = "Stopped"
    public var endpoint: String?
    public var version: String?
    public var models: [LocalModel] = []
    public var excluded = 0
    public var requested: ComputeDevice?
    public var observed: Placement?
    public var result: InferenceResult?
    public var comparison: Comparison?
    public var error: String?
    public var events: [Activity] = []
    public init() {}
}

public enum RuntimeAction: Sendable {
    case start, stop
    case load(String, ComputeDevice)
    case run(String, ComputeDevice, String)
    case compare(String, String)
}

private struct ModelDetails: Decodable, Sendable { var format: String? }
private struct ModelRecord: Decodable, Sendable {
    var name: String?
    var model: String?
    var digest: String?
    var size: UInt64?
    var size_vram: UInt64?
    var remote_host: String?
    var remote_model: String?
    var details: ModelDetails?
    var capabilities: [String]?
    var local: Bool { details?.format == "gguf" && (remote_host ?? "").isEmpty && (remote_model ?? "").isEmpty && !(name ?? "").contains("cloud") }
    var kind: String? { capabilities?.contains("embedding") == true ? "embedding" : capabilities?.contains("completion") == true ? "completion" : nil }
}
private struct ModelList: Decodable, Sendable { var models: [ModelRecord] }
private struct Version: Decodable, Sendable { var version: String }
private struct Failure: Decodable { var error: String }
private struct ModelRequest: Encodable, Sendable { var model: String }
private struct InferenceOptions: Encodable, Sendable {
    var num_gpu: Int
    var num_thread = 2
    var num_ctx = 2048
    var num_predict = 128
    var temperature = 0
    var seed = 42
}
private struct InferenceRequest: Encodable, Sendable {
    var model: String
    var options: InferenceOptions
    var input: [String]?
    var prompt: String?
    var stream = false
    var think = false
    var truncate = false
    var keep_alive = "5m"
}
private struct InferenceResponse: Decodable, Sendable {
    var embeddings: [[Double]]?
    var response: String?
    var eval_count: Int?
}

private final class LocalSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public actor OllamaRuntime {
    private var view = RuntimeSnapshot()
    private let modelsDirectory: URL?
    private var child: OwnedProcess?
    private let session: URLSession
    private var generation: UInt64 = 0
    private var quiet = false
    private var selectedModel: String?
    private var stoppingTask: Task<Void, Never>?
    private struct Calibration { var model: LocalModel; var text: String; var winner: ComputeDevice }
    private var calibration: Calibration?
    public func ownedProcessGroup() -> Int32? { child?.pid }
    public init(modelsDirectory: URL? = nil) {
        self.modelsDirectory = modelsDirectory
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 125
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: LocalSessionDelegate(), delegateQueue: nil)
    }

    public func snapshot() -> RuntimeSnapshot { view }
    private func log(_ text: String) { view.events.insert(Activity(text), at: 0); view.events = Array(view.events.prefix(50)) }
    private func check(_ token: UInt64) throws { guard token == generation, !Task.isCancelled else { throw CancellationError() } }

    public func setQuiet(_ enabled: Bool) async {
        quiet = enabled
        if enabled { await stop() }
    }

    public func stop() async {
        if let stoppingTask { await stoppingTask.value; return }
        generation &+= 1
        let token = generation
        let owned = child
        child = nil
        view.running = false
        view.busy = true
        view.operation = "Stopping owned runtime"
        view.endpoint = nil; view.observed = nil; view.requested = nil
        view.result = nil; view.comparison = nil; calibration = nil; selectedModel = nil
        let cleanup = Task<Void, Never> { [self] in
            view.operation = "Stopping owned runtime"
            if let owned { await owned.terminate() }
        }
        stoppingTask = cleanup
        await cleanup.value
        stoppingTask = nil
        guard token == generation else { return }
        view.busy = false
        view.operation = "Stopped"
        view.error = nil
        if owned != nil { log("Stopped Quiet’s runtime and released its models. Existing Ollama server untouched.") }
    }

    public func perform(_ action: RuntimeAction) async throws -> RuntimeSnapshot {
        if case .stop = action { await stop(); return view }
        guard !quiet else { throw QuietError("Quiet mode holds inference. Select Observe or Balanced to run a model.") }
        guard !view.busy else { throw QuietError("Wait for the current request to finish, or stop Quiet’s runtime.") }
        view.busy = true; view.error = nil
        let token = generation
        defer { if token == generation { view.busy = false; view.operation = view.running ? "Ready" : "Stopped" } }
        do {
            switch action {
            case .start:
                view.operation = "Starting isolated runtime"
                try await start(token)
            case .stop: break
            case let .load(name, requested):
                view.operation = "Switching and verifying placement"
                let model = try await model(name, token)
                let device = try resolve(requested, model, nil)
                view.requested = requested; view.result = nil
                _ = try await infer(model, device, nil, token)
                log("\(name) switched to \(device.label); loaded-model placement verified.")
            case let .run(name, requested, text):
                try Self.validate(text)
                view.operation = "Running local inference"
                let model = try await model(name, token)
                let device = try resolve(requested, model, text)
                view.requested = requested; view.result = nil
                view.result = try await infer(model, device, text, token)
                log("\(name) completed on \(device.label). Input and output are not logged.")
            case let .compare(name, text):
                try Self.validate(text)
                let model = try await model(name, token)
                try await compare(model, text, token)
            }
            try check(token)
            var result = view; result.busy = false; result.operation = result.running ? "Ready" : "Stopped"
            return result
        } catch {
            if token == generation {
                view.error = error.localizedDescription
                log("Operation not completed: \(error.localizedDescription)")
                view.observed = nil
            }
            throw error
        }
    }

    private func call<Response: Decodable & Sendable>(_ path: String, body: Data? = nil, timeout: Double = 5, token: UInt64) async throws -> Response {
        try check(token)
        guard child?.poll() == nil, child != nil, let endpoint = view.endpoint, let url = URL(string: endpoint + "/api/" + path) else { throw QuietError("Start Quiet’s local runtime first.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { try check(token); throw QuietError("Local runtime /api/\(path): \(error.localizedDescription)") }
        try check(token)
        guard data.count <= 2 * 1024 * 1024 else { throw QuietError("Runtime response exceeds 2 MiB.") }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Local runtime rejected the request."
            throw QuietError(String(message.prefix(500)))
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func start(_ token: UInt64) async throws {
        guard !view.running else { throw QuietError("Quiet’s runtime is already running.") }
        guard let executable = view.installed else { throw QuietError("Install Ollama with Homebrew or in /Applications, then reopen Quiet.") }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw QuietError("Cannot reserve a loopback port.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        close(fd)
        guard bound == 0, named == 0 else { throw QuietError("Cannot allocate a loopback port.") }
        let port = UInt16(bigEndian: address.sin_port)
        var environment = localEnvironment()
        environment.merge(["OLLAMA_HOST": "127.0.0.1:\(port)", "OLLAMA_NO_CLOUD": "1", "OLLAMA_NUM_PARALLEL": "1", "OLLAMA_MAX_LOADED_MODELS": "1", "OLLAMA_CONTEXT_LENGTH": "2048", "OLLAMA_KEEP_ALIVE": "5m"]) { _, new in new }
        if let modelsDirectory { environment["OLLAMA_MODELS"] = modelsDirectory.path }
        child = try OwnedProcess(executable: executable, arguments: ["serve"], environment: environment, diagnosticLog: modelsDirectory?.appendingPathComponent("runtime-diagnostic.log").path)
        view.endpoint = "http://127.0.0.1:\(port)"
        do {
            var ownedListener = false
            for _ in 0..<60 {
                try check(token)
                guard let child, child.poll() == nil else { throw QuietError("Ollama exited during startup.") }
                if try Self.listenerOwned(pid: child.pid, port: port) { ownedListener = true; break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard ownedListener else { throw QuietError("Could not verify ownership of the runtime listener.") }
            let version: Version = try await call("version", timeout: 30, token: token)
            view.version = version.version
            view.running = true
            try await inventory(token)
            log("Started an isolated loopback Ollama runtime. Cloud disabled; \(view.models.count) compatible local models.")
        } catch {
            if token == generation { await stop() }
            throw error
        }
    }

    private static func listenerOwned(pid: Int32, port: UInt16) throws -> Bool {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", "\(pid)", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && String(decoding: data, as: UTF8.self).split(separator: "\n").contains("p\(pid)")
    }

    private func inventory(_ token: UInt64) async throws {
        let list: ModelList = try await call("tags", token: token)
        var models: [LocalModel] = []
        for entry in list.models where entry.local {
            guard let name = entry.name, let digest = entry.digest, !digest.isEmpty else { continue }
            let metadata: ModelRecord = try await call("show", body: JSONEncoder().encode(ModelRequest(model: name)), timeout: 10, token: token)
            guard metadata.local, let kind = metadata.kind else { continue }
            models.append(LocalModel(name: name, digest: digest, size: entry.size ?? 0, kind: kind))
        }
        view.models = models.sorted { $0.size < $1.size }
        view.excluded = list.models.count - models.count
    }

    private func model(_ name: String, _ token: UInt64) async throws -> LocalModel {
        guard let model = view.models.first(where: { $0.name == name }) else { throw QuietError("Choose an installed local embedding or completion model.") }
        let metadata: ModelRecord = try await call("show", body: JSONEncoder().encode(ModelRequest(model: name)), timeout: 10, token: token)
        let list: ModelList = try await call("tags", token: token)
        guard metadata.local, metadata.kind == model.kind,
              list.models.contains(where: { $0.local && $0.name == name && $0.digest == model.digest }) else { throw QuietError("Model contents or capabilities changed. Restart the runtime and compare again.") }
        return model
    }

    public func refresh() async {
        guard !view.busy, view.running else { return }
        let token = generation
        do {
            let list: ModelList = try await call("ps", timeout: 2, token: token)
            // Do not overwrite a placement while another operation started during this await.
            guard !view.busy, token == generation else { return }
            view.observed = try placement(list, selectedModel)
        } catch {
            guard !view.busy, token == generation else { return }
            view.observed = nil
            if child?.poll() != nil { view.running = false; view.operation = "Stopped"; view.endpoint = nil }
            view.error = error.localizedDescription
        }
    }

    private func placement(_ list: ModelList, _ name: String?) throws -> Placement? {
        guard let name, let record = list.models.first(where: { $0.name == name || $0.model == name }) else { return nil }
        guard let bytes = record.size_vram else { throw QuietError("Ollama did not report GPU allocation. Placement is unknown.") }
        return Placement(model: name, device: bytes == 0 ? .cpu : .gpu, gpuBytes: bytes)
    }

    private func infer(_ model: LocalModel, _ device: ComputeDevice, _ text: String?, _ token: UInt64) async throws -> InferenceResult? {
        try Self.admit(thermal: .current, comparison: false)
        guard device != .auto else { throw QuietError("Compare this input before using Measured auto.") }
        selectedModel = model.name; view.observed = nil
        let body = InferenceRequest(model: model.name, options: .init(num_gpu: device.layers),
                                    input: model.kind == "embedding" ? text.map { [$0] } ?? [] : nil,
                                    prompt: model.kind == "completion" ? text ?? "" : nil)
        let began = ContinuousClock.now
        let response: InferenceResponse
        do { response = try await call(model.kind == "embedding" ? "embed" : "generate", body: JSONEncoder().encode(body), timeout: 120, token: token) }
        catch {
            if token == generation { await stop() } // A timed-out request cannot overlap another switch.
            throw error
        }
        let duration = began.duration(to: .now).components
        let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        let list: ModelList = try await call("ps", token: token)
        let observed = try placement(list, model.name)
        view.observed = observed
        try Self.verify(observed: observed?.device, requested: device)
        guard text != nil else { return nil }
        if model.kind == "embedding" {
            guard let vector = response.embeddings?.first, !vector.isEmpty, vector.allSatisfy(\.isFinite) else { throw QuietError("Runtime returned an invalid embedding.") }
            return InferenceResult(model: model.name, device: device, milliseconds: milliseconds,
                                   output: String(decoding: try JSONEncoder().encode(vector), as: UTF8.self), dimensions: vector.count)
        }
        guard let output = response.response else { throw QuietError("Runtime returned no completion.") }
        return InferenceResult(model: model.name, device: device, milliseconds: milliseconds, output: output, tokens: response.eval_count)
    }

    private func resolve(_ requested: ComputeDevice, _ model: LocalModel, _ text: String?) throws -> ComputeDevice {
        guard requested == .auto else { return requested }
        guard let c = calibration, c.model == model, text == nil || text == c.text else { throw QuietError("Compare CPU / GPU for this exact model and input before using Measured auto.") }
        return c.winner
    }

    private func compare(_ model: LocalModel, _ text: String, _ token: UInt64) async throws {
        calibration = nil; view.comparison = nil; view.result = nil
        var medians: [Double] = []
        for device in [ComputeDevice.cpu, .gpu] {
            view.operation = "Comparing \(device.label) · warm-up + 3 requests"
            try Self.admit(thermal: .current, comparison: true)
            view.requested = device
            _ = try await infer(model, device, text, token)
            var samples: [Double] = []
            for _ in 0..<3 {
                try Self.admit(thermal: .current, comparison: true)
                guard let result = try await infer(model, device, text, token) else { throw QuietError("Missing comparison result.") }
                try Self.admit(thermal: .current, comparison: true)
                samples.append(result.milliseconds)
            }
            medians.append(samples.sorted()[1])
        }
        let winner = Self.winner(cpu: medians[0], gpu: medians[1])
        _ = try await infer(model, winner, nil, token)
        calibration = Calibration(model: model, text: text, winner: winner)
        view.requested = .auto
        view.comparison = Comparison(model: model.name, cpuMilliseconds: medians[0], gpuMilliseconds: medians[1], winner: winner)
        log("\(model.name): warm median CPU \(Int(medians[0])) ms / GPU \(Int(medians[1])) ms. Selected \(winner.label); energy not measured.")
    }

    public static func admit(thermal: ThermalLevel, comparison: Bool) throws {
        guard comparison ? thermal == .nominal : thermal.admitsWork else {
            throw QuietError(comparison ? "Comparison waits for nominal thermal pressure. Retry after recovery." : "Inference waits for thermal recovery. No automatic CPU fallback.")
        }
    }
    public static func verify(observed: ComputeDevice?, requested: ComputeDevice) throws {
        guard let observed, observed == requested, requested != .auto else { throw QuietError("Requested placement was not verified by Ollama.") }
    }
    public static func winner(cpu: Double, gpu: Double) -> ComputeDevice { cpu < gpu * 0.9 ? .cpu : .gpu }
    private static func validate(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 8000 else { throw QuietError("Enter 1–8,000 bytes of text.") }
    }
}
