import Darwin
import Foundation

public struct Hotspot: Identifiable, Sendable {
    public var id: ProcessIdentity
    public var name: String
    public var path: String
    public var meanCPU: Double
    public var seconds: Double
    public var samples: Int
}

/// Bounded, session-local evidence. A PID restart or a long sampling gap starts fresh.
public struct HotspotDetector: Sendable {
    private struct Track: Sendable {
        var since: Double; var highSince: Double?; var last: Double
        var points: [(Double, Double)]
    }
    private var tracks: [ProcessIdentity: Track] = [:]
    public init() {}
    public mutating func ingest(_ processes: [ProcessSample], at now: Double) -> [Hotspot] {
        let candidates = processes.filter { ($0.cpu ?? 0) >= 20 }.sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) }.prefix(256)
        let live = Set(candidates.map(\.id))
        tracks = tracks.filter { live.contains($0.key) }
        var results: [Hotspot] = []
        for process in candidates {
            guard let cpu = process.cpu, cpu.isFinite else { continue }
            var track = tracks[process.id] ?? Track(since: now, highSince: nil, last: now, points: [])
            if now < track.last || now - track.last > 15 { track = Track(since: now, highSince: nil, last: now, points: []) }
            if cpu >= 50 { track.highSince = track.highSince ?? now } else { track.highSince = nil }
            track.points.append((now, cpu))
            track.points = Array(track.points.filter { now - $0.0 <= 90 }.suffix(40))
            track.last = now; tracks[process.id] = track
            let highDuration = track.highSince.map { now - $0 } ?? 0
            guard highDuration >= 30 || now - track.since >= 60 else { continue }
            let mean = track.points.reduce(0) { $0 + $1.1 } / Double(track.points.count)
            results.append(Hotspot(id: process.id, name: process.name, path: process.path, meanCPU: mean,
                                   seconds: now - track.since, samples: track.points.count))
        }
        return Array(results.sorted { $0.meanCPU > $1.meanCPU }.prefix(8))
    }
}

public struct DiagnosticContext: Sendable {
    public var workingDirectory: String?
    public var role: String
    public var parentPID: Int32?
    public var ageSeconds: Double
    public var recommendation: String
}

public enum ProcessDiagnostics {
    /// On-demand, user-owned processes only. Never reads environment or logs raw arguments.
    /// Command text is discarded after extracting an allowlisted runtime mode.
    public static func inspect(_ identity: ProcessIdentity) -> DiagnosticContext? {
        guard let process = NativeProcess.read(identity.pid), process.id == identity, process.uid == getuid() else { return nil }
        var bsd = proc_bsdinfo()
        let bsdCount = proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd)))
        let parent = bsdCount == MemoryLayout.size(ofValue: bsd) ? Int32(bsd.pbi_ppid) : nil
        var vnode = proc_vnodepathinfo()
        let count = proc_pidinfo(identity.pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout.size(ofValue: vnode)))
        let cwd: String? = count == MemoryLayout.size(ofValue: vnode) ? withUnsafeBytes(of: vnode.pvi_cdir.vip_path) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        } : nil
        let executable = URL(fileURLWithPath: process.path).lastPathComponent.lowercased()
        var role = "Application"
        var advice = "Inspect the app's active tasks. Sustained CPU alone does not establish wasted work."
        if ["bun", "node", "npm", "pnpm"].contains(executable) {
            // Only the first two positional tokens are considered; no arguments are retained.
            if let tokens = ProcessInventory.arguments(of: identity.pid, limit: 3) {
                role = classify(executable: executable, tokens: Array(tokens.dropFirst()))
            } else { role = "JavaScript runtime" }
            advice = role == "Test runner" ? "Inspect test progress and sample its stack. A long run may be stuck; CPU does not prove a loop. Stopping it requires a separate decision." : "Check active requests, rebuild activity and watcher scope. Multiple workers can be intentional; do not assume duplication."
        } else if process.path.contains("Virtualization") || process.path.contains("Docker") {
            role = "Virtual machine / containers"
            advice = "Inspect CPU inside the guest or container runtime to identify the workload. Host CPU cannot identify which guest service is responsible."
        } else if ["log", "tail", "bash", "zsh"].contains(executable) {
            role = "Shell / logging pipeline"
            advice = "Identify the parent job and measure log rate or repeated commands. Keep collection running while investigating."
        } else if process.path.contains("WebKit") || process.path.contains("Safari") {
            role = "Browser / web content"
            advice = "Check active tabs, rendering, media and extensions. This host process may serve more than one page."
        } else if ["quietapp", "quiet"].contains(executable) {
            role = "Quiet"
            advice = "Check sampling and view-update cost; monitor overhead should stay small."
        }
        guard NativeProcess.read(identity.pid)?.id == identity else { return nil }
        return DiagnosticContext(workingDirectory: cwd?.isEmpty == false ? cwd : nil, role: role, parentPID: parent,
            ageSeconds: max(0, Date().timeIntervalSince1970 - Double(identity.started) / 1_000_000), recommendation: advice)
    }
    static func classify(executable: String, tokens: [String]) -> String {
        if executable == "bun", tokens.first == "test" { return "Test runner" }
        if tokens.first == "run", tokens.dropFirst().first == "test" { return "Test runner" }
        if tokens.contains("dev") { return "Development server candidate" }
        return "JavaScript runtime"
    }
}
