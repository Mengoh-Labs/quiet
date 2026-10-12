import Foundation
import ImageIO
import Testing
@testable import QuietCore

@Test func warpSelectionIsExplicitAndConservative() {
    #expect(WarpGraphics.requested(environment: ["TERM_PROGRAM": "WarpTerminal"]))
    #expect(WarpGraphics.requested(environment: ["TERM_PROGRAM": "iTerm.app"]))
    #expect(WarpGraphics.requested(environment: [:]))
    #expect(WarpGraphics.requested(environment: ["TERM": "xterm-256color"]))
    #expect(!WarpGraphics.requested(environment: ["TERM": "dumb"]))
    #expect(!WarpGraphics.requested(environment: ["TERM": "screen-256color"]))
    #expect(!WarpGraphics.requested(environment: ["TERM": "tmux-256color"]))
    #expect(!WarpGraphics.requested(environment: ["TERM_PROGRAM": "WarpTerminal", "TMUX": "yes"]))
    #expect(!WarpGraphics.requested(environment: ["TERM_PROGRAM": "WarpTerminal", "QUIET_RENDERER": "text"]))
    #expect(WarpGraphics.requested(environment: ["QUIET_RENDERER": "warp"]))
}

@Test func graphicsRepliesNeverBecomeCommandsEvenWhenFragmentedOrLong() {
    var input = TerminalInput()
    let reply = "\u{1b}_Gi=\(WarpGraphics.probeID);OK\u{1b}\\"
    var events: [TerminalEvent] = []
    for byte in reply.utf8 { events += input.feed([byte]) }
    #expect(events == [.graphicsResponse(id: WarpGraphics.probeID, ok: true)])
    #expect(input.feed(Array("\u{1b}[6;20;10t".utf8)) == [.cellSize(width: 10, height: 20)])
    #expect(input.feed(Array("\u{1b}_Gi=5;ryq STOP\u{1b}\\".utf8)) == [.graphicsResponse(id: 5, ok: false)])
    #expect(input.feed([27,95]).isEmpty)
    for _ in 0..<20 { #expect(input.feed(Array(repeating: 121, count: 1024)).isEmpty) }
    #expect(input.feed([27,92]).isEmpty)
    #expect(input.feed(Array("\u{1b}]text ryq\u{7}p".utf8)) == [.key("p")])
    #expect(input.feed(Array("\u{1b}[200~\(reply)\u{1b}[201~".utf8)) == [.paste(reply)])
}

@Test func pixelTilesKeepValuesAsTextAndGenerateValidPNG() throws {
    var canvas = TerminalCanvas(width: 80, height: 26, pixelGraphics: true)
    canvas.keycap("s", x: 1, y: 2)
    canvas.gauge(42, in: TerminalRect(2, 4, 13, 5), style: MengohPalette.foreground(MengohPalette.signal))
    canvas.chart([nil, 0, 30, 100], in: TerminalRect(17, 4, 30, 5), color: MengohPalette.research)
    canvas.bar(55, x: 2, y: 12, width: 30)
    #expect(canvas.graphics.count == 4)
    #expect(canvas.plainRows[2].contains("s"))
    #expect(canvas.plainRows[6].contains("42%"))
    #expect(!canvas.plainRows.joined().contains("◖"))
    for tile in canvas.graphics {
        let png = try #require(tile.png())
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == tile.rect.width * 20 && image.height == tile.rect.height * 40)
    }
}

@Test func graphicsCacheReplacesAndDeletesOnlyOwnedTiles() {
    var graphics = WarpGraphics(imageBase: 1234)
    let tile = TerminalGraphic.keycap(TerminalRect(1, 2, 3, 1), 0x303640)
    let first = graphics.update([tile])
    #expect(first.contains("a=T") && first.contains("i=1234"))
    let unchanged = graphics.update([tile])
    #expect(unchanged.contains("a=T") && unchanged.contains("a=d,d=I") && unchanged.contains("p=1"))
    let removed = graphics.update([])
    #expect(removed.contains("a=d,d=I,i=1234"))
    #expect(graphics.reset().isEmpty)
    _ = graphics.update([tile])
    #expect(graphics.cellSize(width: 12, height: 24).contains("d=I,i=1234"))
    #expect(graphics.update([tile]).contains("a=T"))
}

