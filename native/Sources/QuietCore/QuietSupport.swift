import Foundation

/// Quiet's identifier and the folder where it keeps its application data.
public enum QuietSupport {
    public static let identifier = "ai.quandrylabs.quiet"
    public static let directory = storageDirectory(environment: ProcessInfo.processInfo.environment)

    /// Explicit storage isolation for tests or a portable installation.
    static func storageDirectory(environment: [String: String]) -> URL {
        if let path = environment["QUIET_SUPPORT_DIR"], path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if url.path != "/" { return url }
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(identifier, isDirectory: true)
    }
}
