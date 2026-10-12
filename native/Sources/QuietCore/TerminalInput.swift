import Foundation

public enum TerminalEvent: Equatable, Sendable {
    case key(String), mouse(button: Int, x: Int, y: Int), paste(String), graphicsResponse(id: Int, ok: Bool), cellSize(width: Int, height: Int)
    case synchronizedOutput(Bool)
}

/// Incremental xterm SGR mouse/key decoder. Bracketed paste can never become actions.
public struct TerminalInput: Sendable {
    private var bytes: [UInt8] = []
    private var controlString: UInt8?
    private var controlEscape = false
    private var controlPayload: [UInt8] = []
    private var pasting = false
    private var pasted: [UInt8] = []
    public init() {}
    public mutating func feed(_ input: [UInt8]) -> [TerminalEvent] {
        bytes.append(contentsOf: input)
        if bytes.count > 8192 { bytes.removeAll(); pasting = false; pasted.removeAll(); return [] }
        var events: [TerminalEvent] = []
        let endPaste: [UInt8] = [27,91,50,48,49,126]
        while !bytes.isEmpty {
            if let kind = controlString {
                let byte = bytes.removeFirst()
                if (controlEscape && byte == 92) || (kind == 93 && byte == 7) {
                    if kind == 95 {
                        let payload = String(decoding: controlPayload, as: UTF8.self)
                        let parts = payload.split(separator: ";", maxSplits: 1)
                        if parts.count == 2, parts[0].hasPrefix("G") {
                            let fields = parts[0].dropFirst().split(separator: ",")
                            if let field = fields.first(where: { $0.hasPrefix("i=") }), let id = Int(field.dropFirst(2)) {
                                events.append(.graphicsResponse(id: id, ok: parts[1] == "OK"))
                            }
                        }
                    }
                    controlString = nil; controlEscape = false; controlPayload.removeAll(keepingCapacity: true)
                } else {
                    if !controlEscape && byte != 27 && controlPayload.count < 4096 { controlPayload.append(byte) }
                    controlEscape = byte == 27
                }
                continue
            }
            if pasting {
                if bytes.starts(with: endPaste) {
                    bytes.removeFirst(6); events.append(.paste(String(decoding: pasted, as: UTF8.self)))
                    pasted.removeAll(); pasting = false; continue
                }
                if bytes.count < 6 && endPaste.starts(with: bytes) { break }
                // Enough for a pasted question; longer pastes are cut, never interpreted.
                if pasted.count < 2000 { pasted.append(bytes[0]) }
                bytes.removeFirst(); continue
            }
            if bytes[0] == 27 {
                guard bytes.count > 1 else { break }
                if [95, 93, 80, 94].contains(bytes[1]) {
                    controlString = bytes[1]; bytes.removeFirst(2); continue
                }
                guard bytes[1] == 91 else { bytes.removeFirst(2); events.append(.key("escape")); continue }
                guard bytes.count > 2 else { break }
                guard let end = bytes.indices.dropFirst(2).first(where: { (64...126).contains(bytes[$0]) }) else { break }
                let code = String(decoding: bytes[2...end], as: UTF8.self)
                bytes.removeFirst(end + 1)
                if code == "200~" { pasting = true; continue }
                if code.hasPrefix("?2026;"), code.hasSuffix("$y"),
                   let state = Int(code.dropFirst(6).dropLast(2)), (0...4).contains(state) {
                    events.append(.synchronizedOutput(state == 1 || state == 2))
                } else if code.hasPrefix("6;"), code.hasSuffix("t") {
                    let parts = code.dropLast().split(separator: ";").compactMap { Int($0) }
                    if parts.count == 3 { events.append(.cellSize(width: parts[2], height: parts[1])) }
                } else if code.hasPrefix("<"), code.hasSuffix("M") {
                    let parts = code.dropFirst().dropLast().split(separator: ";").compactMap { Int($0) }
                    if parts.count == 3, parts[1] > 0, parts[2] > 0 { events.append(.mouse(button: parts[0], x: parts[1], y: parts[2])) }
                } else if let key = ["A":"up", "B":"down", "C":"right", "D":"left", "5~":"pageUp", "6~":"pageDown", "H":"home", "F":"end"][code] { events.append(.key(key)) }
            } else {
                let byte = bytes.removeFirst()
                switch byte {
                case 13,10: events.append(.key("enter"))
                case 9: events.append(.key("tab"))
                case 127,8: events.append(.key("backspace"))
                case 32...126: events.append(.key(String(UnicodeScalar(byte))))
                default: break
                }
            }
        }
        return events
    }
    public mutating func flushEscape() -> [TerminalEvent] {
        guard bytes == [27] else { return [] }
        bytes.removeAll(); return [.key("escape")]
    }
}

public enum TerminalText {
    /// Treat process names, model output and errors as data, never terminal control sequences.
    public static func safe(_ text: String) -> String {
        String(text.unicodeScalars.map { (32...126).contains($0.value) ? Character($0) : " " })
    }
    public static func fit(_ text: String, width: Int) -> String {
        let value = String(safe(text).prefix(max(0, width)))
        return value + String(repeating: " ", count: max(0, width - value.count))
    }
}
