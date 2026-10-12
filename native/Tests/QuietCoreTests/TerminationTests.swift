import Darwin
import Foundation
import Testing
@testable import QuietCore

@Test func terminationProtectsCriticalProcesses() {
    #expect(!ProcessTermination.protectionReasons(pid: 1, uid: 0, path: "/sbin/launchd", ownPID: 50, ownUID: 501).isEmpty)
    #expect(!ProcessTermination.protectionReasons(pid: 50, uid: 501, path: "/tmp/Quiet", ownPID: 50, ownUID: 501).isEmpty)
    #expect(!ProcessTermination.protectionReasons(pid: 51, uid: 502, path: "/tmp/bun", ownPID: 50, ownUID: 501).isEmpty)
    #expect(!ProcessTermination.protectionReasons(pid: 51, uid: 501, path: "/Library/Elastic/Endpoint/bun", ownPID: 50, ownUID: 501).isEmpty)
    #expect(!ProcessTermination.protectionReasons(pid: 51, uid: 501, path: "/System/Library/bun", ownPID: 50, ownUID: 501).isEmpty)
}

@Test func terminationRejectsSelfAndReusedIdentity() async throws {
    let controller = ProcessTermination()
    let current = try #require(NativeProcess.read(getpid())).id
    let review = try await controller.review(current)
    #expect(!review.allowed)
    await #expect(throws: QuietError.self) { try await controller.stop(review.id) }
    await #expect(throws: QuietError.self) { try await controller.review(.init(pid: current.pid, started: current.started + 1)) }
}

/// Actual signals are restricted to owned temporary Bun fixtures. No external workload is selected.
@Test func reviewedTestTerminationLive() async throws {
    let bun = "/opt/homebrew/bin/bun"
    guard FileManager.default.isExecutableFile(atPath: bun) else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-stop-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for mode in ["graceful", "ignore", "listener", "children"] {
        let marker = root.appendingPathComponent("ready")
        try? FileManager.default.removeItem(at: marker)
        let file = root.appendingPathComponent("fixture.test.js")
        let setup: String
        switch mode {
        case "ignore": setup = "process.on('SIGTERM', () => {});"
        case "listener": setup = "Bun.serve({port:0, fetch:() => new Response('fixture')});"
        case "children": setup = "Bun.spawn(['/bin/sleep', '60']);"
        default: setup = "process.on('SIGTERM', () => process.exit(0));"
        }
        try "import {test} from 'bun:test'; import {writeFileSync} from 'node:fs'; \(setup) writeFileSync('ready','ready'); test('fixture', async () => { await new Promise(r => setTimeout(r, 55000)); });".write(to: file, atomically: true, encoding: .utf8)
        let child = try OwnedProcess(executable: bun, arguments: ["test", "--timeout", "60000", file.path], environment: localEnvironment(), directory: root.path)
        do {
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(FileManager.default.fileExists(atPath: marker.path))
            let identity = try #require(child.identity)
            let controller = ProcessTermination()
            let review = try await controller.review(identity)
            if mode == "listener" || mode == "children" {
                #expect(!review.allowed)
                #expect(review.blockers.contains { $0.contains(mode == "listener" ? "Network sockets" : "child process") })
                await #expect(throws: QuietError.self) { try await controller.stop(review.id) }
                #expect(child.poll() == nil)
            } else {
                #expect(review.allowed)
                #expect(!review.canForce)
                // Force is denied until a confirmed graceful attempt times out.
                await #expect(throws: QuietError.self) { try await controller.stop(review.id, force: true) }
                let fresh = try await controller.review(identity)
                let result = try await controller.stop(fresh.id)
                if mode == "ignore" {
                    guard case .stillRunning = result else { throw QuietError("Fixture did not ignore SIGTERM") }
                    let force = try await controller.review(identity)
                    #expect(force.canForce && force.allowed)
                    let result = try await controller.stop(force.id, force: true)
                    guard case .exited = result else { throw QuietError("Fixture did not exit after SIGKILL") }
                } else {
                    guard case .exited = result else {
                        var info = proc_bsdinfo()
                        let count = proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
                        print("Fixture diagnostic pid=\(identity.pid) bsd=\(count) status=\(info.pbi_status) poll=\(String(describing: child.poll()))")
                        throw QuietError("Fixture did not exit after SIGTERM")
                    }
                }
                await #expect(throws: QuietError.self) { try await controller.stop(fresh.id) }
            }
            await child.terminate()
        } catch { await child.terminate(); throw error }
    }
}

@Test func processInventoryReadsChildrenSocketsAndArgumentsFromTheKernel() throws {
    // A child we own: `sh` holding a `sleep` child, with a recognisable argument list.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", "sleep 30 & wait", "marker-argument"]
    try child.run()
    defer { child.terminate(); child.waitUntilExit() }
    let pid = child.processIdentifier
    var grandchildren = 0
    for _ in 0..<100 where grandchildren == 0 { grandchildren = ProcessInventory.childCount(of: pid) ?? 0; usleep(20_000) }
    #expect(grandchildren == 1, "the shell's sleep is counted as its child")
    #expect((ProcessInventory.childCount(of: getpid()) ?? 0) >= 1, "and the shell is ours")
    #expect(ProcessInventory.arguments(of: pid, limit: 3) == ["/bin/sh", "-c", "sleep 30 & wait"])
    #expect(ProcessInventory.arguments(of: pid, limit: 9)?.last == "marker-argument")
    #expect(ProcessInventory.networkSockets(of: pid) == 0)
    // A listening TCP socket in this process is seen; a Unix-domain pair is not network exposure.
    let before = try #require(ProcessInventory.networkSockets(of: getpid()))
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    #expect(ProcessInventory.networkSockets(of: getpid()) == before)
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    #expect(listener >= 0 && ProcessInventory.networkSockets(of: getpid()) == before + 1)
    close(listener); close(pair[0]); close(pair[1])
    #expect(ProcessInventory.networkSockets(of: getpid()) == before)
    // Unknown stays unknown rather than reading as "none".
    #expect(ProcessInventory.networkSockets(of: 1) == nil, "another user's process cannot be inspected")
    #expect(ProcessInventory.arguments(of: 99_999_999, limit: 3) == nil)
}
