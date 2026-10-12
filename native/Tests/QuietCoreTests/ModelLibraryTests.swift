import CryptoKit
import Foundation
import Testing
@testable import QuietCore
@testable import QuietSilicon

private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
private func blobID(_ data: Data) -> String { hex(Insecure.SHA1.hash(data: Data("blob \(data.count)\u{0}".utf8) + data)) }

/// Serves a fixture repository from memory and records every URL asked for.
private final class FakeHub: ModelFetching, @unchecked Sendable {
    let revision = String(repeating: "ab12", count: 10)
    var files: [String: Data] = [
        "config.json": Data("{\"model_type\":\"test\"}".utf8), "tokenizer.json": Data("{\"version\":\"1\"}".utf8),
        "model.safetensors": Data((0..<4096).map { UInt8($0 % 251) }), "README.md": Data("readme".utf8),
        "nested/extra.json": Data("{}".utf8), "vocab.txt": Data("a\nb\n".utf8)]
    var corrupt: String?
    var listingOverride: Data?
    private(set) var requested: [String] = []
    private let lock = NSLock()
    private func record(_ url: URL) { lock.lock(); requested.append(url.absoluteString); lock.unlock() }

    func data(_ url: URL) async throws -> Data {
        record(url)
        if url.path.hasSuffix("/tree/" + revision) {
            if let listingOverride { return listingOverride }
            return try JSONSerialization.data(withJSONObject: files.keys.sorted().map { path -> [String: Any] in
                let content = files[path]!
                var item: [String: Any] = ["type": "file", "path": path, "size": content.count, "oid": blobID(content)]
                if path.hasSuffix(".safetensors") { item["lfs"] = ["oid": hex(SHA256.hash(data: content)), "size": content.count] }
                return item
            } + [["type": "directory", "path": "nested", "size": 0, "oid": "x"]])
        }
        return try JSONSerialization.data(withJSONObject: ["sha": revision, "private": false])
    }
    func download(_ url: URL, to destination: URL) async throws {
        record(url)
        let path = url.path.components(separatedBy: "/resolve/\(revision)/").last ?? ""
        guard var content = files[path] else { throw QuietError("404 \(path)") }
        if path == corrupt { content[0] ^= 0xFF }
        try content.write(to: destination)
    }
}

private func scratch() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-models-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func modelPullVerifiesPinsAndInstallsAtomically() async throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let library = ModelLibrary(root: root), hub = FakeHub()
    let entry = try await library.pull(repository: "mlx-community/Tiny-4bit", fetch: hub)
    #expect(entry.name == "Tiny-4bit" && entry.repository == "mlx-community/Tiny-4bit")
    let installed = Set(try FileManager.default.contentsOfDirectory(atPath: entry.directory.path))
    #expect(installed == ["config.json", "tokenizer.json", "model.safetensors", "vocab.txt", "quiet-source.json"],
            "only top-level model files: no README, nothing from subfolders")
    #expect(hub.requested.allSatisfy { $0.hasPrefix("https://huggingface.co/") })
    #expect(hub.requested.filter { $0.contains("/resolve/") }.allSatisfy { $0.contains("/resolve/\(hub.revision)/") }, "every file comes from the pinned revision")
    #expect(library.list() == [entry])
    // A second pull must not overwrite an installed model.
    await #expect(throws: QuietError.self) { _ = try await library.pull(repository: "mlx-community/Tiny-4bit", fetch: hub) }
}

@Test func modelPullRejectsTamperedFilesAndLeavesNothingBehind() async throws {
    for target in ["model.safetensors", "tokenizer.json"] {   // one large (SHA-256) file, one small (blob id) file
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let hub = FakeHub(); hub.corrupt = target
        await #expect(throws: QuietError.self) { _ = try await ModelLibrary(root: root).pull(repository: "o/m", fetch: hub) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "a failed pull leaves no partial or usable model")
        #expect(ModelLibrary(root: root).list().isEmpty)
    }
}

