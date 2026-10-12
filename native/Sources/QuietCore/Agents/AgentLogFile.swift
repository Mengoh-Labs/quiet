import Darwin
import Foundation

/// Agent-controlled paths must not make an elevated observer read another user's
/// files or block on a pipe. Inspect the opened descriptor, never a preflight path.
final class AgentLogFile {
    let handle: FileHandle
    let size: UInt64
    let number: UInt64

    init?(_ path: String, owner: uid_t = InvokingUser.uid) {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == owner, info.st_size >= 0 else { close(descriptor); return nil }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        size = UInt64(info.st_size)
        number = UInt64(info.st_ino)
    }
    deinit { try? handle.close() }

    static func read(_ path: String, maximum: Int) -> Data? {
        guard maximum >= 0, maximum < Int.max, let file = AgentLogFile(path), file.size <= UInt64(maximum),
              let data = try? file.handle.read(upToCount: maximum + 1), data.count <= maximum else { return nil }
        return data
    }
}