@Test func graphicsTransportChunksBase64AndSuppressesReplies() {
    let png = Data(repeating: 255, count: 10_000)
    let command = WarpGraphics.transmit(png, id: 50, rect: TerminalRect(1, 1, 20, 5))
    let chunks = command.components(separatedBy: "\u{1b}_G").dropFirst()
    var payload = ""
    for chunk in chunks {
        let parts = chunk.dropLast(2).split(separator: ";", maxSplits: 1)
        #expect(parts.count == 2 && parts[1].count <= 4096)
        payload += parts[1]
    }
    #expect(Data(base64Encoded: payload) == png)
    #expect(command.contains("C=1,z=-1,q=2,m=1") && command.contains("m=0;"))
}

@Test func graphicsRepliesAllowPlacementFieldsAndEmptyMultiplexerVariables() {
    var input = TerminalInput()
    #expect(input.feed(Array("\u{1b}_Gi=2147410000,p=0;OK\u{1b}\\".utf8)) == [.graphicsResponse(id: WarpGraphics.probeID, ok: true)])
    #expect(input.feed(Array("\u{1b}_Gp=0,i=2147410000;OK\u{1b}\\".utf8)) == [.graphicsResponse(id: WarpGraphics.probeID, ok: true)])
    #expect(WarpGraphics.requested(environment: ["TERM_PROGRAM":"WarpTerminal", "TMUX":"", "STY":""]))
}

@Test func transitionsPreserveMeasurementsAndGaps() {
    let r = TerminalRect(0, 0, 10, 4), style = MengohPalette.foreground(MengohPalette.moss)
    let start = TerminalGraphic.gauge(r, 20, style), end = TerminalGraphic.gauge(r, 80, style)
    #expect(end.interpolated(from: start, progress: 0.5) == .gauge(r, 50, style))
    #expect(end.interpolated(from: start, progress: 1) == end)
    let missing = TerminalGraphic.gauge(r, nil, style)
    #expect(missing.interpolated(from: end, progress: 0) == missing)
    #expect(end.interpolated(from: missing, progress: 0) == end)
    let a = TerminalGraphic.chart(r, [10, nil, 30], 100, 0xFFFFFF)
    let b = TerminalGraphic.chart(r, [10, nil, 30, 50], 100, 0xFFFFFF)
    #expect(b.interpolated(from: a, progress: 0.5) == .chart(r, [10, nil, 30, 50], 100, 0xFFFFFF, reveal: 0.5))
    let rescaled = TerminalGraphic.chart(r, [10, nil, 30, 50], 200, 0xFFFFFF)
    #expect(rescaled.interpolated(from: a, progress: 0) == rescaled)
    let unrelated = TerminalGraphic.chart(r, [70, 80], 100, 0xFFFFFF)
    #expect(unrelated.interpolated(from: a, progress: 0) == unrelated)
}

@Test func animationSettlesWithoutIdleWorkAndCanBeDisabled() {
    let r = TerminalRect(0, 0, 10, 1), style = MengohPalette.foreground(MengohPalette.moss)
    let low = TerminalGraphic.bar(r, 10, style), high = TerminalGraphic.bar(r, 90, style)
    var graphics = WarpGraphics(imageBase: 1234)
    _ = graphics.update([low], at: 1)
    #expect(!graphics.isAnimating)
    _ = graphics.update([high], at: 2)
    #expect(graphics.isAnimating)
    let middle = graphics.animate(at: 2.15)
    #expect(middle.contains("a=T") && middle.contains("a=d,d=I"))
    #expect(!graphics.animate(at: 2.3).isEmpty)
    _ = graphics.animate(at: 2.31)
    #expect(!graphics.isAnimating && graphics.animate(at: 3).isEmpty)
    _ = graphics.update([low], at: 4)
    #expect(!graphics.animate(at: 4.01, finish: true).isEmpty)
    #expect(!graphics.isAnimating)
    _ = graphics.update([high], at: 5)
    _ = graphics.reset()
    #expect(!graphics.isAnimating && graphics.animate(at: 5.1).isEmpty)
    var still = WarpGraphics(imageBase: 1234, animated: false)
    _ = still.update([low], at: 1)
    #expect(still.update([high], at: 2).contains("a=T"))
    #expect(!still.isAnimating)
}