@Test func modelPlanRequiresAnMLXLayoutAndValidNames() throws {
    func tree(_ names: [String]) -> Data {
        try! JSONSerialization.data(withJSONObject: names.map { ["type": "file", "path": $0, "size": 10, "oid": "aa"] })
    }
    #expect(throws: QuietError.self) { _ = try ModelLibrary.plan(tree: tree(["model.gguf", "README.md"])) }
    #expect(throws: QuietError.self) { _ = try ModelLibrary.plan(tree: tree(["config.json", "model.safetensors"])) }
    let files = try ModelLibrary.plan(tree: tree(["config.json", "tokenizer.json", "model.safetensors", "../evil.json", ".hidden.json", "a b.json", "chat_template.jinja"]))
    #expect(files.map(\.path) == ["chat_template.jinja", "config.json", "model.safetensors", "tokenizer.json"])
    let huge = try JSONSerialization.data(withJSONObject: [["type": "file", "path": "config.json", "size": 1, "oid": "a"],
        ["type": "file", "path": "tokenizer.json", "size": 1, "oid": "a"],
        ["type": "file", "path": "model.safetensors", "size": ModelLibrary.sizeLimit + 1, "oid": "a"]])
    #expect(throws: QuietError.self) { _ = try ModelLibrary.plan(tree: huge) }
    for good in ["mlx-community/Qwen2.5-0.5B-Instruct-4bit", "a/b"] { #expect(ModelLibrary.validRepository(good)) }
    for bad in ["nomodel", "a/b/c", "../x/y", "a/.b", "a b/c", "a/", "https://huggingface.co/a/b"] { #expect(!ModelLibrary.validRepository(bad)) }
}

@Test func modelSelectionFallsBackWhenTheFolderIsGone() async throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let library = ModelLibrary(root: root)
    #expect(library.selected() == nil && GlyphModel.current(library: library) == .apple)
    #expect(throws: QuietError.self) { try library.select("missing") }
    let entry = try await library.pull(repository: "o/Tiny", fetch: FakeHub())
    try library.select("Tiny")
    let model = GlyphModel.current(library: library)
    #expect(model.backend == .mlx && model.directory == entry.directory && model.promptLimit > GlyphModel.apple.promptLimit)
    // Removing the selected model clears the selection instead of leaving it dangling.
    try library.remove("Tiny")
    #expect(library.list().isEmpty && library.selected() == nil && GlyphModel.current(library: library) == .apple)
    #expect(throws: QuietError.self) { try library.remove("../Tiny") }
    // A selection that outlives its folder (deleted by hand) reads as Apple's model.
    _ = try await library.pull(repository: "o/Tiny", fetch: FakeHub())
    try library.select("Tiny")
    try FileManager.default.removeItem(at: root.appendingPathComponent("Tiny"))
    #expect(GlyphModel.current(library: library) == .apple)
    try library.select(nil)
}

@Test func modelDownloadsStayOnHuggingFaceHosts() {
    for url in ["https://huggingface.co/api/models/a/b", "https://us.aws.cdn.hf.co/x", "https://cdn-lfs.huggingface.co/y"] {
        #expect(HuggingFaceFetcher.allowed(URL(string: url)))
    }
    for url in ["http://huggingface.co/a", "https://evilhuggingface.co/a", "https://hf.co.evil.example/a", "https://example.com/a", "file:///etc/passwd"] {
        #expect(!HuggingFaceFetcher.allowed(URL(string: url)))
    }
    #expect(!HuggingFaceFetcher.allowed(nil))
}

@Test func modelPlanRejectsInvalidOverflowingAndDuplicateSizes() throws {
    func tree(_ size: NSNumber, duplicate: Bool = false) throws -> Data {
        var items: [[String: Any]] = [
            ["type": "file", "path": "config.json", "size": 2],
            ["type": "file", "path": "tokenizer.json", "size": 2],
            ["type": "file", "path": "model.safetensors", "size": size]
        ]
        if duplicate { items.append(items[0]) }
        return try JSONSerialization.data(withJSONObject: items)
    }
    for size in [NSNumber(value: -1), NSNumber(value: 1.5), NSNumber(value: UInt64.max), NSNumber(value: ModelLibrary.sizeLimit)] {
        let data = try tree(size)
        #expect(throws: QuietError.self) { _ = try ModelLibrary.plan(tree: data) }
    }
    let duplicate = try tree(2, duplicate: true)
    #expect(throws: QuietError.self) { _ = try ModelLibrary.plan(tree: duplicate) }
}
