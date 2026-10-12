import Foundation

/// Markdown becomes styled cells, never terminal escape sequences supplied by content.
/// Source text keeps the canvas's ASCII policy; only this renderer emits bullets, rules,
/// gutters and table separators, so every glyph occupies exactly one terminal cell.
public enum TerminalMarkdown {
    public struct Glyph: Sendable {
        public let character: Character
        public let style: String
    }

    static let dim = "2"
    static let code = MengohPalette.foreground(0xC8CDD4) + ";" + MengohPalette.background(0x20242A)

    public static func literal(_ text: String) -> String {
        TerminalText.safe(text).reduce(into: "") { result, char in
            if "\\`*_{}[]<>()#+-.!|~&".contains(char) { result.append("\\") }
            result.append(char)
        }
    }

    public static func inline(_ source: String, style: String = "0") -> [Glyph] {
        let clean = TerminalText.safe(source)
        guard let parsed = try? AttributedString(markdown: clean, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return clean.map { Glyph(character: $0, style: style) }
        }
        return parsed.runs.flatMap { run -> [Glyph] in
            var codes = [style]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { codes.append("1") }
                if intent.contains(.emphasized) { codes.append("3") }
                if intent.contains(.code) { codes.append("7") }
                if intent.contains(.strikethrough) { codes.append("9") }
            }
            // Links are underlined text; never emit OSC links or execute URLs.
            if run.link != nil { codes.append("4") }
            return TerminalText.safe(String(parsed[run.range].characters)).map {
                Glyph(character: $0, style: codes.joined(separator: ";"))
            }
        }
    }

    /// Every returned row holds at most `width` cells. Source line breaks are kept as breaks.
    public static func lines(_ source: String, width: Int, style: String = "0") -> [[Glyph]] {
        guard width > 0 else { return [] }
        let raw = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { line in
            // Tabs would otherwise collapse to one cell and lose list nesting.
            TerminalText.safe(line.replacingOccurrences(of: "\t", with: "    "))
        }
        var result = blocks(raw, width: width, style: style)
        while result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    private static func blocks(_ raw: [String], width: Int, style: String) -> [[Glyph]] {
        var result: [[Glyph]] = []
        var index = 0
        func blank() { if let last = result.last, !last.isEmpty { result.append([]) } }
        while index < raw.count {
            let line = raw[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { blank(); index += 1; continue }
            if let fence = fence(trimmed) {
                var body: [String] = []
                index += 1
                while index < raw.count {
                    let candidate = raw[index].trimmingCharacters(in: .whitespaces)
                    if let close = self.fence(candidate), close.marker == fence.marker, close.count >= fence.count, close.label.isEmpty {
                        index += 1; break
                    }
                    body.append(raw[index]); index += 1
                }
                result += codeBlock(body, label: fence.label, width: width, style: style)
                continue
            }
            if let level = heading(trimmed) {
                let text = String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
                let emphasis = level == 1 ? ";1;4" : level == 2 ? ";1" : ";1;3"
                appendWrapped(inline(text, style: style + emphasis), width: width, to: &result)
                index += 1; continue
            }
            if isRule(trimmed) {
                result.append(Array(repeating: Glyph(character: "─", style: style + ";" + dim), count: width))
                index += 1; continue
            }
            if trimmed.contains("|"), index + 1 < raw.count, let alignments = tableSeparator(raw[index + 1]) {
                var rows = [cells(trimmed)]
                index += 2
                while index < raw.count, raw[index].contains("|"), !raw[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(raw[index])); index += 1
                }
                result += table(rows, alignments: alignments, width: width, style: style)
                continue
            }
            if trimmed.hasPrefix(">") {
                var inner: [String] = []
                while index < raw.count {
                    let candidate = raw[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    let body = candidate.dropFirst()
                    inner.append(String(body.hasPrefix(" ") ? body.dropFirst() : body)); index += 1
                }
                let gutter = [Glyph(character: "│", style: style + ";" + dim), Glyph(character: " ", style: style)]
                if width <= 4 { result += blocks(inner, width: width, style: style + ";3"); continue }
                result += blocks(inner, width: width - 2, style: style + ";3").map { gutter + $0 }
                continue
            }
            if let item = listItem(line) {
                var text = item.text
                index += 1
                // A following plain line continues the item; any block start ends it.
                while index < raw.count {
                    let next = raw[index], nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    guard !nextTrimmed.isEmpty, next.hasPrefix("  "), listItem(next) == nil, fence(nextTrimmed) == nil,
                          heading(nextTrimmed) == nil, !nextTrimmed.hasPrefix(">"), !isRule(nextTrimmed) else { break }
                    text += " " + nextTrimmed; index += 1
                }
                result += listRows(item, text: text, width: width, style: style)
                continue
            }
            appendWrapped(inline(line.trimmingCharacters(in: .whitespaces), style: style), width: width, to: &result)
            index += 1
        }
        return result
    }

    private static func fence(_ trimmed: String) -> (marker: Character, count: Int, label: String)? {
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let label = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
        guard !label.contains("`") else { return nil }
        return (marker, count, label)
    }
    private static func heading(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        return (1...6).contains(hashes) && trimmed.dropFirst(hashes).first == " " ? hashes : nil
    }
    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private struct ListItem: Equatable { var depth: Int; var marker: String; var ordered: Bool; var text: String }
    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix(while: { $0 == " " }).count
        let body = line.dropFirst(indent)
        guard let first = body.first else { return nil }
        if "-*+".contains(first), body.dropFirst().first == " " {
            return ListItem(depth: min(4, indent / 2), marker: "", ordered: false,
                            text: String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        let digits = body.prefix(while: { $0.isNumber })
        let rest = body.dropFirst(digits.count)
        guard (1...9).contains(digits.count), let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return ListItem(depth: min(4, indent / 2), marker: String(digits) + String(mark), ordered: true,
                        text: String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }
    private static func listRows(_ item: ListItem, text: String, width: Int, style: String) -> [[Glyph]] {
        var content = text, contentStyle = style, box = ""
        for (prefix, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where content.hasPrefix(prefix) {
            box = checked ? "[x] " : "[ ] "; content = String(content.dropFirst(4))
            if checked { contentStyle += ";" + dim }
        }
        let bullets: [Character] = ["•", "◦", "▪"]
        let marker = (item.ordered ? item.marker : String(bullets[min(item.depth, bullets.count - 1)])) + " " + box
        // Give up nesting indent before giving up readable text width.
        let indent = min(item.depth * 2, max(0, width - marker.count - 8))
        let available = width - indent - marker.count
        guard available >= 1 else {
            var rows: [[Glyph]] = []
            appendWrapped(inline(marker + content, style: contentStyle), width: width, to: &rows)
            return rows
        }
        var wrapped: [[Glyph]] = []
        appendWrapped(inline(content, style: contentStyle), width: available, to: &wrapped)
        if wrapped.isEmpty { wrapped = [[]] }
        let pad = { (count: Int) in Array(repeating: Glyph(character: " ", style: style), count: count) }
        return wrapped.enumerated().map { row, glyphs in
            let lead = row == 0 ? pad(indent) + marker.map { Glyph(character: $0, style: style + (item.ordered ? "" : ";" + dim)) }
                                : pad(indent + marker.count)
            return lead + glyphs
        }
    }

    private static func codeBlock(_ body: [String], label: String, width: Int, style: String) -> [[Glyph]] {
        let block = style + ";" + code
        func row(_ text: Substring, _ rowStyle: String) -> [Glyph] {
            let inner = max(0, width - 2)
            let cells = width >= 3 ? " " + text + String(repeating: " ", count: max(0, inner - text.count)) + " " : String(text.prefix(width))
            return cells.prefix(width).map { Glyph(character: $0, style: rowStyle) }
        }
        var rows: [[Glyph]] = []
        let inner = max(1, width >= 3 ? width - 2 : width)
        if !label.isEmpty { rows.append(row(label.prefix(inner), block + ";" + dim)) }
        for line in body.isEmpty ? [""] : body {
            // Code wraps by character: a word wrap would move tokens and hide real spacing.
            var rest = Substring(line)
            repeat { rows.append(row(rest.prefix(inner), block)); rest = rest.dropFirst(inner) } while !rest.isEmpty
        }
        return rows
    }

    private enum Alignment { case left, right, center }
    private static func cells(_ line: String) -> [String] {
        var parts: [String] = [], current = "", escaped = false
        for char in line.trimmingCharacters(in: .whitespaces) {
            if escaped { current.append(char); escaped = false }
            else if char == "\\" { current.append(char); escaped = true }
            else if char == "|" { parts.append(current); current = "" }
            else { current.append(char) }
        }
        parts.append(current)
        if parts.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeFirst() }
        if parts.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeLast() }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private static func tableSeparator(_ line: String) -> [Alignment]? {
        guard line.contains("|") || line.contains("-") else { return nil }
        let parts = cells(line)
        guard line.contains("|"), !parts.isEmpty else { return nil }
        var result: [Alignment] = []
        for part in parts {
            let dashes = part.filter { $0 == "-" }.count
            guard dashes >= 1, part.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            result.append(part.hasPrefix(":") && part.hasSuffix(":") ? .center : part.hasSuffix(":") ? .right : .left)
        }
        return result
    }
    private static func table(_ rows: [[String]], alignments: [Alignment], width: Int, style: String) -> [[Glyph]] {
        let columns = rows[0].count
        guard columns > 0 else { return [] }
        let glyphs = rows.enumerated().map { rowIndex, row in
            (0..<columns).map { inline($0 < row.count ? row[$0] : "", style: style + (rowIndex == 0 ? ";1" : "")) }
        }
        let natural = (0..<columns).map { column in max(1, glyphs.map { $0[column].count }.max() ?? 1) }
        let available = width - (columns - 1) * 3
        var widths = natural
        if natural.reduce(0, +) > available {
            // Narrow columns keep their natural width; the wide ones share what is left.
            var remaining = available, left = columns
            for column in (0..<columns).sorted(by: { natural[$0] < natural[$1] }) {
                widths[column] = min(natural[column], remaining / max(1, left))
                remaining -= widths[column]; left -= 1
            }
        }
        guard available >= columns, zip(widths, natural).allSatisfy({ $0 >= min(3, $1) }) else {
            return stacked(glyphs, width: width, style: style)
        }
        let rule = Glyph(character: "─", style: style + ";" + dim)
        func separator(_ middle: Character) -> [Glyph] {
            [Glyph(character: " ", style: style), Glyph(character: middle, style: style + ";" + dim), Glyph(character: " ", style: style)]
        }
        var result: [[Glyph]] = []
        for (rowIndex, row) in glyphs.enumerated() {
            let wrapped = (0..<columns).map { column -> [[Glyph]] in
                var lines: [[Glyph]] = []
                appendWrapped(row[column], width: widths[column], to: &lines)
                return lines.isEmpty ? [[]] : lines
            }
            for lineIndex in 0..<(wrapped.map(\.count).max() ?? 1) {
                var line: [Glyph] = []
                for column in 0..<columns {
                    let cell = lineIndex < wrapped[column].count ? wrapped[column][lineIndex] : []
                    let space = max(0, widths[column] - cell.count)
                    let alignment = column < alignments.count ? alignments[column] : .left
                    let before = alignment == .right ? space : alignment == .center ? space / 2 : 0
                    let pad = { (count: Int) in Array(repeating: Glyph(character: " ", style: style), count: count) }
                    line += pad(before) + cell + pad(space - before)
                    if column < columns - 1 { line += separator("│") }
                }
                result.append(line)
            }
            if rowIndex == 0 {
                var line: [Glyph] = []
                for column in 0..<columns {
                    line += Array(repeating: rule, count: widths[column])
                    if column < columns - 1 { line += [rule, Glyph(character: "┼", style: style + ";" + dim), rule] }
                }
                result.append(line)
            }
        }
        return result
    }
    /// A table too wide for its panel reads as one labelled value per row instead of clipping.
    private static func stacked(_ glyphs: [[[Glyph]]], width: Int, style: String) -> [[Glyph]] {
        var result: [[Glyph]] = []
        for row in glyphs.dropFirst() {
            if !result.isEmpty { result.append([]) }
            for (column, cell) in row.enumerated() {
                let label = glyphs[0][column] + [Glyph(character: ":", style: style + ";1"), Glyph(character: " ", style: style)]
                appendWrapped(label + cell, width: width, to: &result)
            }
        }
        return result
    }

    private static func appendWrapped(_ glyphs: [Glyph], width: Int, to lines: inout [[Glyph]]) {
        guard !glyphs.isEmpty else { lines.append([]); return }
        var start = 0
        while start < glyphs.count {
            var end = min(glyphs.count, start + width)
            if end < glyphs.count, glyphs[end].character != " ",
               let space = (start..<end).last(where: { glyphs[$0].character == " " }), space > start {
                end = space
            }
            lines.append(Array(glyphs[start..<end]))
            start = end
            if start < glyphs.count && glyphs[start].character == " " { start += 1 }
        }
    }

    public static func render(_ source: String, width: Int = 80, ansi: Bool) -> String {
        lines(source, width: width).map { line in
            guard ansi else {
                // Code rows are padded for their background; plain output has no background to fill.
                var text = String(line.map(\.character))
                while text.hasSuffix(" ") { text.removeLast() }
                return text
            }
            var output = "", previous = ""
            for glyph in line {
                if glyph.style != previous { output += "\u{1b}[0;\(glyph.style)m"; previous = glyph.style }
                output.append(glyph.character)
            }
            return output + "\u{1b}[0m"
        }.joined(separator: "\n")
    }
}
