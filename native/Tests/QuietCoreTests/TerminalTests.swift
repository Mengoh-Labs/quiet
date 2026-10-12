import Foundation
import Testing
@testable import QuietCore

@Test func terminalInputHandlesFragmentsAndMouse() {
    var input = TerminalInput()
    #expect(input.feed([27,91]).isEmpty)
    #expect(input.feed([65]) == [.key("up")])
    #expect(input.feed(Array("\u{1b}[<0;12;15M".utf8)) == [.mouse(button: 0, x: 12, y: 15)])
    #expect(input.feed(Array("\u{1b}[<0;12;15m".utf8)).isEmpty)
    #expect(input.feed(Array("\u{1b}[<64;12;15M".utf8)) == [.mouse(button: 64, x: 12, y: 15)])
    #expect(input.feed([27]).isEmpty)
    #expect(input.flushEscape() == [.key("escape")])
}
@Test func terminalPasteCannotTriggerActions() {
    var input = TerminalInput()
    #expect(input.feed(Array("\u{1b}[200~ryq\n".utf8)).isEmpty)
    #expect(input.feed(Array("\u{1b}[20".utf8)).isEmpty)
    #expect(input.feed(Array("1~".utf8)) == [.paste("ryq\n")])
    #expect(input.feed(Array("i".utf8)) == [.key("i")])
}
@Test func terminalTreatsOutputAsData() {
    let text = TerminalText.safe("evil\u{1b}[2J\n\u{7}name")
    #expect(!text.contains("\u{1b}")); #expect(!text.contains("\n")); #expect(!text.contains("\u{7}"))
    #expect(TerminalText.fit("123456", width: 3) == "123")
    #expect(TerminalText.fit("x", width: 3) == "x  ")
}

@Test func terminalCanvasClipsAndSanitizesWithoutBreakingCellWidth() {
    var canvas = TerminalCanvas(width: 20, height: 8)
    canvas.box(TerminalRect(0, 0, 20, 8), title: "TEST", style: "36")
    canvas.text("evil\u{1b}[2J\nvalue", x: 1, y: 1, width: 18)
    canvas.fill(TerminalRect(-10, -10, 12, 12), style: "7")
    canvas.bar(200, x: 2, y: 3, width: 40)
    #expect(canvas.plainRows.count == 8)
    #expect(canvas.plainRows.allSatisfy { $0.count == 20 && !$0.contains("\u{1b}") && !$0.contains("\n") })
    #expect(canvas.plainRows[7].first == "╰")
    #expect(canvas.ansiRows.count == 8)
}

@Test func terminalGraphsRespectMissingSamplesScaleAndBrailleOrientation() {
    var canvas = TerminalCanvas(width: 3, height: 2)
    canvas.graph([nil, nil, 0, 0, 100, 100], in: TerminalRect(0, 0, 3, 2))
    #expect(canvas.plainRows == ["  ⣿", "  ⣿"])
    var half = TerminalCanvas(width: 1, height: 2)
    half.graph([50, 50], in: TerminalRect(0, 0, 1, 2))
    #expect(half.plainRows == [" ", "⣿"])
    var corner = TerminalCanvas(width: 1, height: 1)
    corner.graph([nil, 25], in: TerminalRect(0, 0, 1, 1))
    #expect(corner.plainRows == ["⢀"])
    var invalid = TerminalCanvas(width: 1, height: 1)
    invalid.graph([Double.nan, Double.infinity], in: TerminalRect(0, 0, 1, 1))
    #expect(invalid.plainRows == [" "])
}

@Test func coreTicksHandleWrapMissingAndIdleIntervals() {
    #expect(Sampler.tickPercent(previous: [0,0,0,0], current: [40,10,50,0]) == 50)
    #expect(Sampler.tickPercent(previous: [10,10,10,10], current: [10,10,20,10]) == 0)
    #expect(Sampler.tickPercent(previous: [.max - 4,0,0,0], current: [5,0,10,0]) == 50)
    #expect(Sampler.tickPercent(previous: [1,2,3,4], current: [1,2,3,4]) == nil)
    #expect(Sampler.tickPercent(previous: [], current: []) == nil)
}

@Test func addedProcessCountersRemainBackwardCompatible() throws {
    let process = NativeProcess.read(getpid())!
    #expect((process.threads ?? 0) > 0)
    #expect(process.parentPID != nil)
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(process)) as! [String: Any]
    object.removeValue(forKey: "threads"); object.removeValue(forKey: "parentPID")
    let restored = try JSONDecoder().decode(ProcessSample.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(restored.id == process.id)
    #expect(restored.threads == nil && restored.parentPID == nil)
}

@Test func terminalGaugesKeepMeasuredValuesAndClampSafely() {
    for (value, label) in [(Optional(0.0), "0%"), (50, "50%"), (100, "100%"), (200, "100%"), (nil, "--"), (.nan, "--")] {
        var canvas = TerminalCanvas(width: 15, height: 7)
        canvas.gauge(value, in: TerminalRect(1, 1, 13, 5), style: "32")
        #expect(canvas.plainRows[3].contains(label))
        #expect(canvas.plainRows.allSatisfy { $0.count == 15 })
        #expect(canvas.plainRows[0] == String(repeating: " ", count: 15))
        #expect(canvas.plainRows.joined().unicodeScalars.contains { (0x2801...0x28ff).contains($0.value) })
    }
}

@Test func terminalChartsDistinguishMissingFromMeasuredZero() {
    var missing = TerminalCanvas(width: 4, height: 2)
    missing.chart([nil, .nan], in: TerminalRect(0, 0, 4, 2), color: MengohPalette.signal)
    #expect(!missing.plainRows.joined().unicodeScalars.contains { (0x2801...0x28ff).contains($0.value) })
    var measured = TerminalCanvas(width: 4, height: 2)
    measured.chart([0, 100], in: TerminalRect(0, 0, 4, 2), color: MengohPalette.signal)
    #expect(measured.plainRows[0].last == "⢸")
    #expect(measured.plainRows[1].last == "⣸")
    #expect(measured.plainRows.allSatisfy { $0.count == 4 })
}
