import Foundation
import Testing
import QuietCore
@testable import QuietSilicon

@Test func nativeInferenceAdmission() throws {
    try SiliconRuntime.validate(prompt: "Hello", quiet: false, thermal: .nominal)
    try SiliconRuntime.validate(prompt: "Hello", quiet: false, thermal: .fair)
    for thermal in [ThermalLevel.unknown, .serious, .critical] {
        #expect(throws: QuietError.self) { try SiliconRuntime.validate(prompt: "Hello", quiet: false, thermal: thermal) }
    }
    #expect(throws: QuietError.self) { try SiliconRuntime.validate(prompt: "Hello", quiet: true, thermal: .nominal) }
    #expect(throws: QuietError.self) { try SiliconRuntime.validate(prompt: "  \n", quiet: false, thermal: .nominal) }
    #expect(throws: QuietError.self) { try SiliconRuntime.validate(prompt: String(repeating: "界", count: 2667), quiet: false, thermal: .nominal) }
}
@Test func nativeQuietStopsAndRejectsWork() async throws {
    let runtime = SiliconRuntime()
    async let first: Void = runtime.setQuiet(true)
    async let second: Void = runtime.stop()
    _ = await (first, second)
    let state = await runtime.snapshot()
    #expect(!state.busy)
    #expect(state.loadedModel == nil)
    await #expect(throws: QuietError.self) { try await runtime.run(backend: .apple, directory: nil, prompt: "Hello") }
}
