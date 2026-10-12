import CryptoKit
import Foundation

public struct LocalModelEntry: Sendable, Equatable {
    public var name: String
    public var directory: URL
    public var bytes: UInt64
    public var repository: String?
}

public struct RemoteModelFile: Sendable, Equatable {
    public var path: String
    public var size: UInt64
    /// SHA-256 of the content for large (LFS) files, otherwise nil.
    public var sha256: String?
    /// Git blob id (SHA-1 over a `blob <size>\0` header and the content) for small files.
    public var blob: String?
}

/// The network half of a pull, injected so the planning and verification can be tested offline.
public protocol ModelFetching: Sendable {
    func data(_ url: URL) async throws -> Data
    func download(_ url: URL, to destination: URL) async throws
}

/// MLX models Quiet can load in-process, stored beside its other application data.
/// Downloads are explicit, pinned to one repository revision, and verified before they are usable.
public struct ModelLibrary: Sendable {
    public static let sizeLimit: UInt64 = 24 * 1024 * 1024 * 1024
    public static var defaultRoot: URL {
        QuietSupport.directory.appendingPathComponent("Models", isDirectory: true)
    }
    public let root: URL
    private var preference: URL { root.appendingPathComponent(".glyph-model.json") }
    public init(root: URL = ModelLibrary.defaultRoot) { self.root = root }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 96 && !name.hasPrefix(".")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
    public static func validRepository(_ repository: String) -> Bool {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { validName(String($0)) }
    }

