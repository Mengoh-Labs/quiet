import Darwin
import Foundation

/// POSIX child with its own process group. No shell, inherited terminal, or credentials.
/// The owning actor serializes all access. Only an unreaped direct child can be signalled.
final class OwnedProcess {
    let pid: Int32
    let identity: ProcessIdentity?
    private(set) var status: Int32?

    init(executable: String, arguments: [String], environment: [String: String], directory: String? = nil, diagnosticLog: String? = nil) throws {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else { throw QuietError("Executable must be an existing absolute path.") }
        var attr: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attr)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawnattr_destroy(&attr); posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attr, 0)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGQUIT, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        if let diagnosticLog {
            posix_spawn_file_actions_addopen(&actions, 2, diagnosticLog, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        }
        if let directory {
            guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory) else { throw QuietError("Choose an existing absolute working directory.") }
            let result = posix_spawn_file_actions_addchdir_np(&actions, directory)
            guard result == 0 else { throw QuietError("Cannot use that working directory.") }
        }
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp = environment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.compactMap { $0 }.forEach { free($0) }; envp.compactMap { $0 }.forEach { free($0) } }
        var child: Int32 = 0
        let result = posix_spawn(&child, executable, &actions, &attr, &argv, &envp)
        guard result == 0 else { throw QuietError("Launch failed: \(String(cString: strerror(result)))") }
        pid = child
        identity = NativeProcess.read(child)?.id
    }

    @discardableResult func poll() -> Int32? {
        guard status == nil else { return status }
        var raw: Int32 = 0
        let result = waitpid(pid, &raw, WNOHANG)
        if result == pid { status = raw }
        else if result == -1 && errno == ECHILD { status = -1 }
        return status
    }

    func signalGroup(_ signal: Int32) throws {
        guard poll() == nil, getpgid(pid) == pid else { throw QuietError("Owned process group is no longer running.") }
        guard kill(-pid, signal) == 0 else { throw QuietError("Process signal rejected: \(String(cString: strerror(errno)))") }
    }

    func terminate(isolation: isolated (any Actor)? = #isolation) async {
        guard poll() == nil else { return }
        try? signalGroup(SIGTERM)
        for _ in 0..<30 {
            if poll() != nil { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? signalGroup(SIGKILL)
        var raw: Int32 = 0
        if waitpid(pid, &raw, 0) == pid { status = raw }
    }
}

func localEnvironment() -> [String: String] {
    ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
     "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
     "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
}
