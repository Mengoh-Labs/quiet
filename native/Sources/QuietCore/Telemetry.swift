import Darwin
import Foundation

public struct ProcessIdentity: Codable, Hashable, Sendable {
    public var pid: Int32
    public var started: UInt64
    public init(pid: Int32, started: UInt64) { self.pid = pid; self.started = started }
}

public struct ProcessSample: Codable, Identifiable, Sendable {
    public var id: ProcessIdentity
    public var name: String
    public var path: String
    public var uid: UInt32
    public var cpuNanoseconds: UInt64
    public var memory: UInt64
    public var cpu: Double?
    public var threads: Int? = nil
    public var parentPID: Int32? = nil
    public var category: String {
        let value = (name + path).lowercased()
        if ["ollama", "llama", "mlx", "inference"].contains(where: value.contains) { return "AI" }
        if ["bun", "node", "rustc", "cargo", "swift", "clang", "python", "rsync"].contains(where: value.contains) { return "Development" }
        if value.contains("virtualmachine") || value.contains("docker") { return "Virtual machine" }
        return "App / system"
    }
}

public enum ThermalLevel: Int, Codable, Sendable {
    case unknown = -1, nominal = 0, fair = 1, serious = 2, critical = 3
    public var label: String {
        switch self { case .unknown: "Unknown"; case .nominal: "Nominal"; case .fair: "Fair"; case .serious: "Serious"; case .critical: "Critical" }
    }
    public var admitsWork: Bool { self == .nominal || self == .fair }
    public static var current: Self { Self(rawValue: ProcessInfo.processInfo.thermalState.rawValue) ?? .unknown }
}

public struct Telemetry: Codable, Sendable {
    public var timestamp = Date()
    public var cpu: Double?
    public var cores = ProcessInfo.processInfo.activeProcessorCount
    public var ram = ProcessInfo.processInfo.physicalMemory
    public var thermal = ThermalLevel.current
    public var coreCPU: [Double?]? = nil
    public var gpuPercent: Double? = nil
    public var gpuMemory: UInt64? = nil
    public var cpuTemperature: CPUTemperature? = nil
    public var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    public var processes: [ProcessSample] = []
    public var unreadableProcesses = 0
    public var sampleMilliseconds = 0.0
    public var error: String?
    public init() {}
}

public enum NativeProcess {
    public static func read(_ pid: Int32) -> ProcessSample? {
        var info = proc_taskallinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        var path = [CChar](repeating: 0, count: 4096)
        proc_name(pid, &name, UInt32(name.count))
        proc_pidpath(pid, &path, UInt32(path.count))
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ptinfo.pti_total_user) + Double(info.ptinfo.pti_total_system)
        let ns = ticks * Double(timebase.numer) / Double(timebase.denom)
        func string(_ chars: [CChar]) -> String { String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        return ProcessSample(id: .init(pid: pid, started: info.pbsd.pbi_start_tvsec * 1_000_000 + info.pbsd.pbi_start_tvusec),
                             name: string(name), path: string(path), uid: info.pbsd.pbi_uid,
                             cpuNanoseconds: UInt64(ns), memory: info.ptinfo.pti_resident_size, threads: Int(info.ptinfo.pti_threadnum), parentPID: Int32(info.pbsd.pbi_ppid))
    }

    public static func matches(_ identity: ProcessIdentity) -> Bool {
        guard identity.pid > 1, identity.pid != getpid(), let current = read(identity.pid) else { return false }
        return current.id == identity && current.uid == getuid()
    }

    public static func background(_ identity: ProcessIdentity, enabled: Bool) throws {
        guard matches(identity) else { throw QuietError("Process exited, changed identity, or is not owned by this user.") }
        guard setpriority(PRIO_DARWIN_PROCESS, id_t(identity.pid), enabled ? PRIO_DARWIN_BG : 0) == 0 else {
            throw QuietError("Scheduling request rejected: \(String(cString: strerror(errno)))")
        }
    }
}

public struct QuietError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public actor Sampler {
    private var previous: [ProcessIdentity: UInt64] = [:]
    private var lastTime: UInt64?
    private var lastTicks: [UInt32]?
    private var lastCoreTicks: [[UInt32]]?
    public init() {}

    public func sample() -> Telemetry {
        let began = DispatchTime.now().uptimeNanoseconds
        var snapshot = Telemetry()
        snapshot.cpuTemperature = TemperatureReader.read()
        let elapsed = lastTime.map { Double(began - $0) / 1e9 }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { snapshot.error = "Process enumeration failed."; return snapshot }
        var pids = [Int32](repeating: 0, count: min(Int(count) + 512, 100_000))
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard found >= 0 else { snapshot.error = "Process enumeration failed."; return snapshot }
        var next: [ProcessIdentity: UInt64] = [:]
        for pid in pids.prefix(min(Int(found), pids.count)) where pid > 0 {
            guard var p = NativeProcess.read(pid) else { snapshot.unreadableProcesses += 1; continue }
            if let old = previous[p.id], let elapsed { p.cpu = Self.cpuDelta(old, p.cpuNanoseconds, elapsed) }
            next[p.id] = p.cpuNanoseconds
            snapshot.processes.append(p)
        }
        snapshot.processes.sort { ($0.cpu ?? -1) > ($1.cpu ?? -1) }
        previous = next
        lastTime = began
        if let ticks = Self.systemTicks() {
            if let old = lastTicks {
                let deltas = zip(ticks, old).map { UInt64($0 &- $1) }
                let total = deltas.reduce(0, +)
                if total > 0 { snapshot.cpu = Double(total - deltas[Int(CPU_STATE_IDLE)]) / Double(total) * 100 }
            }
            lastTicks = ticks
        }
        if let ticks = Self.coreTicks() {
            if let old = lastCoreTicks, old.count == ticks.count {
                snapshot.coreCPU = zip(old, ticks).map { Self.tickPercent(previous: $0, current: $1) }
            }
            lastCoreTicks = ticks
        }
        snapshot.sampleMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
        return snapshot
    }

    public static func cpuDelta(_ previous: UInt64, _ current: UInt64, _ seconds: Double) -> Double? {
        guard current >= previous, seconds > 0 else { return nil }
        return Double(current - previous) / 1e9 / seconds * 100
    }

    public static func tickPercent(previous: [UInt32], current: [UInt32]) -> Double? {
        guard previous.count == 4, current.count == 4 else { return nil }
        let delta = zip(current, previous).map { UInt64($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total) * 100
    }

    private static func coreTicks() -> [[UInt32]]? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var count: mach_msg_type_number_t = 0
        var cores: natural_t = 0
        var info: processor_info_array_t?
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cores, &info, &count) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(count) * MemoryLayout<integer_t>.size)) }
        guard cores > 0, cores <= 1024, Int(count) >= Int(cores) * 4 else { return nil }
        return (0..<Int(cores)).map { core in (0..<4).map { UInt32(bitPattern: info[core * 4 + $0]) } }
    }

    private static func systemTicks() -> [UInt32]? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }
}
