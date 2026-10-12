import Darwin
import Foundation
import Testing
@testable import QuietCore

@Test func intervalAndThermalPolicy() throws {
    #expect(Sampler.cpuDelta(5_000_000_000, 9_000_000_000, 2) == 200)
    #expect(Sampler.cpuDelta(9, 5, 2) == nil)
    var policy = ThermalPolicy()
    #expect(policy.decide(mode: .balanced, thermal: .serious, uptime: 0) == true)
    #expect(policy.decide(mode: .balanced, thermal: .nominal, uptime: 1) == nil)
    #expect(policy.decide(mode: .balanced, thermal: .nominal, uptime: 30) == nil)
    #expect(policy.decide(mode: .balanced, thermal: .nominal, uptime: 31) == false)
    #expect(policy.decide(mode: .balanced, thermal: .fair, uptime: 32) == nil)
    #expect(policy.decide(mode: .quiet, thermal: .nominal, uptime: 33) == true)
    #expect(policy.decide(mode: .observe, thermal: .critical, uptime: 34) == false)
}

@Test func placementAndThermalAdmission() throws {
    try OllamaRuntime.verify(observed: .cpu, requested: .cpu)
    #expect(throws: QuietError.self) { try OllamaRuntime.verify(observed: .cpu, requested: .gpu) }
    #expect(throws: QuietError.self) { try OllamaRuntime.verify(observed: nil, requested: .cpu) }
    #expect(throws: QuietError.self) { try OllamaRuntime.admit(thermal: .critical, comparison: false) }
    #expect(throws: QuietError.self) { try OllamaRuntime.admit(thermal: .fair, comparison: true) }
    try OllamaRuntime.admit(thermal: .fair, comparison: false)
    #expect(OllamaRuntime.winner(cpu: 5, gpu: 10) == .cpu)
    #expect(OllamaRuntime.winner(cpu: 9.5, gpu: 10) == .gpu)
}

@Test func nativeCPUTimeMatchesPosixClock() throws {
    func clock() -> UInt64 {
        var value = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }
    let before = try #require(NativeProcess.read(getpid())).cpuNanoseconds
    let start = clock()
    while clock() - start < 30_000_000 {}
    let elapsed = clock() - start
    let after = try #require(NativeProcess.read(getpid())).cpuNanoseconds
    #expect((0.75...1.25).contains(Double(after - before) / Double(elapsed)))
}

@Test func ownedChildIdentityAndRestore() async throws {
    let child = try OwnedProcess(executable: "/bin/sleep", arguments: ["5"], environment: localEnvironment())
    do {
        let id = try #require(child.identity)
        #expect(getpgid(child.pid) == child.pid)
        try NativeProcess.background(id, enabled: true)
        try NativeProcess.background(id, enabled: false)
        #expect(throws: QuietError.self) { try NativeProcess.background(.init(pid: id.pid, started: id.started + 1), enabled: true) }
        await child.terminate()
        #expect(child.poll() != nil)
    } catch { await child.terminate(); throw error }
}

@Test func queueQuietAdmissionAndRealCompletion() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-test-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: path) }
    let queue = JobQueue(journal: path)
    await queue.setMode(.quiet)
    try await queue.enqueue(.init(executable: "/usr/bin/true", arguments: [], directory: "/tmp"))
    await queue.tick(thermal: .nominal)
    #expect(await queue.snapshot().jobs.first?.state == "Queued")
    await queue.setMode(.balanced)
    await queue.tick(thermal: .serious)
    #expect(await queue.snapshot().jobs.first?.state == "Queued")
    await queue.tick(thermal: .nominal)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await queue.snapshot().jobs.first?.state == "Running", ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
        await queue.tick(thermal: .nominal)
    }
    #expect(await queue.snapshot().jobs.first?.state == "Completed")
}

@Test func quietPreventsRuntimeStart() async throws {
    let runtime = OllamaRuntime()
    await runtime.setQuiet(true)
    await #expect(throws: QuietError.self) { try await runtime.perform(.start) }
    #expect(await runtime.snapshot().running == false)
}

@Test func journalFailureRefusesSchedulingChange() async throws {
    let queue = JobQueue(journal: URL(fileURLWithPath: "/dev/null/quiet-recovery.json"))
    try await queue.enqueue(.init(executable: "/bin/sleep", arguments: ["5"], directory: "/tmp"))
    await queue.tick(thermal: .nominal)
    let identity = try #require(await queue.snapshot().jobs.first?.identity)
    await queue.setMode(.quiet)
    await queue.tick(thermal: .nominal)
    #expect(await queue.snapshot().jobs.first?.background == false)
    #expect(await queue.snapshot().events.contains { $0.text.contains("/dev/null") || $0.text.contains("file") })
    if NativeProcess.matches(identity) { kill(identity.pid, SIGTERM) }
    try await Task.sleep(for: .milliseconds(100))
    await queue.tick(thermal: .nominal)
}