    public func list() -> [LocalModelEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap { name -> LocalModelEntry? in
            guard Self.validName(name) else { return nil }
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else { return nil }
            var bytes: UInt64 = 0
            for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
                bytes += ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path)[.size]) as? NSNumber)?.uint64Value ?? 0
            }
            let source = (try? Data(contentsOf: directory.appendingPathComponent("quiet-source.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return LocalModelEntry(name: name, directory: directory, bytes: bytes, repository: source?["repository"] as? String)
        }
    }

    /// The model Glyph should use, or nil for Apple's on-device model. A selection whose folder
    /// has since been removed reads as nil rather than failing later at load time.
    public func selected() -> LocalModelEntry? {
        guard let data = try? Data(contentsOf: preference),
              let name = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["model"] as? String else { return nil }
        return list().first { $0.name == name }
    }
    public func select(_ name: String?) throws {
        guard let name else { try? FileManager.default.removeItem(at: preference); return }
        guard list().contains(where: { $0.name == name }) else { throw QuietError("No local model named \(name). Run quiet models to list them.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["model": name], options: [.sortedKeys]).write(to: preference, options: .atomic)
    }
    public func remove(_ name: String) throws {
        guard Self.validName(name), let entry = list().first(where: { $0.name == name }) else {
            throw QuietError("No local model named \(name).")
        }
        if selected()?.name == name { try select(nil) }
        try FileManager.default.removeItem(at: entry.directory)
    }

    /// Files an MLX language model needs, taken from the repository's top level only.
    public static func plan(tree: Data) throws -> [RemoteModelFile] {
        guard let items = try JSONSerialization.jsonObject(with: tree) as? [[String: Any]] else { throw QuietError("Unexpected repository listing.") }
        let wanted: Set<String> = ["json", "safetensors", "jinja", "txt", "model"]
        var files: [RemoteModelFile] = []
        var total: UInt64 = 0
        var paths: Set<String> = []
        for item in items where item["type"] as? String == "file" {
            guard let path = item["path"] as? String, !path.contains("/"), validName(path),
                  wanted.contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
                  let number = item["size"] as? NSNumber else { continue }
            guard let size = UInt64(number.stringValue), size <= sizeLimit - total, paths.insert(path).inserted else {
                throw QuietError("Repository file sizes exceed the model limit or the listing is invalid.")
            }
            total += size
            let lfs = (item["lfs"] as? [String: Any])?["oid"] as? String
            files.append(RemoteModelFile(path: path, size: size, sha256: lfs, blob: lfs == nil ? item["oid"] as? String : nil))
        }
        guard files.contains(where: { $0.path == "config.json" }), files.contains(where: { $0.path.hasSuffix(".safetensors") }),
              files.contains(where: { $0.path == "tokenizer.json" }) else {
            throw QuietError("That repository is not an MLX language model: it needs config.json, tokenizer.json and .safetensors weights. GGUF repositories are not supported.")
        }
        return files.sorted { $0.path < $1.path }
    }

    static func verify(_ file: RemoteModelFile, at url: URL) throws {
        let size = ((try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value
        guard size == file.size else { throw QuietError("\(file.path): size does not match the repository listing.") }
        guard let handle = FileHandle(forReadingAtPath: url.path) else { throw QuietError("\(file.path): cannot be read back.") }
        defer { try? handle.close() }
        var strong = SHA256(), blob = Insecure.SHA1()
        blob.update(data: Data("blob \(file.size)\u{0}".utf8))
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            if file.sha256 != nil { strong.update(data: chunk) } else { blob.update(data: chunk) }
        }
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
        if let expected = file.sha256 {
            guard hex(strong.finalize()) == expected.lowercased() else { throw QuietError("\(file.path): SHA-256 does not match the repository listing.") }
        } else if let expected = file.blob {
            guard hex(blob.finalize()) == expected.lowercased() else { throw QuietError("\(file.path): content does not match the repository listing.") }
        } else { throw QuietError("\(file.path): the repository listing has no digest to verify against.") }
    }

    /// Downloads into a hidden folder and renames it into place only after every file verifies.
    public func pull(repository: String, fetch: any ModelFetching, progress: @Sendable (String) -> Void = { _ in }) async throws -> LocalModelEntry {
        guard Self.validRepository(repository) else { throw QuietError("Use the form owner/model, for example mlx-community/Qwen2.5-0.5B-Instruct-4bit.") }
        let api = "https://huggingface.co/api/models/\(repository)"
        guard let info = try JSONSerialization.jsonObject(with: try await fetch.data(URL(string: api)!)) as? [String: Any],
              let revision = info["sha"] as? String, revision.count == 40, revision.allSatisfy(\.isHexDigit) else {
            throw QuietError("Could not read \(repository). Private and gated repositories are not supported.")
        }
        // Pin every request to one commit so the listing and the files cannot disagree.
        let files = try Self.plan(tree: try await fetch.data(URL(string: "\(api)/tree/\(revision)")!))
        let total = files.reduce(UInt64(0)) { $0 + $1.size }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let free = ((try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage).map(UInt64.init)
        if let free, free < total + 2 * 1024 * 1024 * 1024 { throw QuietError("Not enough free disk space for a \(total / 1_048_576) MiB model.") }
        let name = String(repository.split(separator: "/")[1])
        let final = root.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: final.path) else { throw QuietError("\(name) already exists. Remove it first with quiet models remove \(name).") }
        let partial = root.appendingPathComponent(".partial-" + name, isDirectory: true)
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                progress("[\(index + 1)/\(files.count)] \(file.path) (\(file.size / 1024) KiB)")
                let target = partial.appendingPathComponent(file.path)
                try await fetch.download(URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")!, to: target)
                try Self.verify(file, at: target)
            }
            let source: [String: Any] = ["repository": repository, "revision": revision, "files": files.map(\.path), "bytes": total]
            try JSONSerialization.data(withJSONObject: source, options: [.prettyPrinted, .sortedKeys])
                .write(to: partial.appendingPathComponent("quiet-source.json"))
            try FileManager.default.moveItem(at: partial, to: final)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        guard let entry = list().first(where: { $0.name == name }) else { throw QuietError("The model was downloaded but cannot be listed.") }
        return entry
    }
}

/// Talks only to Hugging Face: requests start at huggingface.co and may be redirected to its CDN.
public final class HuggingFaceFetcher: NSObject, ModelFetching, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    public override init() { super.init() }

    public static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host == "hf.co" || host.hasSuffix(".hf.co")
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.allowed(request.url) ? request : nil)
    }
    private func check(_ response: URLResponse, _ url: URL) throws {
        guard let http = response as? HTTPURLResponse else { throw QuietError("No HTTP response from \(url.host ?? "server").") }
        guard http.statusCode == 200 else {
            throw QuietError(http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 404
                ? "Hugging Face returned \(http.statusCode): the repository is missing, private or gated."
                : "Hugging Face returned HTTP \(http.statusCode).")
        }
    }
    public func data(_ url: URL) async throws -> Data {
        guard Self.allowed(url) else { throw QuietError("Refusing to contact \(url.host ?? "that host").") }
        let (data, response) = try await session.data(from: url)
        try check(response, url)
        guard data.count <= 8 * 1024 * 1024 else { throw QuietError("Repository listing is unexpectedly large.") }
        return data
    }
    public func download(_ url: URL, to destination: URL) async throws {
        guard Self.allowed(url) else { throw QuietError("Refusing to contact \(url.host ?? "that host").") }
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try check(response, url)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
