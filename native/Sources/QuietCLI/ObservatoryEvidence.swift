import Foundation
import QuietCore

enum ObservatoryEvidence {
    static func values(_ sample: Telemetry, _ metrics: MachineMetrics) -> [String: Double] {
        var result: [String: Double] = [:]
        func add(_ key: String, _ value: Double?) { if let value, value.isFinite { result[key] = value } }
        add("cpuPercent", sample.cpu); add("gpuPercent", metrics.gpu)
        add("cpuCelsius", sample.cpuTemperature?.hottestCelsius)
        add("ramOccupiedPercent", metrics.memoryAccounting(total: sample.ram).occupiedPercent)
        add("swapGiB", metrics.swapUsed.map { Double($0) / 1_073_741_824 })
        add("diskReadMiBps", metrics.diskRead.map { $0 / 1_048_576 })
        add("diskWriteMiBps", metrics.diskWrite.map { $0 / 1_048_576 })
        add("leastDiskFreePercent", metrics.volumes.filter { $0.total > 0 }.map { Double($0.free) / Double($0.total) * 100 }.min())
        // Keep interfaces separate: adding physical and tunnel traffic can double-count bytes.
        for network in metrics.networks.sorted(by: { ($0.download ?? 0) + ($0.upload ?? 0) > ($1.download ?? 0) + ($1.upload ?? 0) }).prefix(2) {
            let name = String(TerminalText.safe(network.name).prefix(24))
            add("network.\(name).downloadMiBps", network.download.map { $0 / 1_048_576 })
            add("network.\(name).uploadMiBps", network.upload.map { $0 / 1_048_576 })
        }
        return result
    }
    static func context(_ sample: Telemetry, _ metrics: MachineMetrics, window: ObservatoryWindow, hotspots: [Hotspot]) -> ObservatoryContext {
        func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "unknown" }
        func gib(_ value: UInt64?) -> String { number(value.map { Double($0) / 1_073_741_824 }) }
        func name(_ value: String) -> String { String(TerminalText.safe(value).prefix(64)) }
        let cpu = sample.processes.sorted { ($0.cpu ?? -1) > ($1.cpu ?? -1) }.prefix(4)
        let ram = sample.processes.sorted { $0.memory > $1.memory }.prefix(2)
        var seen: Set<ProcessIdentity> = []
        let processes = (Array(cpu) + Array(ram)).filter { seen.insert($0.id).inserted }.map {
            "\(name($0.name)) | PID \($0.id.pid) | CPU/core \(number($0.cpu))% | RAM \(gib($0.memory)) GiB"
        }
        var facts = ["cores": "\(sample.cores)", "ramTotalGiB": gib(sample.ram),
            "ramActiveGiB": gib(metrics.active), "ramWiredGiB": gib(metrics.wired),
            "ramCompressedGiB": gib(metrics.compressed), "ramInactiveGiB": gib(metrics.inactive), "ramFreePoolGiB": gib(metrics.free),
            "ramOccupiedGiB": gib(metrics.memoryAccounting(total: sample.ram).occupied),
            "ramOtherGiB": gib(metrics.memoryAccounting(total: sample.ram).other),
            "ramAccounting": "occupied = physical minus kernel free pool (includes speculative pages); inactive is occupied, not all file cache; other is an unclassified residual; occupancy is not memory pressure",
            "unreadableProcesses": "\(sample.unreadableProcesses)", "lowPowerMode": "\(sample.lowPower)",
            "gpuMemoryGiB": gib(metrics.gpuMemory), "unmeasured": "memory pressure, active swap I/O, fan speed, power, NPU utilization, per-process GPU utilization"]
        if metrics.load.count == 3 { facts["load1_5_15Minutes"] = metrics.load.map { number($0) }.joined(separator: ", ") }
        if let error = sample.error { facts["samplingError"] = String(TerminalText.safe(error).prefix(120)) }
        var context = ObservatoryContext(capturedAt: ISO8601DateFormatter().string(from: sample.timestamp), window: window,
            thermal: sample.thermal.label, facts: facts, processes: processes,
            sustained: hotspots.prefix(4).map { "\(name($0.name)) (\($0.id.pid):\($0.id.started)) | mean CPU/core \(number($0.meanCPU))% over \(Int($0.seconds))s, \($0.samples) samples" },
            volumes: metrics.volumes.prefix(4).map { "\(name($0.name)) | free \(gib($0.free)) / \(gib($0.total)) GiB" })
        let currentKeys = Set(values(sample, metrics).keys)
        context.trends = context.trends.filter { !$0.key.hasPrefix("network.") || currentKeys.contains($0.key) }
        return context
    }
}
