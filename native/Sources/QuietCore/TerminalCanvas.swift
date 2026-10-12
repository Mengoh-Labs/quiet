import Foundation

/// All coordinates are zero-based terminal cells. Only trusted drawing primitives emit Unicode.
/// External text is sanitized before entering the canvas so it cannot inject terminal controls.
public struct TerminalRect: Sendable, Equatable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
        self.x = x; self.y = y; self.width = max(0, width); self.height = max(0, height)
    }
    public func contains(x: Int, y: Int) -> Bool { x >= self.x && y >= self.y && x < self.x + width && y < self.y + height }
}

public struct TerminalCanvas {
    private struct Cell { var glyph: Character = " "; var style = "0" }
    public let width: Int, height: Int
    public private(set) var graphics: [TerminalGraphic] = []
    private let pixelGraphics: Bool
    private var baseStyle: String
    private var cells: [Cell]
    public init(width: Int, height: Int, baseStyle: String = "0", pixelGraphics: Bool = false) {
        self.pixelGraphics = pixelGraphics
        self.baseStyle = baseStyle
        self.width = max(1, width); self.height = max(1, height)
        cells = Array(repeating: Cell(), count: self.width * self.height)
    }
    /// Returns false when pixel graphics are unavailable; callers retain full text width.
    @discardableResult
    public mutating func portrait(_ data: Data, in rect: TerminalRect) -> Bool {
        guard pixelGraphics, rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
              rect.x + rect.width <= width, rect.y + rect.height <= height else { return false }
        graphics.append(.portrait(rect, data))
        return true
    }
    /// A fully rendered control. Returns false in text mode, where the caller draws a character keycap and label.
    @discardableResult
    public mutating func button(_ key: String, label: String, in rect: TerminalRect, accent: UInt32, enabled: Bool = true) -> Bool {
        guard pixelGraphics, rect.x >= 0, rect.y >= 0, rect.width >= 4, rect.height == 1,
              rect.x + rect.width <= width, rect.y < height else { return false }
        graphics.append(.button(rect, key: TerminalText.safe(key), label: TerminalText.safe(label), accent: accent, enabled: enabled))
        return true
    }
    /// Returns false when pixel graphics are unavailable; callers then draw the text masthead.
    @discardableResult
    public mutating func header(_ card: HeaderCard, in rect: TerminalRect) -> Bool {
        guard pixelGraphics, rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
              rect.x + rect.width <= width, rect.y + rect.height <= height else { return false }
        graphics.append(.header(rect, card))
        return true
    }
    private mutating func put(_ x: Int, _ y: Int, _ char: Character, _ style: String) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        cells[y * width + x] = Cell(glyph: char, style: style)
    }
    public mutating func text(_ value: String, x: Int, y: Int, width limit: Int, style: String = "0") {
        for (i, char) in TerminalText.safe(value).prefix(max(0, limit)).enumerated() { put(x + i, y, char, style) }
    }
    /// Draws the rows that fit after skipping `scroll` rows; returns the total so callers can scroll.
    @discardableResult
    public mutating func markdown(_ value: String, in rect: TerminalRect, style: String = "0", scroll: Int = 0) -> Int {
        let lines = TerminalMarkdown.lines(value, width: rect.width, style: style)
        for (row, glyphs) in lines.dropFirst(max(0, scroll)).prefix(rect.height).enumerated() {
            for (column, glyph) in glyphs.enumerated() { put(rect.x + column, rect.y + row, glyph.character, glyph.style) }
        }
        return lines.count
    }
    /// Draws rows already laid out by `TerminalMarkdown`, clipped to the rectangle.
    public mutating func glyphs(_ rows: ArraySlice<[TerminalMarkdown.Glyph]>, in rect: TerminalRect) {
        for (row, glyphs) in rows.prefix(rect.height).enumerated() {
            for (column, glyph) in glyphs.prefix(rect.width).enumerated() { put(rect.x + column, rect.y + row, glyph.character, glyph.style) }
        }
    }
    public mutating func markdownLabel(_ value: String, x: Int, y: Int, width: Int, style: String = "0") {
        for (column, glyph) in TerminalMarkdown.inline(value, style: style).prefix(max(0, width)).enumerated() {
            put(x + column, y, glyph.character, glyph.style)
        }
    }
    /// Standard Unicode half-circles keep one-row keycaps rounded without a custom font.
    /// `graphic: false` keeps the character keycap even in pixel mode, for rows that repaint often:
    /// an image there would be retransmitted on every repaint.
    public mutating func keycap(_ key: String, x: Int, y: Int, foreground: UInt32 = 0xE5E9EF, background: UInt32 = 0x303640, graphic: Bool = true) {
        if pixelGraphics && graphic {
            graphics.append(.keycap(TerminalRect(x, y, 3, 1), background))
            text(key, x: x + 1, y: y, width: 1, style: "1;" + MengohPalette.foreground(foreground))
            return
        }
        let edge = MengohPalette.foreground(background) + ";49"
        put(x, y, "◖", edge)
        text(key, x: x + 1, y: y, width: 1, style: "1;" + MengohPalette.foreground(foreground) + ";" + MengohPalette.background(background))
        put(x + 2, y, "◗", edge)
    }
    public mutating func fill(_ rect: TerminalRect, style: String) {
        guard rect.width > 0, rect.height > 0 else { return }
        let left = max(0, rect.x), right = min(width, rect.x + rect.width)
        let top = max(0, rect.y), bottom = min(height, rect.y + rect.height)
        guard left < right, top < bottom else { return }
        for y in top..<bottom {
            for x in left..<right { put(x, y, " ", style) }
        }
    }
    public mutating func box(_ rect: TerminalRect, title: String, style: String, titleStyle: String? = nil, markdownTitle: Bool = false) {
        guard rect.width >= 2, rect.height >= 2 else { return }
        for x in 1..<(rect.width - 1) { put(rect.x + x, rect.y, "─", style); put(rect.x + x, rect.y + rect.height - 1, "─", style) }
        for y in 1..<(rect.height - 1) { put(rect.x, rect.y + y, "│", style); put(rect.x + rect.width - 1, rect.y + y, "│", style) }
        put(rect.x, rect.y, "╭", style); put(rect.x + rect.width - 1, rect.y, "╮", style)
        put(rect.x, rect.y + rect.height - 1, "╰", style); put(rect.x + rect.width - 1, rect.y + rect.height - 1, "╯", style)
        if markdownTitle {
            markdownLabel(" " + title + " ", x: rect.x + 2, y: rect.y, width: rect.width - 4, style: titleStyle ?? style)
        } else {
            text(" " + title + " ", x: rect.x + 2, y: rect.y, width: rect.width - 4, style: titleStyle ?? style)
        }
    }
    public mutating func bar(_ value: Double?, x: Int, y: Int, width: Int, style: String = MengohPalette.foreground(MengohPalette.moss)) {
        guard width > 0 else { return }
        if pixelGraphics {
            let reading = value.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
            graphics.append(.bar(TerminalRect(x, y, width, 1), reading, style))
            if reading == nil { text("unavailable", x: x, y: y, width: width, style: "2") }
            return
        }
        guard let value, value.isFinite else { text("unavailable", x: x, y: y, width: width, style: "2"); return }
        let n = Int((min(100, max(0, value)) / 100 * Double(width)).rounded())
        for i in 0..<width { put(x + i, y, i < n ? "━" : "─", i < n ? style : MengohPalette.foreground(0x3A3F46)) }
    }
    /// Two samples per cell, four vertical dots per row. Missing data stays blank.
    public mutating func graph(_ values: [Double?], in rect: TerminalRect, maximum: Double = 100, style: String = MengohPalette.foreground(MengohPalette.moss)) {
        guard rect.width > 0, rect.height > 0, maximum.isFinite, maximum > 0 else { return }
        let samples = Array(values.suffix(rect.width * 2))
        let padding = rect.width * 2 - samples.count
        let bits = [[0, 1, 2, 6], [3, 4, 5, 7]]
        for col in 0..<rect.width {
            for row in 0..<rect.height {
                var mask = 0
                for side in 0..<2 {
                    let index = col * 2 + side - padding
                    guard index >= 0, index < samples.count, let value = samples[index], value.isFinite else { continue }
                    let dots = Int((max(0, min(maximum, value)) / maximum * Double(rect.height * 4)).rounded())
                    for dot in 0..<4 where (rect.height - 1 - row) * 4 + (3 - dot) < dots { mask |= 1 << bits[side][dot] }
                }
                put(rect.x + col, rect.y + row, mask == 0 ? " " : Character(UnicodeScalar(0x2800 + mask)!), style)
            }
        }
    }
    /// A measured-value ring at Braille resolution. Missing values retain only the track.
    public mutating func gauge(_ value: Double?, in rect: TerminalRect, style: String) {
        guard rect.width >= 7, rect.height >= 3 else { return }
        if pixelGraphics {
            let reading = value.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
            graphics.append(.gauge(rect, reading, style))
            let label = reading.map { String(format: "%.0f%%", $0) } ?? "--"
            text(label, x: rect.x + (rect.width - label.count) / 2, y: rect.y + rect.height / 2, width: label.count, style: "1;" + style)
            return
        }
        let fraction = value.flatMap { $0.isFinite ? min(100, max(0, $0)) / 100 : nil }
        let bits = [[0, 1, 2, 6], [3, 4, 5, 7]]
        let rx = Double(rect.width * 2 - 1) / 2, ry = Double(rect.height * 4 - 1) / 2
        for row in 0..<rect.height {
            for col in 0..<rect.width {
                var track = 0, active = 0
                for dx in 0..<2 {
                    for dy in 0..<4 {
                        let px = (Double(col * 2 + dx) - rx) / rx
                        let py = (Double(row * 4 + dy) - ry) / ry
                        let radius = sqrt(px * px + py * py)
                        guard radius >= 0.73, radius <= 1.08 else { continue }
                        let bit = 1 << bits[dx][dy]
                        track |= bit
                        var angle = atan2(px, -py)
                        if angle < 0 { angle += 2 * .pi }
                        if let fraction, fraction > 0, angle / (2 * .pi) <= fraction { active |= bit }
                    }
                }
                let mask = active > 0 ? active : track
                if mask > 0 { put(rect.x + col, rect.y + row, Character(UnicodeScalar(0x2800 + mask)!), active > 0 ? style : MengohPalette.foreground(0x3A3F46)) }
            }
        }
        let label = fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "--"
        text(label, x: rect.x + (rect.width - label.count) / 2, y: rect.y + rect.height / 2, width: label.count, style: "1;" + style)
    }

    /// Filled history with a bright crest and a subdued grid. No synthesized samples.
    public mutating func chart(_ values: [Double?], in rect: TerminalRect, maximum: Double = 100, color: UInt32) {
        guard rect.width > 0, rect.height > 0, maximum.isFinite, maximum > 0 else { return }
        if pixelGraphics {
            graphics.append(.chart(rect, values.suffix(rect.width * 2).map { $0.flatMap { $0.isFinite ? $0 : nil } }, maximum, color))
            return
        }
        let samples = Array(values.suffix(rect.width * 2))
        let padding = rect.width * 2 - samples.count
        let bits = [[0, 1, 2, 6], [3, 4, 5, 7]]
        let ink = MengohPalette.foreground(color)
        let shadow = ((color & 0xFEFEFE) >> 1)
        for row in 0..<rect.height {
            for col in 0..<rect.width {
                var mask = 0, crest = false, measured = false
                for side in 0..<2 {
                    let index = col * 2 + side - padding
                    guard index >= 0, index < samples.count, let value = samples[index], value.isFinite else { continue }
                    measured = true
                    let dots = max(1, Int((max(0, min(maximum, value)) / maximum * Double(rect.height * 4)).rounded()))
                    for dot in 0..<4 {
                        let level = (rect.height - 1 - row) * 4 + 3 - dot
                        if level < dots { mask |= 1 << bits[side][dot] }
                        if level == dots - 1 { crest = true }
                    }
                }
                if mask > 0 {
                    put(rect.x + col, rect.y + row, Character(UnicodeScalar(0x2800 + mask)!), crest ? ink : MengohPalette.foreground(shadow))
                } else if col % 8 == 0 {
                    put(rect.x + col, rect.y + row, "·", MengohPalette.foreground(0x303640))
                } else if row == rect.height - 1 && !measured {
                    put(rect.x + col, rect.y + row, "─", MengohPalette.foreground(0x303640))
                }
            }
        }
    }

    public var plainRows: [String] {
        (0..<height).map { y in String(cells[(y * width)..<((y + 1) * width)].map(\.glyph)) }
    }
    public var ansiRows: [String] {
        (0..<height).map { y in
            var result = "", previous = ""
            for cell in cells[(y * width)..<((y + 1) * width)] {
                if cell.style != previous { let style = cell.style == "0" ? baseStyle : baseStyle + ";" + cell.style
                    result += "\u{1b}[0;\(style)m"; previous = cell.style }
                result.append(cell.glyph)
            }
            return result + "\u{1b}[0m"
        }
    }
}