@Test func portraitFitsItsTileAndTextFallbackReservesNoImage() throws {
    let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Glyph-avatar.png")
    let data = try Data(contentsOf: asset)
    let rect = TerminalRect(2, 5, 8, 3)
    let png = try #require(TerminalGraphic.portrait(rect, data).png())
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 160 && image.height == 120)
    #expect(TerminalGraphic.portrait(rect, Data()).png() == nil)
    var text = TerminalCanvas(width: 80, height: 26)
    let hidden = text.portrait(data, in: rect)
    #expect(!hidden && text.graphics.isEmpty)
    var pixels = TerminalCanvas(width: 110, height: 34, pixelGraphics: true)
    let shown = pixels.portrait(data, in: rect)
    #expect(shown && pixels.graphics.count == 1)
    let clipped = pixels.portrait(data, in: TerminalRect(108, 33, 8, 3))
    #expect(!clipped && pixels.graphics.count == 1)
}

private func pixels(_ png: Data) -> (width: Int, height: Int, alpha: (Int, Int) -> UInt8)? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    guard let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let copy = bytes
    return (w, h, { x, y in copy[(y * w + x) * 4 + 3] })
}

@Test func headerCardRendersARoundedCardAtCellResolution() throws {
    let card = HeaderCard(avatar: nil, name: "Glyph", handle: "@quiet · 0.10.0", status: "live · every 2 s", statusColor: MengohPalette.signal,
                          detail: "Apple M3 Max · 16-core Neural Engine", pills: [.init("system view", MengohPalette.signal), .init("thermal Nominal", MengohPalette.ion)])
    let graphic = TerminalGraphic.header(TerminalRect(0, 0, 120, 3), card)
    #expect(graphic.rect == TerminalRect(0, 0, 120, 3))
    let png = try #require(graphic.png(cellWidth: 20, cellHeight: 40))
    let image = try #require(pixels(png))
    #expect(image.width == 2400 && image.height == 120)
    #expect(image.alpha(0, 0) == 0 && image.alpha(2399, 119) == 0, "rounded corners stay transparent over the terminal background")
    #expect(image.alpha(1200, 60) > 200, "the card body is filled")
    // Content is part of the image: any change produces a different image, an identical card the same one.
    var paused = card; paused.status = "paused · every 2 s"
    #expect(TerminalGraphic.header(TerminalRect(0, 0, 120, 3), paused) != graphic)
    #expect(TerminalGraphic.header(TerminalRect(0, 0, 120, 3), paused).png(cellWidth: 20, cellHeight: 40) != png)
    #expect(TerminalGraphic.header(TerminalRect(0, 0, 120, 3), card).png(cellWidth: 20, cellHeight: 40) == png)
    // A narrow card with long text and many pills must still render rather than overflow or fail.
    var crowded = card
    crowded.detail = String(repeating: "long machine description ", count: 20)
    crowded.pills = (0..<12).map { .init("pill number \($0)", MengohPalette.amber) }
    #expect(TerminalGraphic.header(TerminalRect(0, 0, 40, 3), crowded).png(cellWidth: 20, cellHeight: 40) != nil)
}

