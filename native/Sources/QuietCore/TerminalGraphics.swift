import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum TerminalGraphic: Equatable, Sendable {
    case portrait(TerminalRect, Data)
    case keycap(TerminalRect, UInt32)
    case gauge(TerminalRect, Double?, String)
    case bar(TerminalRect, Double?, String)
    case chart(TerminalRect, [Double?], Double, UInt32, reveal: Double = 1)
    /// The rendered masthead: one image, so nothing on its rows needs repainting between changes.
    case header(TerminalRect, HeaderCard)
    /// A control drawn whole: tinted pill, accent key badge and label, in the header's style.
    case button(TerminalRect, key: String, label: String, accent: UInt32, enabled: Bool)

    public var rect: TerminalRect {
        switch self {
        case .portrait(let r, _), .keycap(let r, _), .gauge(let r, _, _), .bar(let r, _, _), .chart(let r, _, _, _, _), .header(let r, _), .button(let r, _, _, _, _): r
        }
    }

    /// Only the presentation moves. Labels and stored samples always retain measured values.
    public func interpolated(from old: TerminalGraphic, progress: Double) -> TerminalGraphic {
        guard rect == old.rect, progress < 1 else { return self }
        let t = max(0, min(1, progress)), eased = t * t * (3 - 2 * t)
        switch (old, self) {
        case (.gauge(_, let a?, let style), .gauge(let r, let b?, let next)) where style == next && a.isFinite && b.isFinite:
            return .gauge(r, a + (b - a) * eased, next)
        case (.bar(_, let a?, let style), .bar(let r, let b?, let next)) where style == next && a.isFinite && b.isFinite:
            return .bar(r, a + (b - a) * eased, next)
        case (.chart(_, let a, let scale, let color, let phase), .chart(let r, let b, let nextScale, let nextColor, _))
            where phase == 1 && scale == nextScale && color == nextColor && b.count > 1:
            // A single new measurement: scroll the existing line, revealing its newest segment.
            let overlap = b.count - 1
            guard a.count >= overlap, Array(a.suffix(overlap)) == Array(b.dropLast()) else { return self }
            return .chart(r, b, nextScale, nextColor, reveal: eased)
        default: return self
        }
    }

    fileprivate func pixelSize(cellWidth: Int, cellHeight: Int) -> (Int, Int)? {
        guard rect.width > 0, rect.height > 0, cellWidth > 0, cellHeight > 0 else { return nil }
        let rawWidth = Double(rect.width) * Double(cellWidth), rawHeight = Double(rect.height) * Double(cellHeight)
        let scale = min(1, 4800 / rawWidth, 4000 / rawHeight)
        return (max(1, Int(rawWidth * scale)), max(1, Int(rawHeight * scale)))
    }

    /// Chart overscan stores one extra sample-width so animation can move a crop window
    /// through a single PNG instead of rasterizing and transmitting a new PNG every frame.
    public func png(cellWidth: Int = 20, cellHeight: Int = 40, chartOverscan: Bool = false) -> Data? {
        guard let (w, h) = pixelSize(cellWidth: cellWidth, cellHeight: cellHeight) else { return nil }
        let extra: Int
        if case .chart = self, chartOverscan { extra = Int(ceil(Double(w) / Double(max(1, rect.width * 2 - 1)))) }
        else { extra = 0 }
        guard
              let context = CGContext(data: nil, width: w + extra, height: h, bitsPerComponent: 8, bytesPerRow: (w + extra) * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setAllowsAntialiasing(true)
        func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                    blue: CGFloat(rgb & 255) / 255, alpha: alpha)
        }
        func foreground(_ style: String) -> UInt32 {
            let codes = style.split(separator: ";").compactMap { UInt32($0) }
            if codes.count >= 5 {
                for i in 0...(codes.count - 5) where codes[i] == 38 && codes[i + 1] == 2 {
                    return (codes[i + 2] << 16) | (codes[i + 3] << 8) | codes[i + 4]
                }
            }
            return MengohPalette.signal
        }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        switch self {
        case .portrait(_, let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let diameter = max(1, min(bounds.width, bounds.height) - 6)
            let circle = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                                width: diameter, height: diameter)
            context.saveGState()
            context.addEllipse(in: circle); context.clip()
            context.setFillColor(color(0x19252B)); context.fill(circle)
            // Social-avatar framing: focus on Glyph's face rather than the full bust.
            // The source portrait stays unchanged; the circle deliberately crops ear tips.
            let scale = max(diameter / CGFloat(image.width), diameter / CGFloat(image.height)) * 1.45
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: circle.midX - size.width * 0.52,
                                          y: circle.midY - size.height * 0.40,
                                          width: size.width, height: size.height))
            context.restoreGState()
            context.setStrokeColor(color(MengohPalette.signal, 0.45)); context.setLineWidth(1.5)
            context.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))
        case .header(_, let card):
            card.draw(in: context, width: w, height: h)
        case .button(_, let key, let label, let accent, let enabled):
            // The pill fills the control's cells, so what looks like the button is what responds to a click.
            let unit = bounds.height / 40
            let pill = bounds.insetBy(dx: 3 * unit, dy: 3.5 * unit)
            let tone = enabled ? accent : 0x5A616B
            let path = CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)
            context.addPath(path); context.setFillColor(color(0x121A17, 0.96)); context.fillPath()
            context.addPath(path); context.setFillColor(color(tone, enabled ? 0.16 : 0.06)); context.fillPath()
            context.addPath(path); context.setStrokeColor(color(tone, enabled ? 0.9 : 0.5)); context.setLineWidth(max(1, 1.5 * unit)); context.strokePath()
            let diameter = pill.height - 8 * unit
            let badge = CGRect(x: pill.minX + 4.5 * unit, y: pill.midY - diameter / 2, width: diameter, height: diameter)
            context.setFillColor(color(tone, enabled ? 0.95 : 0.35)); context.fillEllipse(in: badge)
            let letter = HeaderCard.line(key, size: 18 * unit, bold: true, rgb: enabled ? 0x0B1410 : 0x15191D)
            context.textPosition = CGPoint(x: badge.midX - HeaderCard.width(letter) / 2, y: badge.midY - 18 * unit * 0.34)
            CTLineDraw(letter, context)
            let left = badge.maxX + 7 * unit, room = pill.maxX - 9 * unit - left
            let text = HeaderCard.fitted(label, size: 21 * unit, bold: false, rgb: enabled ? 0xE9EEEA : 0x858B93, limit: max(4, room))
            context.textPosition = CGPoint(x: left + max(0, room - HeaderCard.width(text)) / 2, y: pill.midY - 21 * unit * 0.34)
            CTLineDraw(text, context)
        case .keycap(_, let rgb):
            let r = bounds.insetBy(dx: 3, dy: 3)
            context.setFillColor(color(rgb))
            context.addPath(CGPath(roundedRect: r, cornerWidth: 9, cornerHeight: 9, transform: nil)); context.fillPath()
        case .gauge(_, let value, let style):
            let rgb = foreground(style)
            let center = CGPoint(x: w / 2, y: h / 2)
            let radius = CGFloat(min(w, h)) * 0.40
            context.setLineWidth(max(5, radius * 0.13)); context.setLineCap(.round)
            context.setStrokeColor(color(0x667080, 0.28))
            context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)); context.strokePath()
            if let value, value.isFinite, value > 0 {
                context.setStrokeColor(color(rgb))
                context.addArc(center: center, radius: radius, startAngle: .pi / 2,
                               endAngle: .pi / 2 - CGFloat(min(100, value) / 100) * 2 * .pi, clockwise: true)
                context.strokePath()
            }
        case .bar(_, let value, let style):
            let thickness = max(2, CGFloat(h) * 0.22)
            let track = CGRect(x: 0, y: (CGFloat(h) - thickness) / 2, width: CGFloat(w), height: thickness)
            context.setFillColor(color(0x667080, 0.28))
            context.addPath(CGPath(roundedRect: track, cornerWidth: thickness / 2, cornerHeight: thickness / 2, transform: nil)); context.fillPath()
            if let value, value.isFinite, value > 0 {
                let fill = CGRect(x: 0, y: track.minY, width: CGFloat(w) * CGFloat(min(100, value) / 100), height: thickness)
                context.setFillColor(color(foreground(style)))
                context.addPath(CGPath(roundedRect: fill, cornerWidth: min(thickness, fill.width) / 2,
                                       cornerHeight: thickness / 2, transform: nil)); context.fillPath()
            }
        case .chart(_, let values, let maximum, let rgb, let reveal):
            guard maximum.isFinite, maximum > 0 else { return nil }
            context.setStrokeColor(color(0x667080, 0.18)); context.setLineWidth(1)
            for row in 0...2 {
                let y = 2 + CGFloat(row) * CGFloat(h - 4) / 2
                context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: CGFloat(w + extra), y: y))
            }
            context.strokePath()
            let samples = Array(values.suffix(rect.width * 2))
            let step = CGFloat(w) / CGFloat(max(1, rect.width * 2 - 1))
            let padding = rect.width * 2 - samples.count
            var segment: [CGPoint] = []
            func drawSegment() {
                guard let first = segment.first, let last = segment.last else { return }
                if segment.count > 1 {
                    context.move(to: CGPoint(x: first.x, y: 2)); for point in segment { context.addLine(to: point) }
                    context.addLine(to: CGPoint(x: last.x, y: 2)); context.closePath()
                    context.setFillColor(color(rgb, 0.18)); context.fillPath()
                    context.addLines(between: segment); context.setStrokeColor(color(rgb)); context.setLineWidth(2.5); context.setLineJoin(.round); context.strokePath()
                } else {
                    context.setFillColor(color(rgb)); context.fillEllipse(in: CGRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4))
                }
                segment.removeAll(keepingCapacity: true)
            }
            for (i, value) in samples.enumerated() {
                guard let value, value.isFinite else { drawSegment(); continue }
                let offset = extra > 0 ? CGFloat(extra) : CGFloat(1 - min(1, max(0, reveal))) * step
                segment.append(CGPoint(x: CGFloat(padding + i) * step + offset,
                                       y: 2 + CGFloat(min(maximum, max(0, value)) / maximum) * CGFloat(h - 4)))
            }
            drawSegment()
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGCompressionFilter: IMAGEIO_PNG_FILTER_NONE]] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// What the rendered masthead shows. Equatable so an unchanged card is never re-rasterized or resent.
public struct HeaderCard: Equatable, Sendable {
    public struct Pill: Equatable, Sendable {
        public var text: String
        public var color: UInt32
        public init(_ text: String, _ color: UInt32) { self.text = text; self.color = color }
    }
    public var avatar: Data?
    public var name: String
    public var handle: String
    public var status: String
    public var statusColor: UInt32
    public var detail: String
    public var pills: [Pill]
    public init(avatar: Data?, name: String, handle: String, status: String, statusColor: UInt32, detail: String, pills: [Pill]) {
        self.avatar = avatar; self.name = name; self.handle = handle; self.status = status
        self.statusColor = statusColor; self.detail = detail; self.pills = pills
    }

