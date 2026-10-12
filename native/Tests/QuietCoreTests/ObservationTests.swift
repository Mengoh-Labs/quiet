import Foundation
import Testing
@testable import QuietCore

@Test func observationRoundTripAndPrivacy() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ObservationStore(directory: folder)
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var sample = Telemetry(); sample.timestamp = now; sample.cpu = 42.5; sample.cores = 16
    sample.cpuTemperature = CPUTemperature(hottestCelsius: 79, averageCelsius: 70, sensorCount: 16)
    let identity = ProcessIdentity(pid: 123, started: 456)
    sample.processes = [ProcessSample(id: identity, name: "bun", path: "/private/secret/bun", uid: 501, cpuNanoseconds: 0, memory: 1024, cpu: 99)]
    let hot = Hotspot(id: identity, name: "bun", path: "/private/secret/bun", meanCPU: 99, seconds: 60, samples: 20)
    let context = DiagnosticContext(workingDirectory: "/private/secret/project", role: "Test runner", parentPID: 1, ageSeconds: 9000, recommendation: "secret advice")
    let saved = try await store.record(sample, hotspots: [hot], contexts: [identity: context], mode: "Observe", activeJobs: 0, ollamaBusy: false, nativeBusy: false, uptime: 0)
    #expect(saved)
    let throttled = try await store.record(sample, hotspots: [], contexts: [:], mode: "Observe", activeJobs: 0, ollamaBusy: false, nativeBusy: false, uptime: 3)
    #expect(!throttled)
    try await store.action("process.stop", outcome: "exited", process: identity, at: now)
    let text = try ObservationStore.history(directory: folder, now: now)
    #expect(!text.contains("secret"))
    #expect(text.contains("Test runner"))
    #expect(text.contains("79"))
    let root = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    let rows = try #require(root["records"] as? [[String: Any]])
    #expect(rows.count == 2)
    let fields = try #require(rows.first?["fields"] as? [String: Any])
    #expect(fields["cpu.percent"] as? Double == 42.5)
    #expect(fields["cpu.cores"] as? String == "16")
    #expect(fields["power.low"] as? Bool == sample.lowPower)
    let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    let raw = try String(contentsOf: file, encoding: .utf8)
    #expect(raw.contains("resourceLogs")); #expect(raw.contains("timeUnixNano"))
}

@Test func observationRetentionRestartAndPartialWrite() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = ObservationStore(directory: folder)
    let old = Date(timeIntervalSince1970: 1_790_000_000)
    try await first.action("old", outcome: "completed", at: old)
    let unrelated = folder.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: unrelated)
    let now = old.addingTimeInterval(26 * 3600)
    let restarted = ObservationStore(directory: folder)
    try await restarted.action("new", outcome: "completed", at: now)
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    #expect(files.count == 2)
    let file = try #require(files.first { $0.pathExtension == "jsonl" })
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
    try handle.write(contentsOf: Data("{partial".utf8)); try handle.close()
    try await restarted.action("after_partial", outcome: "completed", at: now)
    let text = try ObservationStore.history(directory: folder, now: now)
    #expect(!text.contains("\"old\"")); #expect(text.contains("after_partial"))
    #expect(text.contains("\"skippedMalformedLines\" : 1"))
    #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep")
    let later = try ObservationStore.history(directory: folder, now: now.addingTimeInterval(25 * 3600))
    #expect(!later.contains("after_partial"))
}

@Test func observationFailureAndCap() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ObservationStore(directory: folder, byteLimit: 1)
    await #expect(throws: QuietError.self) { try await store.action("test", outcome: "completed") }
    let invalid = folder.appendingPathComponent("not-a-directory")
    try Data().write(to: invalid)
    let failed = ObservationStore(directory: invalid)
    await #expect(throws: (any Error).self) { try await failed.action("test", outcome: "completed") }
    #expect(throws: QuietError.self) { try ObservationStore.history(directory: folder, hours: 25) }
}
