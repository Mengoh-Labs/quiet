import Testing
@testable import QuietCore

@Test func observatoryUsesOnlyActualSamplesAndResetsAfterGaps() {
    var window = ObservatoryWindow()
    window.observe(at: 0, values: ["cpuPercent": 10, "gpuPercent": .nan])
    window.observe(at: 2, values: ["cpuPercent": 30])
    window.observe(at: 4, values: [:])
    let trend = window.trends()["cpuPercent"]
    #expect(trend?.current == nil)
    #expect(trend?.mean == 20 && trend?.peak == 30 && trend?.measuredSamples == 2)
    #expect(window.trends()["gpuPercent"] == nil)
    window.observe(at: 40, values: ["cpuPercent": 5])
    #expect(window.count == 1 && window.seconds == 0)
}

@Test func ambientGateWaitsForEvidenceAndBoundsWork() {
    var window = ObservatoryWindow(), gate = AmbientInsightGate()
    func context() -> ObservatoryContext { ObservatoryContext(capturedAt: "now", window: window, thermal: "Nominal") }
    window.observe(at: 0, values: ["cpuPercent": 10])
    let decision1 = gate.shouldRequest(context(), at: 0, blocked: false)
    #expect(decision1 == false)
    window.observe(at: 2, values: ["cpuPercent": 10])
    window.observe(at: 4, values: ["cpuPercent": 10])
    let decision2 = gate.shouldRequest(context(), at: 4, blocked: true)
    #expect(decision2 == false)
    let decision3 = gate.shouldRequest(context(), at: 4, blocked: false)
    #expect(decision3 == true)
    window.observe(at: 6, values: ["cpuPercent": 80])
    let decision4 = gate.shouldRequest(context(), at: 6, blocked: false)
    #expect(decision4 == false)
    let decision5 = gate.shouldRequest(context(), at: 49, blocked: false)
    #expect(decision5 == true)
    let decision6 = gate.shouldRequest(context(), at: 100, blocked: false)
    #expect(decision6 == false)
    let decision7 = gate.shouldRequest(context(), at: 229, blocked: false)
    #expect(decision7 == true)
    gate.failed(at: 230)
    let decision8 = gate.shouldRequest(context(), at: 529, blocked: false)
    #expect(decision8 == false)
    let decision9 = gate.shouldRequest(context(), at: 530, blocked: false)
    #expect(decision9 == true)
}

@Test func ambientPromptPreservesUnknownsAndAllowsSilence() throws {
    var window = ObservatoryWindow()
    window.observe(at: 1, values: ["cpuPercent": 20])
    let context = ObservatoryContext(capturedAt: "now", window: window, thermal: "Nominal")
    let prompt = try ObservatoryPrompt.make(context, previous: "Things look steady.", ambient: true)
    #expect(prompt.contains("UNCHANGED") && prompt.contains("cpuPercent"))
    #expect(!prompt.contains("gpuPercent") && !prompt.contains("Next check:"))
    #expect(ObservatoryPrompt.instructions.contains("active paging"))
    #expect(!(try ObservatoryPrompt.make(context, previous: nil, ambient: false)).contains("UNCHANGED"))
}
