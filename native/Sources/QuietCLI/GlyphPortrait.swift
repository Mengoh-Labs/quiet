import Foundation
import ImageIO

/// Load once from the installed bundle, including when the CLI is reached through a symlink.
/// The source-tree fallback supports SwiftPM development runs without copying artwork.
enum GlyphPortrait {
    static let data: Data? = {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let resources = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        for directory in [resources, development] {
            let url = directory.appendingPathComponent("Glyph-avatar.png")
            guard let data = try? Data(contentsOf: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { continue }
            return data
        }
        return nil
    }()
}
