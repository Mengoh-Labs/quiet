/// Physical occupancy, not Activity Monitor's Memory Used or memory pressure.
/// XNU free_count already includes speculative pages. Do not add them again.
public struct MemoryAccounting: Sendable {
    public let occupied: UInt64?
    public let occupiedPercent: Double?
    /// Residual outside the displayed active/wired/compressor/inactive categories.
    /// Unknown for missing or inconsistent counters; never invent a zero residual.
    public let other: UInt64?

    public init(total: UInt64, freePool: UInt64?, active: UInt64?, wired: UInt64?,
                compressed: UInt64?, inactive: UInt64?) {
        guard total > 0, let freePool, freePool <= total else {
            occupied = nil; occupiedPercent = nil; other = nil; return
        }
        let nonFree = total - freePool
        occupied = nonFree
        occupiedPercent = Double(nonFree) / Double(total) * 100
        var remaining = nonFree
        for value in [active, wired, compressed, inactive] {
            guard let value, value <= remaining else { other = nil; return }
            remaining -= value
        }
        other = remaining
    }
}
