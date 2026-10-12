import Darwin
import Foundation

public enum CareMode: String, CaseIterable, Codable, Sendable {
    case observe = "Observe", balanced = "Balanced", quiet = "Quiet"
    public var detail: String {
        switch self {
        case .observe: "Jobs run normally. Existing apps stay untouched."
        case .balanced: "Thermal-aware admission and background scheduling for Quiet jobs."
        case .quiet: "Hold new jobs, background running Quiet jobs, and stop Quiet’s inference runtime."
        }
    }
}

public struct Activity: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var text: String
    public init(_ text: String) { self.text = text }
}

public struct JobRequest: Sendable {
    public var executable: String
    public var arguments: [String]
    public var directory: String
    public init(executable: String, arguments: [String], directory: String) {
        self.executable = executable; self.arguments = arguments; self.directory = directory
    }
}

public struct JobView: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var name: String
    public var state = "Queued"
    public var identity: ProcessIdentity?
    public var background = false
}

public struct QueueSnapshot: Sendable {
    public var mode = CareMode.observe
    public var jobs: [JobView] = []
    public var events: [Activity] = []
    public init() {}
}

public struct ThermalPolicy: Sendable {
    private var nominalSince: Double?
    public init() {}
    public mutating func decide(mode: CareMode, thermal: ThermalLevel, uptime: Double) -> Bool? {
        if mode == .observe { nominalSince = nil; return false }
        if mode == .quiet { nominalSince = nil; return true }
        if thermal == .serious || thermal == .critical { nominalSince = nil; return true }
        if thermal == .nominal {
            if nominalSince == nil { nominalSince = uptime }
            return uptime - (nominalSince ?? uptime) >= 30 ? false : nil
        }
        nominalSince = nil
        return nil
    }
}

public actor JobQueue {
    private struct Job { var view: JobView; var request: JobRequest; var child: OwnedProcess? }
    private var jobs: [Job] = []
    private var mode = CareMode.observe
    private var policy = ThermalPolicy()
    private var events: [Activity] = []
    private var recovery: [ProcessIdentity] = []
    private let journal: URL
    private var recovered = false
    public init(journal: URL) { self.journal = journal }

    private func log(_ text: String) { events.insert(Activity(text), at: 0); events = Array(events.prefix(100)) }
    public func snapshot() -> QueueSnapshot {
        var result = QueueSnapshot()
        result.mode = mode; result.jobs = jobs.map(\.view); result.events = events
        return result
    }

    private func persist(_ identities: [ProcessIdentity]) throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(identities)
        try data.write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }

    public func recover() {
        guard !recovered else { return }; recovered = true
        if let data = try? Data(contentsOf: journal), let ids = try? JSONDecoder().decode([ProcessIdentity].self, from: data) { recovery = ids }
        restoreRecovery()
    }

    private func restoreRecovery() {
        recovery = recovery.filter { id in
            guard NativeProcess.matches(id) else { return false }
            do { try NativeProcess.background(id, enabled: false); log("Recovered scheduling for PID \(id.pid)."); return false }
            catch { log("Could not restore PID \(id.pid): \(error.localizedDescription)"); return true }
        }
        try? persist(recovery)
    }

    public func setMode(_ value: CareMode) {
        mode = value
        log("\(value.rawValue) mode. \(value.detail)")
        if value == .observe { restoreAll() }
    }

    public func enqueue(_ request: JobRequest) throws {
        guard request.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: request.executable),
              request.directory.hasPrefix("/"), request.arguments.count <= 128,
              !request.arguments.contains(where: { $0.utf8.count > 8192 || $0.contains("\0") }),
              !request.executable.contains("\0"), !request.directory.contains("\0") else {
            throw QuietError("Use an absolute executable and directory, with at most 128 literal arguments.")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.directory, isDirectory: &directory), directory.boolValue else { throw QuietError("Working directory does not exist.") }
        guard jobs.filter({ $0.view.state == "Running" || $0.view.state == "Queued" }).count < 32 else { throw QuietError("The queue already contains 32 active jobs.") }
        let name = URL(fileURLWithPath: request.executable).lastPathComponent
        jobs.append(Job(view: JobView(name: name), request: request))
        log("Queued \(name). Arguments are not logged.")
    }

    public func remove(_ id: UUID) throws {
        guard let index = jobs.firstIndex(where: { $0.view.id == id && $0.view.state == "Queued" }) else { throw QuietError("Only queued jobs can be removed.") }
        jobs[index].view.state = "Removed"
    }

    private func background(_ index: Int, enabled: Bool) {
        guard jobs[index].view.background != enabled, let identity = jobs[index].view.identity else { return }
        do {
            if enabled {
                var next = recovery
                if !next.contains(identity) { next.append(identity) }
                try persist(next) // Journal before changing external scheduling.
                recovery = next
            }
            try NativeProcess.background(identity, enabled: enabled)
            jobs[index].view.background = enabled
            if !enabled { recovery.removeAll { $0 == identity }; try persist(recovery) }
            log("\(jobs[index].view.name): \(enabled ? "background scheduling accepted" : "normal scheduling restored").")
        } catch { log("\(jobs[index].view.name): \(error.localizedDescription)") }
    }

    public func tick(thermal: ThermalLevel, foreground: Int32 = 0) {
        recover()
        let decision = policy.decide(mode: mode, thermal: thermal, uptime: ProcessInfo.processInfo.systemUptime)
        for index in jobs.indices where jobs[index].view.state == "Running" {
            if let status = jobs[index].child?.poll() {
                jobs[index].view.state = status == 0 ? "Completed" : "Exited (\(status))"
                if let id = jobs[index].view.identity { recovery.removeAll { $0 == id } }
                jobs[index].view.background = false
                try? persist(recovery)
                log("\(jobs[index].view.name): \(jobs[index].view.state).")
            } else if jobs[index].view.identity?.pid == foreground { background(index, enabled: false) }
            else if let decision { background(index, enabled: decision) }
        }
        guard mode != .quiet, mode == .observe || thermal.admitsWork,
              !jobs.contains(where: { $0.view.state == "Running" }),
              let index = jobs.firstIndex(where: { $0.view.state == "Queued" }) else { return }
        do {
            let r = jobs[index].request
            let child = try OwnedProcess(executable: r.executable, arguments: r.arguments, environment: localEnvironment(), directory: r.directory)
            jobs[index].child = child
            jobs[index].view.identity = child.identity
            jobs[index].view.state = "Running"
            log("Started \(jobs[index].view.name), PID \(child.pid).")
        } catch { jobs[index].view.state = "Failed"; log(error.localizedDescription) }
        // Keep history bounded without dropping active jobs.
        if jobs.count > 100, let old = jobs.firstIndex(where: { $0.view.state != "Queued" && $0.view.state != "Running" }) { jobs.remove(at: old) }
    }

    public func restoreAll() {
        for index in jobs.indices where jobs[index].view.background { background(index, enabled: false) }
        restoreRecovery()
    }
}