@Test func headerCardNeedsPixelGraphicsAndRoom() {
    let card = HeaderCard(avatar: nil, name: "Glyph", handle: "h", status: "s", statusColor: 0, detail: "d", pills: [])
    var text = TerminalCanvas(width: 120, height: 10)
    #expect(!text.header(card, in: TerminalRect(0, 0, 120, 3)) && text.graphics.isEmpty, "text mode keeps its text masthead")
    var pixel = TerminalCanvas(width: 120, height: 10, pixelGraphics: true)
    #expect(!pixel.header(card, in: TerminalRect(0, 0, 121, 3)) && pixel.graphics.isEmpty, "a card wider than the canvas is refused")
    #expect(pixel.header(card, in: TerminalRect(0, 0, 120, 3)) && pixel.graphics == [.header(TerminalRect(0, 0, 120, 3), card)])
}

@Test func renderedButtonCoversExactlyItsCellsAndCarriesItsOwnLabel() throws {
    var canvas = TerminalCanvas(width: 40, height: 3, pixelGraphics: true)
    let rect = TerminalRect(1, 1, 9, 1)
    let placed = canvas.button("s", label: "Sort", in: rect, accent: MengohPalette.ion)
    #expect(placed && canvas.graphics == [.button(rect, key: "s", label: "Sort", accent: MengohPalette.ion, enabled: true)])
    #expect(canvas.plainRows[1].allSatisfy { $0 == " " }, "the label is in the image; no text sits on the button's cells")
    // Refused when it cannot fit or graphics are off: the caller then draws a character keycap and label.
    let overflowing = canvas.button("s", label: "Sort", in: TerminalRect(36, 1, 9, 1), accent: 0)
    let tooNarrow = canvas.button("s", label: "Sort", in: TerminalRect(1, 1, 3, 1), accent: 0)
    #expect(!overflowing && !tooNarrow && canvas.graphics.count == 1)
    var text = TerminalCanvas(width: 40, height: 3)
    let inTextMode = text.button("s", label: "Sort", in: rect, accent: 0)
    #expect(!inTextMode && text.graphics.isEmpty)
    let png = try #require(canvas.graphics[0].png(cellWidth: 20, cellHeight: 40))
    let image = try #require(pixels(png))
    #expect(image.width == 180 && image.height == 40)
    #expect(image.alpha(0, 0) == 0 && image.alpha(179, 39) == 0 && image.alpha(90, 20) > 200, "rounded ends, filled body")
    func render(_ label: String, _ accent: UInt32, _ enabled: Bool) -> Data? {
        TerminalGraphic.button(rect, key: "s", label: label, accent: accent, enabled: enabled).png(cellWidth: 20, cellHeight: 40)
    }
    #expect(render("Sort", MengohPalette.ion, true) == png)
    #expect(render("Sort", MengohPalette.ion, false) != png && render("Size", MengohPalette.ion, true) != png && render("Sort", MengohPalette.amber, true) != png)
    #expect(render(String(repeating: "long label ", count: 10), MengohPalette.ion, true) != nil, "an over-long label is shortened, not a failure")
    // Escape sequences in a label never reach the graphic's stored text.
    var guarded = TerminalCanvas(width: 40, height: 3, pixelGraphics: true)
    let accepted = guarded.button("s", label: "a\u{1b}[2Jb", in: rect, accent: 0)
    #expect(accepted && guarded.graphics == [.button(rect, key: "s", label: "a [2Jb", accent: 0, enabled: true)])
}

@Test func identityCardWithoutAMachineLineStillRenders() throws {
    let card = HeaderCard(avatar: nil, name: "Glyph", handle: "Apple on-device", status: "local AI · 12:04", statusColor: MengohPalette.signal, detail: "", pills: [])
    let png = try #require(TerminalGraphic.header(TerminalRect(2, 10, 30, 3), card).png(cellWidth: 20, cellHeight: 40))
    let image = try #require(pixels(png))
    #expect(image.width == 600 && image.height == 120 && image.alpha(300, 60) > 200)
    var other = card; other.status = "paused"
    #expect(TerminalGraphic.header(TerminalRect(2, 10, 30, 3), other).png(cellWidth: 20, cellHeight: 40) != png)
}