@Test func recoveryRestoresOnlyMatchingOwnedIdentity() async throws {
    let child = try OwnedProcess(executable: "/bin/sleep", arguments: ["5"], environment: localEnvironment())
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-recovery-test-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        let id = try #require(child.identity)
        try NativeProcess.background(id, enabled: true)
        let stale = ProcessIdentity(pid: id.pid, started: id.started + 1)
        try JSONEncoder().encode([id, stale]).write(to: url)
        let queue = JobQueue(journal: url)
        await queue.recover()
        let remaining = try JSONDecoder().decode([ProcessIdentity].self, from: Data(contentsOf: url))
        #expect(remaining.isEmpty)
        #expect(await queue.snapshot().events.filter { $0.text.contains("Recovered scheduling") }.count == 1)
        await child.terminate()
    } catch { await child.terminate(); throw error }
}

@Test func temperatureDecodingRejectsInvalidSensors() {
    #expect(TemperatureReader.decode([0, 0, 160, 66], type: "flt ") == 80)
    #expect(TemperatureReader.decode([80, 128], type: "sp78") == 80.5)
    #expect(TemperatureReader.decode([0, 0, 192, 127], type: "flt ") == nil)
    #expect(TemperatureReader.decode([0, 0, 0, 0], type: "flt ") == nil)
    #expect(TemperatureReader.decode([255, 0], type: "sp78") == nil)
    #expect(TemperatureReader.decode([80], type: "sp78") == nil)
}

private func diagnosticFixture(cpu: Double, started: UInt64 = 1) -> ProcessSample {
    ProcessSample(id: .init(pid: 123, started: started), name: "bun", path: "/opt/homebrew/bin/bun", uid: getuid(), cpuNanoseconds: 0, memory: 0, cpu: cpu)
}

@Test func sustainedDiagnosticsIgnoreSpikesAndPIDReuse() {
    var detector = HotspotDetector()
    for tick in stride(from: 0, to: 30, by: 3) {
        #expect(detector.ingest([diagnosticFixture(cpu: 100)], at: Double(tick)).isEmpty)
    }
    let finding = detector.ingest([diagnosticFixture(cpu: 100)], at: 30)
    #expect(finding.count == 1)
    #expect(finding.first?.meanCPU == 100)
    #expect(detector.ingest([diagnosticFixture(cpu: 100, started: 2)], at: 33).isEmpty)
    #expect(detector.ingest([diagnosticFixture(cpu: 100, started: 2)], at: 70).isEmpty)
    #expect(detector.ingest([diagnosticFixture(cpu: 0, started: 2)], at: 73).isEmpty)
}

@Test func sustainedModerateLoadAndExit() {
    var detector = HotspotDetector()
    for tick in stride(from: 0, to: 60, by: 6) {
        #expect(detector.ingest([diagnosticFixture(cpu: 25)], at: Double(tick)).isEmpty)
    }
    #expect(detector.ingest([diagnosticFixture(cpu: 25)], at: 60).count == 1)
    #expect(detector.ingest([], at: 66).isEmpty)
    #expect(detector.ingest([diagnosticFixture(cpu: 25)], at: 72).isEmpty)
}

@Test func diagnosticRolesUseExactModes() {
    #expect(ProcessDiagnostics.classify(executable: "bun", tokens: ["test"]) == "Test runner")
    #expect(ProcessDiagnostics.classify(executable: "bun", tokens: ["install"]) == "JavaScript runtime")
    #expect(ProcessDiagnostics.classify(executable: "node", tokens: ["contest.js"]) == "JavaScript runtime")
    #expect(ProcessDiagnostics.classify(executable: "npm", tokens: ["run", "test"]) == "Test runner")
}

@Test func supportDirectoryOverrideRequiresAnAbsoluteNonRootPath() {
    #expect(QuietSupport.storageDirectory(environment: ["QUIET_SUPPORT_DIR": "/Volumes/Test/quiet-fixture"]).path == "/Volumes/Test/quiet-fixture")
    let fallback = QuietSupport.storageDirectory(environment: [:])
    for path in ["", "relative", "/", "/.", "/Volumes/.."] {
        #expect(QuietSupport.storageDirectory(environment: ["QUIET_SUPPORT_DIR": path]) == fallback, "Invalid support path: \(path)")
    }
}
