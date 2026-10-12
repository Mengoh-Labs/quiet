import Darwin
import Foundation
import IOKit
import QuietCore

struct NetworkReading {
    var name: String
    var received: UInt64, sent: UInt64
    var download: Double?, upload: Double?
}
struct VolumeReading { var name: String; var total: UInt64; var free: UInt64 }

/// Native, unprivileged counters. No periodic shell commands and no model inference.
struct MachineMetrics {
    var active: UInt64?, wired: UInt64?, compressed: UInt64?, inactive: UInt64?, free: UInt64?
    var swapUsed: UInt64?, swapTotal: UInt64?
    var gpu: Double?, gpuMemory: UInt64?
    var load: [Double] = []
    var networks: [NetworkReading] = []
    var volumes: [VolumeReading] = []
    var diskRead: Double?, diskWrite: Double?
    private var previousNet: [String: (UInt64, UInt64)] = [:]
    private var previousDisk: [UInt64: (UInt64, UInt64)] = [:]
    private var lastTime: Double?
    private var volumeTime = -Double.infinity

    func memoryAccounting(total: UInt64) -> MemoryAccounting {
        MemoryAccounting(total: total, freePool: free, active: active, wired: wired,
                         compressed: compressed, inactive: inactive)
    }

    static func rate(_ old: UInt64?, _ new: UInt64, _ seconds: Double?) -> Double? {
        guard let old, new >= old, let seconds, seconds > 0 else { return nil }
        return Double(new - old) / seconds
    }
    mutating func read(now: Double) {
        let elapsed = lastTime.map { now - $0 }
        defer { lastTime = now }
        let host = mach_host_self(); defer { mach_port_deallocate(mach_task_self_, host) }
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &vm) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        active = nil; wired = nil; compressed = nil; inactive = nil; free = nil
        var pageSize: vm_size_t = 0
        if status == KERN_SUCCESS && host_page_size(host, &pageSize) == KERN_SUCCESS {
            let page = UInt64(pageSize)
            active = UInt64(vm.active_count) * page; wired = UInt64(vm.wire_count) * page
            compressed = UInt64(vm.compressor_page_count) * page
            inactive = UInt64(vm.inactive_count) * page; free = UInt64(vm.free_count) * page
        }
        var swap = xsw_usage(); var length = MemoryLayout.size(ofValue: swap)
        let swapOK = sysctlbyname("vm.swapusage", &swap, &length, nil, 0) == 0
        swapUsed = swapOK ? swap.xsu_used : nil; swapTotal = swapOK ? swap.xsu_total : nil
        var loadValues = [Double](repeating: 0, count: 3)
        load = getloadavg(&loadValues, 3) == 3 ? loadValues : []
        gpu = nil; gpuMemory = nil
        Self.registry("IOAccelerator", key: "PerformanceStatistics") { _, values in
            // Driver property, not a guaranteed macOS API. Never substitute availability or memory for utilization.
            if let n = values["Device Utilization %"] as? NSNumber, n.doubleValue.isFinite, (0...100).contains(n.doubleValue) {
                gpu = max(gpu ?? 0, n.doubleValue)
            }
            if let n = values["In use system memory"] as? NSNumber, n.int64Value >= 0 { gpuMemory = (gpuMemory ?? 0) + n.uint64Value }
        }
        networks = Self.networkCounters().map { name, values in
            let old = previousNet[name]
            return NetworkReading(name: name, received: values.0, sent: values.1,
                                  download: Self.rate(old?.0, values.0, elapsed), upload: Self.rate(old?.1, values.1, elapsed))
        }.sorted { $0.name < $1.name }
        previousNet = Dictionary(uniqueKeysWithValues: networks.map { ($0.name, ($0.received, $0.sent)) })
        var nextDisk: [UInt64: (UInt64, UInt64)] = [:]
        var reads: [Double] = [], writes: [Double] = []
        Self.registry("IOBlockStorageDriver", key: "Statistics") { id, values in
            guard let r = values["Bytes (Read)"] as? NSNumber, let w = values["Bytes (Write)"] as? NSNumber else { return }
            nextDisk[id] = (r.uint64Value, w.uint64Value)
            if let rate = Self.rate(previousDisk[id]?.0, r.uint64Value, elapsed) { reads.append(rate) }
            if let rate = Self.rate(previousDisk[id]?.1, w.uint64Value, elapsed) { writes.append(rate) }
        }
        diskRead = reads.isEmpty ? nil : reads.reduce(0, +); diskWrite = writes.isEmpty ? nil : writes.reduce(0, +)
        previousDisk = nextDisk
        if now - volumeTime >= 30 {
            // Show user-visible local volumes. APFS sibling volumes share capacity; never sum their capacities.
            let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsLocalKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
            let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
            volumes = urls.compactMap { url in
                guard let v = try? url.resourceValues(forKeys: keys), v.volumeIsLocal == true,
                      let total = v.volumeTotalCapacity, total > 0, let free = v.volumeAvailableCapacity else { return nil }
                return VolumeReading(name: v.volumeName ?? url.lastPathComponent, total: UInt64(total), free: UInt64(max(0, free)))
            }
            volumeTime = now
        }
    }
    private static func registry(_ name: String, key: String, consume: (UInt64, [String: Any]) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator); if service == 0 { break }
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                  let property = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let values = property as? [String: Any] else { continue }
            consume(id, values)
        }
    }
    private static func networkCounters() -> [String: (UInt64, UInt64)] {
        // NET_RT_IFLIST2 exposes 64-bit counters; getifaddrs' if_data uses wrapping 32-bit byte totals.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0, size < 16_777_216 else { return [:] }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &data, &size, nil, 0) == 0 else { return [:] }
        return data.withUnsafeBytes { buffer in
            var result: [String: (UInt64, UInt64)] = [:]; var offset = 0
            while offset + 4 <= size {
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, offset + length <= size else { break }
                if buffer[offset + 3] == UInt8(RTM_IFINFO2), length >= MemoryLayout<if_msghdr2>.size {
                    let info = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if info.ifm_flags & IFF_LOOPBACK == 0, if_indextoname(UInt32(info.ifm_index), &name) != nil {
                        let text = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        result[text] = (info.ifm_data.ifi_ibytes, info.ifm_data.ifi_obytes)
                    }
                }
                offset += length
            }
            return result
        }
    }
}
