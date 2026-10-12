import Darwin
import Foundation

/// Whose agents to look for. Under `sudo` the process is root, but the sessions worth watching
/// belong to the person who ran it; their home is where the session logs are.
public enum InvokingUser {
    /// File ownership remains the invoking account even when telemetry is run via sudo.
    static var uid: uid_t {
        if geteuid() == 0, let text = ProcessInfo.processInfo.environment["SUDO_UID"],
           let uid = uid_t(text), uid != 0, getpwuid(uid) != nil { return uid }
        return getuid()
    }
    public static var home: URL {
        home(effectiveUID: geteuid(), environment: ProcessInfo.processInfo.environment) { uid in
            getpwuid(uid).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) }
        } ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// The home of the user named by `SUDO_UID`, only when running as root and only when the
    /// account database knows that user. The environment's `HOME` and `SUDO_USER` are not trusted.
    static func home(effectiveUID: uid_t, environment: [String: String], lookup: (uid_t) -> String?) -> URL? {
        guard effectiveUID == 0, let text = environment["SUDO_UID"], let uid = uid_t(text), uid != 0,
              let path = lookup(uid), path.hasPrefix("/"), path != "/" else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
