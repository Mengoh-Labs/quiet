import Darwin
import Foundation

/// Local OTLP/JSON LogsData. No network exporter or additional sampler.
public actor ObservationStore {
    public static var defaultDirectory: URL {
        QuietSupport.directory.appendingPathComponent("Telemetry", isDirectory: true)
    }
    public let directory: URL
    private let session = UUID().uuidString
    private var lastSnapshot: Double?
    private let byteLimit: Int
    public init(directory: URL = ObservationStore.defaultDirectory, byteLimit: Int = 64 * 1024 * 1024) {
        self.directory = directory; self.byteLimit = byteLimit
    }

    public func record(_ sample: Telemetry, hotspots: [Hotspot], contexts: [ProcessIdentity: DiagnosticContext],
                       mode: String, activeJobs: Int, ollamaBusy: Bool, nativeBusy: Bool,
                       uptime: Double = ProcessInfo.processInfo.systemUptime) throws -> Bool {
        if let lastSnapshot, uptime >= lastSnapshot, uptime - lastSnapshot < 15 { return false }
        var fields: [String: Any] = ["cpu.cores": sample.cores, "thermal.pressure": sample.thermal.label,
            "power.low": sample.lowPower, "process.unreadable": sample.unreadableProcesses,
            "process.readable": sample.processes.count, "sampler.duration_ms": sample.sampleMilliseconds,
            "care.mode": mode, "jobs.active": activeJobs, "ollama.busy": ollamaBusy, "native.busy": nativeBusy,
            "sample.failed": sample.error != nil]
        if let cpu = sample.cpu { fields["cpu.percent"] = cpu }
        if let gpu = sample.gpuPercent { fields["gpu.driver_percent"] = gpu }
        if let memory = sample.gpuMemory { fields["gpu.shared_memory_bytes"] = String(memory) }
        for (index, value) in (sample.coreCPU ?? []).enumerated() {
            if let value { fields["cpu.core.\(index).percent"] = value }
        }
        if let cpu = sample.processes.first(where: { $0.id.pid == getpid() })?.cpu { fields["quiet.cpu.percent"] = cpu }
        if let temperature = sample.cpuTemperature {
            fields["cpu.temperature_max_c"] = temperature.hottestCelsius
            fields["cpu.temperature_mean_c"] = temperature.averageCelsius
            fields["cpu.temperature_sensors"] = temperature.sensorCount
        }
        fields["process.top"] = sample.processes.sorted { ($0.cpu ?? -1) > ($1.cpu ?? -1) }.prefix(12).map { p -> [String: Any] in
            var row: [String: Any] = ["name": String(p.name.prefix(128)), "pid": Int(p.id.pid),
                "start_us": String(p.id.started), "memory_bytes": String(p.memory)]
            if let cpu = p.cpu { row["cpu.percent"] = cpu }
            return row
        }
        fields["hotspots"] = hotspots.prefix(8).map { h -> [String: Any] in
            ["name": String(h.name.prefix(128)), "pid": Int(h.id.pid), "start_us": String(h.id.started),
             "cpu.mean_percent": h.meanCPU, "duration_s": h.seconds, "samples": h.samples,
             "role": contexts[h.id]?.role ?? "Unknown"]
        }
        try append(event: "quiet.observation", fields: fields, at: sample.timestamp)
        lastSnapshot = uptime
        return true
    }

    /// Callers supply fixed action/outcome labels, never exception descriptions or user input.
    public func action(_ action: String, outcome: String, process: ProcessIdentity? = nil, at date: Date = Date()) throws {
        var fields: [String: Any] = ["action": action, "outcome": outcome]
        if let process { fields["pid"] = Int(process.pid); fields["start_us"] = String(process.started) }
        try append(event: "quiet.action", fields: fields, at: date)
    }

    private func append(event: String, fields: [String: Any], at date: Date) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directoryInfo = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard directoryInfo.isSymbolicLink != true, directoryInfo.isDirectory == true else { throw QuietError("Telemetry directory is not a regular directory.") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let stamp = String(UInt64(max(0, date.timeIntervalSince1970) * 1_000_000_000))
        let record: [String: Any] = ["timeUnixNano": stamp, "observedTimeUnixNano": stamp,
            "severityNumber": 9, "severityText": "INFO", "eventName": event, "body": Self.value(fields)]
        let envelope: [String: Any] = ["resourceLogs": [[
            "resource": ["attributes": [["key": "service.name", "value": ["stringValue": "quiet"]],
                ["key": "service.instance.id", "value": ["stringValue": session]]]],
            "scopeLogs": [["scope": ["name": "ai.quandrylabs.quiet.observations", "version": "1"], "logRecords": [record]]]
        ]]]
        var bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        bytes.append(10)
        guard bytes.count <= byteLimit else { throw QuietError("Telemetry record exceeds storage limit.") }
        let bucket = Int(date.timeIntervalSince1970 / 3600)
        let target = directory.appendingPathComponent("quiet-\(bucket).logs.jsonl")
        var files = try Self.files(in: directory)
        // Keep the current and previous 24 hour buckets (at most about 25 hours).
        for file in files where file.bucket < bucket - 24 {
            try fm.removeItem(at: file.url)
        }
        files = try Self.files(in: directory)
        var total = files.reduce(0) { $0 + $1.size }
        for file in files where total + bytes.count > byteLimit && file.url != target {
            try fm.removeItem(at: file.url); total -= file.size
        }
        guard total + bytes.count <= byteLimit else { throw QuietError("Telemetry storage cap reached; recording resumes after rotation.") }
        let fd = open(target.path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw QuietError("Cannot open local telemetry file (errno \(errno)).") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              flock(fd, LOCK_EX) == 0, fchmod(fd, 0o600) == 0 else { throw QuietError("Cannot secure local telemetry file.") }
        defer { flock(fd, LOCK_UN) }
        // A crash can leave a partial final line. Delimit it so subsequent records remain readable.
        if info.st_size > 0 {
            var last: UInt8 = 0
            guard pread(fd, &last, 1, info.st_size - 1) == 1 else { throw QuietError("Cannot inspect telemetry append boundary.") }
            if last != 10 {
                var newline: UInt8 = 10
                guard write(fd, &newline, 1) == 1 else { throw QuietError("Cannot repair telemetry append boundary.") }
            }
        }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw QuietError("Cannot write local telemetry (errno \(errno)).") }
                offset += count
            }
        }
    }

    private static func value(_ input: Any) -> [String: Any] {
        switch input {
        case let x as String: return ["stringValue": x]
        case let x as Bool: return ["boolValue": x]
        case let x as Int: return ["intValue": String(x)]
        case let x as Double: return x.isFinite ? ["doubleValue": x] : ["stringValue": "unavailable"]
        case let x as [String: Any]: return ["kvlistValue": ["values": x.keys.sorted().map { ["key": $0, "value": value(x[$0]!)] }]]
        case let x as [Any]: return ["arrayValue": ["values": x.map(value)]]
        default: return ["stringValue": "unavailable"]
        }
    }

    private struct StoredFile { var url: URL; var bucket: Int; var size: Int }
    private static func files(in directory: URL) throws -> [StoredFile] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]).compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("quiet-"), name.hasSuffix(".logs.jsonl"),
                  let bucket = Int(name.dropFirst(6).dropLast(11)) else { return nil }
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { return nil }
            return StoredFile(url: url, bucket: bucket, size: info.fileSize ?? 0)
        }.sorted { $0.bucket < $1.bucket }
    }

    /// Read-only, bounded, tolerant of an incomplete final append. Expired rows are filtered even while the app is closed.
    public static func history(directory: URL = defaultDirectory, hours: Double = 24, now: Date = Date()) throws -> String {
        guard hours > 0, hours <= 24 else { throw QuietError("History hours must be greater than zero and at most 24.") }
        let cutoff = now.addingTimeInterval(-hours * 3600).timeIntervalSince1970
        var rows: [[String: Any]] = []
        var skipped = 0
        var remaining = 64 * 1024 * 1024
        for file in try files(in: directory) where Double(file.bucket + 1) * 3600 >= cutoff {
            guard file.size <= remaining else { throw QuietError("Telemetry history exceeds the 64 MiB read limit.") }
            remaining -= file.size
            let data = try Data(contentsOf: file.url)
            for line in data.split(separator: 10) {
                guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let resources = root["resourceLogs"] as? [[String: Any]],
                      let scopes = resources.first?["scopeLogs"] as? [[String: Any]],
                      let records = scopes.first?["logRecords"] as? [[String: Any]] else { skipped += 1; continue }
                for record in records {
                    guard let stamp = record["timeUnixNano"] as? String, let nanos = Double(stamp) else { skipped += 1; continue }
                    let seconds = nanos / 1e9
                    guard seconds >= cutoff, seconds <= now.timeIntervalSince1970 else { continue }
                    rows.append(["timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds)),
                        "event": record["eventName"] as? String ?? "unknown", "fields": plain(record["body"] as? [String: Any] ?? [:])])
                }
            }
        }
        let result: [String: Any] = ["hours": hours, "records": rows, "skippedMalformedLines": skipped]
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
    private static func plain(_ value: [String: Any]) -> Any {
        for key in ["stringValue", "boolValue", "doubleValue", "intValue"] { if let x = value[key] { return x } }
        if let array = value["arrayValue"] as? [String: Any], let values = array["values"] as? [[String: Any]] { return values.map(plain) }
        if let list = value["kvlistValue"] as? [String: Any], let entries = list["values"] as? [[String: Any]] {
            var result: [String: Any] = [:]
            for entry in entries { if let key = entry["key"] as? String, let val = entry["value"] as? [String: Any] { result[key] = plain(val) } }
            return result
        }
        return NSNull()
    }
}