    private static func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }
    fileprivate static func line(_ text: String, size: CGFloat, bold: Bool, rgb: UInt32) -> CTLine {
        let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): base,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(rgb)]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
    fileprivate static func width(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }
    /// Shorten with an ellipsis until the text fits; a clipped glyph would look like a rendering fault.
    fileprivate static func fitted(_ text: String, size: CGFloat, bold: Bool, rgb: UInt32, limit: CGFloat) -> CTLine {
        var value = text, result = line(value, size: size, bold: bold, rgb: rgb)
        while width(result) > limit, value.count > 1 {
            value = String(value.dropLast(value.hasSuffix("…") ? 2 : 1)) + "…"
            result = line(value, size: size, bold: bold, rgb: rgb)
        }
        return result
    }

    /// Draws into a context whose origin is the bottom-left corner, `width` by `height` pixels.
    func draw(in context: CGContext, width w: Int, height h: Int) {
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let unit = CGFloat(h) / 100                      // all metrics scale with the card's height
        let card = bounds.insetBy(dx: 2, dy: 3 * unit)
        let radius = 14 * unit
        context.addPath(CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(Self.color(0x0F3B2A, 0.92)); context.fillPath()
        context.addPath(CGPath(roundedRect: card.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setStrokeColor(Self.color(0x275E45)); context.setLineWidth(max(1.5, 1.6 * unit)); context.strokePath()

        var textX = card.minX + 16 * unit
        let diameter = card.height - 16 * unit
        if let avatar, let source = CGImageSourceCreateWithData(avatar as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let circle = CGRect(x: textX, y: card.midY - diameter / 2, width: diameter, height: diameter)
            context.saveGState()
            context.addEllipse(in: circle); context.clip()
            context.setFillColor(Self.color(0x19252B)); context.fill(circle)
            // Same face-centred framing as the intelligence panel's portrait.
            let scale = max(diameter / CGFloat(image.width), diameter / CGFloat(image.height)) * 1.45
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: circle.midX - size.width * 0.52, y: circle.midY - size.height * 0.40, width: size.width, height: size.height))
            context.restoreGState()
            context.setStrokeColor(Self.color(MengohPalette.signal, 0.7)); context.setLineWidth(max(1.5, 2 * unit))
            context.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))
            textX = circle.maxX + 14 * unit
        }

        // Pills: right-aligned, wrapping upward from the top row, within the right half of the card.
        let pillSize = 18 * unit, pillHeight = 30 * unit, gap = 8 * unit
        let pillLimit = card.width * 0.56
        var rows: [[(CTLine, CGFloat, UInt32)]] = [[]]
        var used: CGFloat = 0
        for pill in pills {
            let text = Self.line(pill.text, size: pillSize, bold: false, rgb: 0xE9EEEA)
            let span = Self.width(text) + 26 * unit
            if used + span + (rows[rows.count - 1].isEmpty ? 0 : gap) > pillLimit, !rows[rows.count - 1].isEmpty {
                guard rows.count < 2 else { break }
                rows.append([]); used = 0
            }
            used += span + (rows[rows.count - 1].isEmpty ? 0 : gap)
            rows[rows.count - 1].append((text, span, pill.color))
        }
        let block = CGFloat(rows.count) * pillHeight + CGFloat(rows.count - 1) * gap
        var pillLeft = card.maxX
        for (index, row) in rows.enumerated() {
            let y = card.midY + block / 2 - CGFloat(index + 1) * pillHeight - CGFloat(index) * gap
            var x = card.maxX - 14 * unit - row.reduce(0) { $0 + $1.1 } - CGFloat(max(0, row.count - 1)) * gap
            pillLeft = min(pillLeft, x)
            for (text, span, rgb) in row {
                let rect = CGRect(x: x, y: y, width: span, height: pillHeight)
                let path = CGPath(roundedRect: rect, cornerWidth: pillHeight / 2, cornerHeight: pillHeight / 2, transform: nil)
                context.addPath(path); context.setFillColor(Self.color(rgb, 0.16)); context.fillPath()
                context.addPath(path); context.setStrokeColor(Self.color(rgb, 0.9)); context.setLineWidth(max(1, 1.3 * unit)); context.strokePath()
                context.textPosition = CGPoint(x: x + 13 * unit, y: y + pillHeight / 2 - pillSize * 0.36)
                CTLineDraw(text, context)
                x += span + gap
            }
        }

        // Three text rows, clipped by ellipsis before they reach the pills.
        let limit = max(40 * unit, pillLeft - 12 * unit - textX)
        let nameLine = Self.line(name, size: 30 * unit, bold: true, rgb: 0xF3F1E6)
        let top = detail.isEmpty ? card.midY + 3 * unit : card.maxY - 35 * unit
        context.textPosition = CGPoint(x: textX, y: top); CTLineDraw(nameLine, context)
        let handleX = textX + Self.width(nameLine) + 9 * unit
        if handleX < textX + limit {
            context.textPosition = CGPoint(x: handleX, y: top)
            CTLineDraw(Self.fitted(handle, size: 19 * unit, bold: false, rgb: 0x9FB7AC, limit: textX + limit - handleX), context)
        }
        let statusY = top - 25 * unit
        let dot = CGRect(x: textX + 1 * unit, y: statusY + 2 * unit, width: 11 * unit, height: 11 * unit)
        context.setFillColor(Self.color(statusColor, 0.3)); context.fillEllipse(in: dot.insetBy(dx: -2.5 * unit, dy: -2.5 * unit))
        context.setFillColor(Self.color(statusColor)); context.fillEllipse(in: dot)
        context.textPosition = CGPoint(x: dot.maxX + 7 * unit, y: statusY)
        CTLineDraw(Self.fitted(status, size: 19 * unit, bold: false, rgb: 0x9FB7AC, limit: limit - 19 * unit), context)
        guard !detail.isEmpty else { return }
        context.textPosition = CGPoint(x: textX, y: statusY - 24 * unit)
        CTLineDraw(Self.fitted(detail, size: 19 * unit, bold: false, rgb: 0xD6DDD7, limit: limit), context)
    }
}

