import Darwin
import Foundation
import Testing
@testable import QuietCore

private func logScratch() throws -> URL {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/security-logs-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func agentLogFilesRejectSymlinksPipesAndDifferentOwners() throws {
    let directory = try logScratch(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("session.jsonl")
    let bytes = Data("{\"type\":\"user\",\"message\":{\"content\":\"fixture\"}}\n".utf8)
    try bytes.write(to: file)
    #expect(AgentLogFile.read(file.path, maximum: 1024) == bytes)
    #expect(AgentLogFile.read(file.path, maximum: 4) == nil)
    #expect(AgentLogFile(file.path, owner: getuid() == 0 ? 1 : 0) == nil)
    #expect(AgentLogFile(directory.path) == nil)
    let link = directory.appendingPathComponent("linked.jsonl")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(AgentLogFile(link.path) == nil)
    var tail = SessionTail(path: link.path, parse: ClaudeCodeLog.parse)
    tail.read()
    #expect(tail.events.isEmpty)
    let fifo = directory.appendingPathComponent("pipe.jsonl")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(AgentLogFile.read(fifo.path, maximum: 1024) == nil, "must reject without waiting for a writer")
}

@Test func agentLogReadUsesOneDescriptorAcrossPathReplacement() throws {
    let directory = try logScratch(); defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("session.jsonl")
    let other = directory.appendingPathComponent("other.jsonl")
    try Data("original".utf8).write(to: path)
    try Data("replacement".utf8).write(to: other)
    let opened = try #require(AgentLogFile(path.path))
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: other)
    #expect(try opened.handle.readToEnd() == Data("original".utf8))
    #expect(opened.size == 8)
    #expect(AgentLogFile(path.path) == nil)
}
