import Testing
@testable import QuietCore

@Test func physicalOccupancyIncludesInactiveAndReconcilesResidual() {
    // Tenths of a GiB for an exact integer fixture matching the screenshot.
    let m = MemoryAccounting(total: 1280, freePool: 17, active: 509, wired: 105, compressed: 126, inactive: 514)
    #expect(m.occupied == 1263)
    #expect(m.other == 9) // Displayed category values round independently.
    #expect(m.occupiedPercent == 1263.0 / 1280.0 * 100)
    #expect(509 + 105 + 126 + 514 + m.other! + 17 == 1280)
}

@Test func missingOrInconsistentCountersDoNotInventMemory() {
    let absent = MemoryAccounting(total: 100, freePool: nil, active: 1, wired: 1, compressed: 1, inactive: 1)
    #expect(absent.occupied == nil && absent.other == nil && absent.occupiedPercent == nil)
    let badFree = MemoryAccounting(total: 100, freePool: 101, active: nil, wired: nil, compressed: nil, inactive: nil)
    #expect(badFree.occupied == nil)
    let partial = MemoryAccounting(total: 100, freePool: 10, active: nil, wired: 1, compressed: 1, inactive: 1)
    #expect(partial.occupied == 90 && partial.other == nil)
    let inconsistent = MemoryAccounting(total: 100, freePool: 10, active: 80, wired: 20, compressed: 0, inactive: 0)
    #expect(inconsistent.occupied == 90 && inconsistent.other == nil)
    let overflow = MemoryAccounting(total: UInt64.max, freePool: 0, active: UInt64.max, wired: 1, compressed: 0, inactive: 0)
    #expect(overflow.other == nil)
    let empty = MemoryAccounting(total: 100, freePool: 100, active: 0, wired: 0, compressed: 0, inactive: 0)
    #expect(empty.occupied == 0 && empty.other == 0 && empty.occupiedPercent == 0)
}
