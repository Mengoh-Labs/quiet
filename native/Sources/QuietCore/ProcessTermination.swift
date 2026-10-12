import Darwin
import Foundation

public struct TerminationReview: Identifiable, Sendable {
    public let id: UUID
    public let process: ProcessIdentity
    public let name: String
    public let path: String
    public let role: String
    public let blockers: [String]
    public let canForce: Bool
    public var allowed: Bool { blockers.isEmpty }
}

public enum TerminationResult: Sendable {
    case exited, stillRunning
}

/// Explicit, one-use review tickets. No automatic policy, process groups or elevated privileges.
public actor ProcessTermination {
    private var tickets: [UUID: (TerminationReview, Double)] = [:]
    private var forceUntil: [ProcessIdentity: Double] = [:]
    private var busy = false
    public init() {}

    public func review(_ identity: ProcessIdentity) throws -> TerminationReview {
        guard !busy else { throw QuietError("A stop is already in progress.") }
        let result = try inspect(identity)
        tickets = [result.id: (result, ProcessInfo.processInfo.systemUptime)]
        return result
    }

    public func stop(_ ticket: UUID, force: Bool = false) async throws -> TerminationResult {
        guard !busy, let (approved, created) = tickets.removeValue(forKey: ticket),
              ProcessInfo.processInfo.systemUptime - created <= 60 else { throw QuietError("Review expired or already used. Inspect the process again.") }
        busy = true; defer { busy = false }
        let current = try inspect(approved.process)
        guard approved.allowed, current.allowed, current.path == approved.path else {
            throw QuietError(current.blockers.first ?? "Process changed since review; no signal sent.")
        }
        guard !force || (approved.canForce && current.canForce) else { throw QuietError("Try graceful stop first, then review force-stop separately.") }
        // Final identity/path check immediately before signaling. Darwin has no PID-handle kill API.
        guard let fresh = NativeProcess.read(approved.process.pid), fresh.id == approved.process,
              fresh.path == approved.path, fresh.uid == getuid() else { throw QuietError("Process exited or changed. No signal sent.") }
        guard kill(approved.process.pid, force ? SIGKILL : SIGTERM) == 0 else { throw QuietError("Stop rejected by macOS (errno \(errno)).") }
        for _ in 0..<50 {
            // After a signal, finish observing even if the requesting UI goes away.
            try? await Task.sleep(for: .milliseconds(200))
            if exited(approved.process) {
                forceUntil[approved.process] = nil
                return .exited
            }
        }
        if !force { forceUntil[approved.process] = ProcessInfo.processInfo.systemUptime + 300 }
        return .stillRunning
    }

    private func exited(_ identity: ProcessIdentity) -> Bool {
        // proc_pidinfo can stop exposing task data before the parent reaps an exited child.
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, identity.pid]
        var kernel = kinfo_proc()
        var size = MemoryLayout.size(ofValue: kernel)
        if sysctl(&query, UInt32(query.count), &kernel, &size, nil, 0) == 0,
           size == MemoryLayout.size(ofValue: kernel), kernel.kp_proc.p_pid == identity.pid,
           kernel.kp_proc.p_stat == SZOMB { return true }
        var info = proc_bsdinfo()
        if proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) {
            let started = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
            return started != identity.started || info.pbi_status == 5 // exited, awaiting parent reaping
        }
        if let current = NativeProcess.read(identity.pid) { return current.id != identity }
        return kill(identity.pid, 0) == -1 && errno == ESRCH
    }

    private func inspect(_ identity: ProcessIdentity) throws -> TerminationReview {
        guard let process = NativeProcess.read(identity.pid), process.id == identity else { throw QuietError("Process exited or its PID was reused.") }
        var blockers = Self.protectionReasons(pid: identity.pid, uid: process.uid, path: process.path, ownPID: getpid(), ownUID: getuid())
        var ancestor = getppid()
        for _ in 0..<64 where ancestor > 1 {
            if ancestor == identity.pid { blockers.append("Quiet's parent/ancestor process is protected."); break }
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(ancestor, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd))) == MemoryLayout.size(ofValue: bsd), bsd.pbi_ppid != ancestor else { break }
            ancestor = Int32(bsd.pbi_ppid)
        }
        let context = blockers.isEmpty ? ProcessDiagnostics.inspect(identity) : nil
        if context?.role != "Test runner" { blockers.append("This release permits stopping recognized test runners only.") }
        if blockers.isEmpty {
            // Kernel queries, not external tools: a review must not depend on how quickly the
            // machine can start another process. Every probe still fails closed.
            guard let count = ProcessInventory.childCount(of: identity.pid) else { throw QuietError("Cannot verify child processes. No stop allowed.") }
            if count > 0 { blockers.append("\(count) child process(es) attached. Use the test runner's own controls.") }
            switch ProcessInventory.networkSockets(of: identity.pid) {
            case .some(0): break
            case .some: blockers.append("Network sockets are attached; service impact is uncertain.")
            case .none: blockers.append("Network isolation could not be verified.")
            }
        }
        guard NativeProcess.read(identity.pid)?.id == identity else { throw QuietError("Process changed during inspection.") }
        forceUntil = forceUntil.filter { $0.value > ProcessInfo.processInfo.systemUptime }
        return TerminationReview(id: UUID(), process: identity, name: process.name, path: process.path,
            role: context?.role ?? "Unverified", blockers: blockers, canForce: forceUntil[identity] != nil)
    }

    static func protectionReasons(pid: Int32, uid: UInt32, path: String, ownPID: Int32, ownUID: UInt32) -> [String] {
        var reasons: [String] = []
        if pid <= 1 || pid == ownPID { reasons.append("Quiet and essential process identities are protected.") }
        if uid == 0 || uid != ownUID { reasons.append("System and other users' processes are protected.") }
        let lower = path.lowercased()
        if path.isEmpty || path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") ||
            ["/library/systemextensions/", "/library/elastic/", "crowdstrike", "jamf", "osquery", "virtualization", "docker"].contains(where: lower.contains) {
            reasons.append("System, security and virtualization processes are protected.")
        }
        return reasons
    }
}

