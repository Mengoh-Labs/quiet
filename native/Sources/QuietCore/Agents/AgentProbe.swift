import Darwin
import Foundation

/// Facts about a same-user process that the sampler does not collect. Injected so the registry
/// can be tested without live processes.
public protocol AgentProbing: Sendable {
    func workingDirectory(_ pid: Int32) -> String?
    func openLogs(_ pid: Int32) -> [String]
    func script(_ pid: Int32) -> String?
    func ancestor(of pid: Int32) -> AgentAncestor?
}

public struct AgentAncestor: Sendable {
    public var pid: Int32, name: String, path: String
    public init(pid: Int32, name: String, path: String) { self.pid = pid; self.name = name; self.path = path }
}

public struct AgentProcessProbe: AgentProbing {
    public init() {}

    public func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// Paths of open regular files ending in `.jsonl`: how a harness without a pid file reveals its session.
    public func openLogs(_ pid: Int32) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let used = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }
        var result: [String] = []
        for descriptor in descriptors.prefix(Int(used) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if path.hasSuffix(".jsonl"), !result.contains(path) { result.append(path) }
        }
        return result
    }

    /// The parent process, readable even when it belongs to another user (`login` is root-owned).
    public func ancestor(of pid: Int32) -> AgentAncestor? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_ppid > 0 else { return nil }
        let parent = Int32(info.pbsi_ppid)
        var name = [CChar](repeating: 0, count: 256), path = [CChar](repeating: 0, count: 4096)
        proc_name(parent, &name, UInt32(name.count))
        proc_pidpath(parent, &path, UInt32(path.count))
        func string(_ chars: [CChar]) -> String { String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        return AgentAncestor(pid: parent, name: string(name), path: string(path))
    }

    /// Last path component of the first argument. Arguments are never returned whole: they can
    /// carry credentials, and only the script name is needed to recognise a script-hosted agent.
    public func script(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard count >= 2 else { return nil }
        var index = MemoryLayout<Int32>.size
        func skip(while predicate: (UInt8) -> Bool) { while index < size, predicate(buffer[index]) { index += 1 } }
        skip { $0 != 0 }; skip { $0 == 0 }   // executable path and its padding
        skip { $0 != 0 }; index += 1         // argv[0]
        // Skip interpreter flags such as `node --no-warnings script.js`.
        for _ in 1..<min(count, 6) {
            let start = index
            skip { $0 != 0 }
            let argument = String(decoding: buffer[start..<min(index, size)], as: UTF8.self)
            index += 1
            if argument.hasPrefix("-") { continue }
            let name = URL(fileURLWithPath: argument).lastPathComponent
            return name.isEmpty ? nil : String(name.prefix(64))
        }
        return nil
    }
}
