import CoreML
import Foundation
import FoundationModels
import Metal

public struct SiliconHardware: Sendable {
    public var gpuName: String
    public var unifiedMemory: Bool
    public var recommendedGPUBytes: UInt64
    public var neuralEngineCores: Int
    public var appleAvailable: Bool
    public var appleStatus: String
    public static func read() -> Self {
        let gpu = MTLCreateSystemDefaultDevice()
        let cores = MLComputeDevice.allComputeDevices.reduce(0) { count, device in
            if case .neuralEngine(let engine) = device { return count + engine.totalCoreCount }
            return count
        }
        var available = false
        var status = "Requires macOS 26 or later"
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: available = true; status = "On-device model ready"
            case .unavailable(.appleIntelligenceNotEnabled): status = "Enable Apple Intelligence in System Settings"
            case .unavailable(.deviceNotEligible): status = "This Mac is not eligible for Apple Intelligence"
            case .unavailable(.modelNotReady): status = "Apple’s on-device model is not ready"
            case .unavailable: status = "Apple’s on-device model is unavailable"
            }
        }
        return Self(gpuName: gpu?.name ?? "No Metal device", unifiedMemory: gpu?.hasUnifiedMemory ?? false,
                    recommendedGPUBytes: gpu?.recommendedMaxWorkingSetSize ?? 0, neuralEngineCores: cores,
                    appleAvailable: available, appleStatus: status)
    }
}