/// Owns only Quiet's images. Other applications' image IDs are never deleted.
public struct WarpGraphics {
    public static let probeID = 2_147_410_000
    public static let probe = "\u{1b}_Gi=\(probeID),s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\"
    private var cache: [Int: TerminalGraphic] = [:]
    private var rasterImages: [Int: Data] = [:]
    private struct Transition {
        var from: TerminalGraphic, to: TerminalGraphic
        var start: Double
    }
    private var targets: [Int: TerminalGraphic] = [:]
    private var transitions: [Int: Transition] = [:]
    private let duration: Double
    private let imageBase: Int
    private var cellWidth = 20, cellHeight = 40
    public init(imageBase: Int = Int.random(in: 1_000_000...2_000_000_000), animated: Bool = true) {
        self.imageBase = imageBase; duration = animated ? 0.3 : 0
    }
    public var isAnimating: Bool { !transitions.isEmpty }
    public mutating func cellSize(width: Int, height: Int) -> String {
        guard (4...64).contains(width), (8...128).contains(height) else { return "" }
        let w = width * 2, h = height * 2
        guard w != cellWidth || h != cellHeight else { return "" }
        cellWidth = w; cellHeight = h
        return reset()
    }
    public static func requested(environment: [String: String]) -> Bool {
        if environment["QUIET_RENDERER"] == "text" { return false }
        if environment["QUIET_RENDERER"] == "warp" { return true }
        // Query capabilities, not the terminal brand: sudo/launchers can strip TERM_PROGRAM.
        // The dashboard separately requires an interactive stdin/stdout before sending anything.
        return canQuery(environment: environment)
    }
    public static func canQuery(environment: [String: String]) -> Bool {
        let term = environment["TERM"] ?? ""
        return term != "dumb" && !term.hasPrefix("screen") && !term.hasPrefix("tmux")
            && (environment["TMUX"] ?? "").isEmpty && (environment["STY"] ?? "").isEmpty
    }
    public mutating func reset() -> String {
        let output = cache.keys.sorted().map(Self.delete).joined()
        cache.removeAll(); rasterImages.removeAll(); targets.removeAll(); transitions.removeAll(); return output
    }
    private static func delete(_ id: Int) -> String { "\u{1b}_Ga=d,d=I,i=\(id),q=2\u{1b}\\" }
    public mutating func update(_ graphics: [TerminalGraphic], at now: Double = ProcessInfo.processInfo.systemUptime,
                                redrawnRows: Set<Int>? = nil) -> String {
        var result = "", current: Set<Int> = []
        let layoutChanged = !targets.isEmpty && (targets.count != min(128, graphics.count)
            || graphics.prefix(128).enumerated().contains { targets[imageBase + $0.offset]?.rect != $0.element.rect })
        if layoutChanged { result += reset() }
        for (index, target) in graphics.prefix(128).enumerated() {
            let id = imageBase + index
            current.insert(id)
            if targets[id] != target {
                if duration > 0, let previous = cache[id], target.interpolated(from: previous, progress: 0) != target {
                    transitions[id] = Transition(from: previous, to: target, start: now)
                } else { transitions.removeValue(forKey: id) }
                targets[id] = target
            }
            let r = target.rect
            let needsPlacement = redrawnRows.map { rows in (r.y..<(r.y + r.height)).contains(where: rows.contains) } ?? true
            result += draw(frame(id, at: now) ?? target, id: id, placeUnchanged: needsPlacement)
        }
        for id in targets.keys.filter({ !current.contains($0) }) {
            if cache[id] != nil { result += Self.delete(id) }
            cache.removeValue(forKey: id); targets.removeValue(forKey: id); transitions.removeValue(forKey: id)
            rasterImages.removeValue(forKey: id)
        }
        return result
    }
    /// Called only during the short transition window; does not redraw text or resample metrics.
    public mutating func animate(at now: Double = ProcessInfo.processInfo.systemUptime, finish: Bool = false) -> String {
        var result = ""
        for id in transitions.keys.sorted() {
            if let graphic = frame(id, at: finish ? .infinity : now) {
                result += draw(graphic, id: id, placeUnchanged: false)
            }
        }
        return result
    }
    private mutating func frame(_ id: Int, at now: Double) -> TerminalGraphic? {
        guard let transition = transitions[id] else { return targets[id] }
        let progress = (now - transition.start) / duration
        if progress >= 1 { transitions.removeValue(forKey: id); return transition.to }
        return transition.to.interpolated(from: transition.from, progress: progress)
    }
    private mutating func draw(_ graphic: TerminalGraphic, id: Int, placeUnchanged: Bool) -> String {
        let r = graphic.rect
        let cursor = "\u{1b}[\(r.y + 1);\(r.x + 1)H"
        guard cache[id] != graphic || placeUnchanged else { return "" }
        let cleanup = cache[id] == nil ? "" : Self.delete(id)
        let png: Data
        if cache[id] == graphic, let stored = rasterImages[id] { png = stored }
        else {
            guard let rendered = graphic.png(cellWidth: cellWidth, cellHeight: cellHeight) else { return "" }
            png = rendered
        }
        cache[id] = graphic; rasterImages[id] = png
        return cleanup + cursor + Self.transmit(png, id: id, rect: r)
    }

    public static func transmit(_ png: Data, id: Int, rect: TerminalRect, source: TerminalRect? = nil) -> String {
        let bytes = Array(png.base64EncodedString().utf8)
        var result = ""
        for start in stride(from: 0, to: bytes.count, by: 4096) {
            let end = min(bytes.count, start + 4096)
            let crop = source.map { "x=\($0.x),y=\($0.y),w=\($0.width),h=\($0.height)," } ?? ""
            let metadata = start == 0 ? "a=T,t=d,f=100,i=\(id),p=1,\(crop)c=\(rect.width),r=\(rect.height),C=1,z=-1,q=2," : ""
            result += "\u{1b}_G\(metadata)m=\(end == bytes.count ? 0 : 1);" + String(decoding: bytes[start..<end], as: UTF8.self) + "\u{1b}\\"
        }
        return result
    }
}
