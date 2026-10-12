import Testing
@testable import QuietCore

@Test func synchronizedOutputNegotiationIsFragmentSafeAndNeverInput() {
    var input = TerminalInput()
    var events: [TerminalEvent] = []
    for byte in "\u{1b}[?2026;2$y".utf8 { events += input.feed([byte]) }
    #expect(events == [.synchronizedOutput(true)])
    #expect(input.feed(Array("\u{1b}[?2026;1$y".utf8)) == [.synchronizedOutput(true)])
    for state in [0, 3, 4] {
        #expect(input.feed(Array("\u{1b}[?2026;\(state)$y".utf8)) == [.synchronizedOutput(false)])
    }
    #expect(input.feed(Array("\u{1b}[?2026;99$y\u{1b}[?999;2$y".utf8)).isEmpty)
    let reply = "\u{1b}[?2026;2$y"
    #expect(input.feed(Array("\u{1b}[200~\(reply)\u{1b}[201~".utf8)) == [.paste(reply)])
    #expect(input.feed(Array("p".utf8)) == [.key("p")])
}

@Test func synchronizedFramesAreBalancedAndEmptyUpdatesStayEmpty() {
    let body = "\u{1b}[2J\u{1b}[1;1Hhello"
    #expect(TerminalSynchronizedOutput.frame(body, enabled: true)
            == TerminalSynchronizedOutput.begin + body + TerminalSynchronizedOutput.end)
    #expect(TerminalSynchronizedOutput.frame(body, enabled: false) == body)
    #expect(TerminalSynchronizedOutput.frame("", enabled: true).isEmpty)
}

@Test func framePacingIncludesWorkAndSkipsCatchUp() {
    var pacer = TerminalFramePacer()
    pacer.completed(started: 1, ended: 1.004)
    #expect(pacer.sleepMilliseconds(at: 1.004, animating: true) == 13)
    #expect(!pacer.due(at: 1.010))
    #expect(pacer.due(at: 1.020))
    pacer.completed(started: 2, ended: 2.050)
    #expect(pacer.framesPerSecond < 21)
    #expect(!pacer.due(at: 2.051))
    // A slow write never builds a queue of obsolete frames.
    pacer.completed(started: 3, ended: 3.4)
    #expect(pacer.due(at: 3.4))
    #expect(pacer.sleepMilliseconds(at: 3.4, animating: true) == 1)
    #expect(pacer.sleepMilliseconds(at: 3.4, animating: false) == 50)
    pacer.reset()
    #expect(pacer.framesPerSecond == 60)
}

@Test func measuredChartsReplaceOwnedPlacementsAndRetireMovedLayouts() {
    let r = TerminalRect(2, 4, 20, 5)
    let a = TerminalGraphic.chart(r, [10, nil, 30], 100, 0xFFFFFF)
    var graphics = WarpGraphics(imageBase: 1234, animated: false)
    #expect(graphics.update([a], at: 1).contains("a=T"))
    #expect(graphics.update([a], at: 2, redrawnRows: []).isEmpty)
    let redraw = graphics.update([a], at: 3, redrawnRows: [5])
    #expect(redraw.contains("a=d,d=I,i=1234"))
    #expect(redraw.contains("a=T") && !redraw.contains("a=p"))
    let moved = TerminalGraphic.chart(TerminalRect(2, 12, 20, 3), [40], 100, 0xFFFFFF)
    let replacement = graphics.update([moved], at: 4)
    #expect(replacement.hasPrefix("\u{1b}_Ga=d,d=I,i=1234"))
    #expect(replacement.contains("c=20,r=3"))
    #expect(!graphics.isAnimating && graphics.animate(at: 5).isEmpty)
    #expect(graphics.update([], at: 6).contains("a=d,d=I,i=1234"))
}