/// Read-only process facts straight from the kernel. `nil` always means "could not be determined".
public enum ProcessInventory {
    /// Direct children of `pid`, counted across every user's processes.
    public static func childCount(of pid: Int32) -> Int? {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: min(Int(estimate) + 512, 100_000))
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard found > 0 else { return nil }
        var count = 0
        for candidate in pids.prefix(min(Int(found), pids.count)) where candidate > 0 {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            // A process that exits during the scan has no parent to report; that is not a failure.
            guard proc_pidinfo(candidate, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { continue }
            if Int32(info.pbsi_ppid) == pid { count += 1 }
        }
        return count
    }

    /// Open IPv4/IPv6 sockets of `pid`. Local (Unix-domain) sockets are not network exposure.
    public static func networkSockets(of pid: Int32) -> Int? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 32)
        let used = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return nil }
        var count = 0
        for descriptor in descriptors.prefix(Int(used) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else {
                // Closed between the listing and this call: gone, so not exposure. Anything else is unknown.
                if errno == EBADF { continue }
                return nil
            }
            if info.psi.soi_family == AF_INET || info.psi.soi_family == AF_INET6 { count += 1 }
        }
        return count
    }

    /// The first `limit` command-line arguments (argv[0] first), each cut to 256 bytes.
    public static func arguments(of pid: Int32, limit: Int) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let count = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }      // executable path
        while index < size, buffer[index] == 0 { index += 1 }      // padding
        var result: [String] = []
        while result.count < min(count, limit), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<min(index, start + 256)], as: UTF8.self))
            index += 1
        }
        return result
    }
}
