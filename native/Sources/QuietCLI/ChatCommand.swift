import Foundation
import QuietCore

/// `quiet chat`: read or clear the saved chat history without opening the dashboard.
enum ChatCommand {
    static func run(_ arguments: [String]) throws {
        let store = ChatState.store()
        switch (arguments.first, arguments.count) {
        case (nil, _):
            let turns = store.recent(limit: 20)
            guard !turns.isEmpty else { print("No saved chat. Open the dashboard and press c to start one."); return }
            let ansi = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["TERM"] != "dumb"
                && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
            var size = winsize()
            _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
            let text = turns.map { turn in
                "**\(turn.role == .owner ? "You" : "Glyph")** - \(turn.date.formatted(date: .abbreviated, time: .shortened))\n"
                    + (turn.role == .owner ? TerminalMarkdown.literal(turn.text) : turn.text)
            }.joined(separator: "\n\n")
            print(TerminalMarkdown.render(text, width: size.ws_col > 0 ? max(1, Int(size.ws_col) - 1) : 100, ansi: ansi))
            FileHandle.standardError.write(Data("\n\(store.bytes / 1024) KiB saved in \(store.directory.path); the store rotates at 25 MiB.\n".utf8))
        case ("clear", 1):
            store.clear()
            print("Saved chat history cleared.")
        default: throw QuietError("Usage: quiet chat | quiet chat clear")
        }
    }
}
