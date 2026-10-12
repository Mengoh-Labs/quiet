import Foundation
import QuietCore

/// `quiet models`: the MLX models Glyph can use for narration and chat instead of Apple's model.
enum ModelsCommand {
    static let usage = "Usage: quiet models | quiet models pull <owner/model> | quiet models use <name|apple> | quiet models remove <name>"

    static func run(_ arguments: [String]) async throws {
        let library = ModelLibrary()
        switch (arguments.first, arguments.count) {
        case (nil, _), ("list", 1):
            let selected = library.selected()?.name
            var table = "| Use | Model | Size | Source |\n| :-: | :-- | --: | :-- |\n"
            table += "| \(selected == nil ? "x" : " ") | apple | -- | Apple on-device model (default) |\n"
            for entry in library.list() {
                table += "| \(entry.name == selected ? "x" : " ") | \(TerminalMarkdown.literal(entry.name)) | \(AgentsCommand.bytes(entry.bytes)) | \(TerminalMarkdown.literal(entry.repository ?? "local folder")) |\n"
            }
            let ansi = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["TERM"] != "dumb"
                && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
            print(TerminalMarkdown.render("# Glyph models\n" + table + "\nNarration and chat use the marked model. Ambient commentary always uses Apple's.", width: 100, ansi: ansi))
        case ("pull", 2):
            let entry = try await library.pull(repository: arguments[1], fetch: HuggingFaceFetcher()) { line in
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            print("Downloaded and verified \(entry.name) (\(AgentsCommand.bytes(entry.bytes))). Select it with: quiet models use \(entry.name)")
        case ("use", 2):
            try library.select(arguments[1] == "apple" ? nil : arguments[1])
            print(arguments[1] == "apple" ? "Glyph uses Apple's on-device model." : "Glyph uses \(arguments[1]) for narration and chat.")
        case ("remove", 2):
            try library.remove(arguments[1])
            print("Removed \(arguments[1]).")
        default: throw QuietError(usage)
        }
    }
}
