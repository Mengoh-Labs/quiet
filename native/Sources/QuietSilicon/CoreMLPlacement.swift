import CoreML
import Foundation

/// A compute plan is compiler evidence, not a live utilization measurement.
enum CoreMLPlacement {
    static func describe(directory: URL, configuration: MLModelConfiguration) async -> String {
        let prefix = "Core ML: CPU + Neural Engine policy; GPU excluded."
        guard #available(macOS 14.4, *) else { return prefix + " Compute plan requires macOS 14.4." }
        do {
            let plan = try await MLComputePlan.load(contentsOf: directory, configuration: configuration)
            var counts: [String: Int] = [:]
            func add(_ usage: MLComputePlan.DeviceUsage?) {
                guard let usage else { counts["unreported", default: 0] += 1; return }
                let name: String
                switch usage.preferred {
                case .cpu: name = "CPU"
                case .gpu: name = "GPU"
                case .neuralEngine: name = "Neural Engine"
                @unknown default: name = "Unknown device"
                }
                counts[name, default: 0] += 1
            }
            func block(_ value: MLModelStructure.Program.Block) {
                for operation in value.operations {
                    add(plan.deviceUsage(for: operation))
                    for child in operation.blocks { block(child) }
                }
            }
            switch plan.modelStructure {
            case .program(let program): for function in program.functions.values { block(function.block) }
            case .neuralNetwork(let network): for layer in network.layers { add(plan.deviceUsage(for: layer)) }
            default: return prefix + " No operation plan for this model structure."
            }
            return prefix + " Planned operations: " + counts.keys.sorted().map { "\($0) \(counts[$0]!)" }.joined(separator: ", ") + ". Not live utilization."
        } catch { return prefix + " Compute plan unavailable: \(error.localizedDescription)" }
    }
}
