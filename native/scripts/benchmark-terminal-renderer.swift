// Compile with the terminal primitives from QuietCore; see QUIET-CLI.md.
// Measures host-side encoding/transport preparation, not Warp's compositor.
import Foundation

@main struct RendererBenchmark {
    static func main() throws {
        let wide = CommandLine.arguments.contains("--wide")
        let width = wide ? 90 : 60, height = wide ? 12 : 7
        func tiles(_ tick: Int) -> [TerminalGraphic] {
            let style = MengohPalette.foreground(MengohPalette.moss)
            var tiles: [TerminalGraphic] = (0..<10).map { .keycap(TerminalRect($0 * 12, 2, 3, 1), 0x303640) }
            for i in 0..<2 {
                tiles.append(.gauge(TerminalRect(2, 4 + i * 7, 13, 5), Double((tick * 13 + i * 31) % 100), style))
            }
            for i in 0..<24 {
                tiles.append(.bar(TerminalRect(100 + i / 12 * 30, 4 + i % 12, 24, 1), Double((tick * 11 + i * 7) % 100), style))
            }
            for i in 0..<7 {
                let values: [Double?] = (0..<(width * 2)).map { n in
                    let phase = n + tick
                    return phase % 37 == 0 ? nil : 50 + sin(Double(phase + i * 3) / 8) * 40
                }
                tiles.append(.chart(TerminalRect(18, 4 + i * (height + 1), width, height), values, 100, MengohPalette.research))
            }
            return tiles
        }
        var renderer = WarpGraphics(imageBase: 1000)
        _ = renderer.update(tiles(0), at: 0)
        var times: [Double] = [], bytes = 0, idleBytes = 0
        for tick in 1...6 {
            let time = Double(tick)
            _ = renderer.update(tiles(tick), at: time)
            for frame in 1...19 {
                let start = ProcessInfo.processInfo.systemUptime
                let output = renderer.animate(at: time + Double(frame) / 60)
                times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                bytes += output.utf8.count
            }
            idleBytes += renderer.update(tiles(tick), at: time + 0.5, redrawnRows: []).utf8.count
        }
        times.sort()
        let summary: [String: Any] = [
            "fixture": wide ? "wide" : "normal", "tiles": tiles(0).count, "frames": times.count,
            "encode_ms_p50": times[times.count / 2], "encode_ms_p95": times[Int(Double(times.count - 1) * 0.95)],
            "encode_ms_max": times.last ?? 0, "encode_ms_total": times.reduce(0, +),
            "wire_bytes": bytes, "unchanged_update_bytes": idleBytes
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
