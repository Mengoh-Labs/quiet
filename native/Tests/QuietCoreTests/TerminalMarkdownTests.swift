import Foundation
import Testing
@testable import QuietCore

private func plain(_ source: String, _ width: Int) -> [String] {
    TerminalMarkdown.lines(source, width: width).map { String($0.map(\.character)) }
}

@Test func markdownInlineStylesNestAndReset() {
    let glyphs = TerminalMarkdown.inline("**bold *both*** plain `a*b` [link](https://example.com)")
    #expect(String(glyphs.map(\.character)) == "bold both plain a*b link")
    #expect(glyphs[0].style.contains(";1"))
    #expect(glyphs[5].style.contains(";1") && glyphs[5].style.contains(";3"))
    #expect(glyphs[10].style == "0")
    #expect(glyphs[16].style.contains(";7"))
    #expect(glyphs.last?.style.contains(";4") == true)
}

@Test func markdownBlocksWrapWithBoundedCells() {
    let lines = TerminalMarkdown.lines("# Title\n- **one** two three\n> quote\n```swift\na*b\n```\n1. last", width: 10)
    #expect(lines.map { String($0.map(\.character)) } == ["Title", "• one two", "  three", "│ quote", " swift    ", " a*b      ", "1. last"])
    #expect(lines[0].allSatisfy { $0.style.contains(";1;4") })
    #expect(lines[3].dropFirst(2).allSatisfy { $0.style.contains(";3") })
    #expect(lines[5].allSatisfy { $0.style.contains("48;2;") })
    #expect(plain("hello world next", 11) == ["hello world", "next"])
    #expect(TerminalMarkdown.lines("hello", width: 0).isEmpty)
    #expect(TerminalMarkdown.lines("abcdefghijkl", width: 3).allSatisfy { $0.count <= 3 })
}

@Test func markdownHeadingLevelsAreDistinct() {
    let lines = TerminalMarkdown.lines("# one\n## two\n### three", width: 20)
    #expect(lines[0][0].style.hasSuffix(";1;4"))
    #expect(lines[1][0].style.hasSuffix(";1"))
    #expect(lines[2][0].style.hasSuffix(";1;3"))
}

@Test func markdownListsNestNumberAndHang() {
    #expect(plain("- top level item wraps\n  - nested child item wraps\n    - third\n1. first\n10. tenth entry wraps here", 16) == [
        "• top level item", "  wraps",
        "  ◦ nested child", "    item wraps",
        "    ▪ third",
        "1. first",
        "10. tenth entry", "    wraps here"])
    #expect(plain("- [ ] open\n- [x] done", 20) == ["• [ ] open", "• [x] done"])
    #expect(plain("- one\n  continues here", 30) == ["• one continues here"])
    let done = TerminalMarkdown.lines("- [x] done", width: 20)[0]
    #expect(done.last?.style.contains(";2") == true)
}

@Test func markdownQuotesNestAndRulesFillTheWidth() {
    #expect(plain("> outer\n> > inner", 12) == ["│ outer", "│ │ inner"])
    #expect(plain("above\n\n---\nbelow", 6) == ["above", "", "──────", "below"])
    #expect(plain("a\n\n\n\nb", 5) == ["a", "", "b"])
}

@Test func markdownCodeBlocksKeepSpacingAndWrapByCharacter() {
    let rows = plain("```\nif x  {\n    abcdefghijkl\n}\n```", 10)
    #expect(rows == [" if x  {  ", "     abcd ", " efghijkl ", " }        "])
    #expect(plain("```\n**not bold** | pipe\n```", 30)[0].contains("**not bold** | pipe"))
    #expect(plain("```sh\nunterminated", 20) == [" sh                 ", " unterminated       "])
}

@Test func markdownTablesAlignWrapAndFallBack() {
    let table = "| Name | CPU | Note |\n| :-- | --: | :-: |\n| claude | 12 | ok |\n| codex-long | 3 | a |"
    #expect(plain(table, 40) == [
        "Name       │ CPU │ Note",
        "───────────┼─────┼─────",
        "claude     │  12 │  ok ",
        "codex-long │   3 │  a  "])
    let header = TerminalMarkdown.lines(table, width: 40)[0]
    #expect(header[0].style.contains(";1"))
    // A long cell wraps inside its own column and every row stays within the width.
    let wide = plain("| k | value |\n|---|---|\n| a | one two three four five six |", 20)
    #expect(wide.allSatisfy { $0.count <= 20 })
    #expect(wide.count > 3 && wide[2].hasPrefix("a │ "))
    #expect(wide.dropFirst(3).allSatisfy { $0.hasPrefix("  │ ") })
    // Too narrow for columns: one labelled value per row, nothing clipped.
    let stacked = plain("| Name | Status | Detail |\n|---|---|---|\n| alpha | working | reading files |", 9)
    #expect(stacked.allSatisfy { $0.count <= 9 })
    #expect(stacked.joined(separator: " ").contains("Name: alpha"))
    #expect(stacked.joined(separator: " ").contains("reading"))
    // A pipe without a separator row is ordinary text.
    #expect(plain("a | b", 10) == ["a | b"])
}

@Test func markdownCannotInjectTerminalControlsOrStyleLiteralNames() {
    let source = "# **Hi**\n\u{1b}[2J\u{7}\u{9b}31m\n[link](https://example.com)\n| a\u{1b}[2J | b |\n|---|---|\n| \u{7}c | d |"
    let plain = TerminalMarkdown.render(source, ansi: false)
    #expect(!plain.contains("\u{1b}") && !plain.contains("\u{7}") && !plain.contains("\u{9b}"))
    #expect(!plain.contains("**"))
    let ansi = TerminalMarkdown.render(source, ansi: true)
    let stripped = ansi.replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
    #expect(stripped == plain)
    #expect(!stripped.contains("\u{1b}"))
    let name = "a_b **test** [x](y) `cmd` &amp; &#65;"
    let literal = TerminalMarkdown.inline(TerminalMarkdown.literal(name))
    #expect(String(literal.map(\.character)) == name)
    #expect(literal.allSatisfy { $0.style == "0" })
}

@Test func markdownCanvasClipsStylesAndKeepsBordersAndLiteralText() {
    var canvas = TerminalCanvas(width: 16, height: 5)
    canvas.box(TerminalRect(0, 0, 16, 5), title: "**CPU**", style: "36", markdownTitle: true)
    let total = canvas.markdown("**hello** world longer\nlast", in: TerminalRect(2, 1, 12, 2))
    canvas.text("**literal**", x: 2, y: 3, width: 12)
    #expect(total == 3)
    #expect(canvas.plainRows[0].contains(" CPU "))
    #expect(canvas.plainRows[1].contains("hello world"))
    #expect(canvas.plainRows[2].contains("longer"))
    #expect(!canvas.plainRows.joined().contains("last"))
    #expect(canvas.plainRows[3].contains("**literal**"))
    #expect(canvas.plainRows.allSatisfy { $0.count == 16 })
    #expect(canvas.plainRows[4].first == "╰")
    #expect(canvas.ansiRows[0].contains("36;1mCPU"))
}

@Test func markdownCanvasScrollsToLaterRows() {
    var canvas = TerminalCanvas(width: 10, height: 2)
    let total = canvas.markdown("one\ntwo\nthree\nfour", in: TerminalRect(0, 0, 10, 2), scroll: 2)
    #expect(total == 4)
    #expect(canvas.plainRows == ["three     ", "four      "])
}
