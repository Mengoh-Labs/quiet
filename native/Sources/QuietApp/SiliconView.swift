import AppKit
import QuietCore
import QuietSilicon
import SwiftUI

struct AccelerationPage: View {
    @Bindable var model: QuietModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            QuietPageHero(painting: .acceleration, eyebrow: "APPLE SILICON / LOCAL INTELLIGENCE",
                          title: "Closer to the silicon.", subtitle: "Choose the runtime that fits the work. Every request stays on this Mac.")
            hardware
            Picker("Inference runtime", selection: $model.engine) {
                Text("Apple Intelligence").tag("Apple Intelligence")
                Text("MLX · Metal").tag("MLX")
                Text("Core ML · Neural Engine").tag("Core ML")
                Text("Ollama").tag("Ollama")
            }.pickerStyle(.segmented).labelsHidden().disabled(model.siliconPending || model.silicon.busy || model.runtimePending || model.runtime.busy || model.changingMode)
            if model.engine == "Ollama" { OllamaPanel(model: model) }
            else { nativeControls }
        }
    }
    private var hardware: some View {
        HStack(spacing: 12) {
            hardwareCard("METAL GPU", value: model.hardware?.gpuName ?? "Checking…", detail: "Unified memory · MLX and Ollama", symbol: "cpu")
            hardwareCard("NEURAL ENGINE", value: model.hardware.map { $0.neuralEngineCores > 0 ? "\($0.neuralEngineCores) cores available" : "Not reported" } ?? "Checking…", detail: "Core ML capability · not utilization", symbol: "brain.head.profile")
            hardwareCard("APPLE INTELLIGENCE", value: model.hardware?.appleAvailable == true ? "Available" : "Not ready", detail: model.hardware?.appleStatus ?? "Checking on-device model", symbol: "sparkles")
        }
    }
    private func hardwareCard(_ title: String, value: String, detail: String, symbol: String) -> some View {
        QuietCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Eyebrow(text: title); Spacer(); Image(systemName: symbol).foregroundStyle(QuietTheme.accent) }
                Text(value).font(.system(size: 17, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.system(size: 10)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var nativeControls: some View {
        HStack(alignment: .top, spacing: 18) {
            QuietCard {
                VStack(alignment: .leading, spacing: 16) {
                    Eyebrow(text: "01 / LOCAL REQUEST")
                    Text(model.engine == "MLX" ? "Your model. Apple’s GPU." : model.engine == "Core ML" ? "Core ML, on device." : "Apple’s on-device model.").font(QuietTheme.heading(24))
                    if model.engine != "Apple Intelligence" {
                        Button(model.engine == "MLX" ? "Choose MLX model folder…" : "Choose Core ML model…") { model.chooseMLXFolder() }
                        Text(model.engine == "Core ML" ? (model.coreMLDirectory.isEmpty ? "Compiled .mlmodelc · input JSON: {\"feature\": [numbers]}" : model.coreMLDirectory) : (model.mlxDirectory.isEmpty ? "Local safetensors model and tokenizer. No automatic downloads." : model.mlxDirectory))
                            .font(.system(size: 10)).foregroundStyle(QuietTheme.muted).textSelection(.enabled).lineLimit(3)
                    } else {
                        Text(model.hardware?.appleStatus ?? "Checking availability…").font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
                        if model.hardware?.appleAvailable != true {
                            Button("Refresh availability") { model.refreshHardware() }
                        }
                    }
                    TextEditor(text: model.engine == "Core ML" ? $model.coreMLInput : $model.nativeInput).font(.system(size: 12)).frame(height: 110).padding(8)
                        .scrollContentBackground(.hidden).background(QuietTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("Run locally ↗") { model.runNative() }.buttonStyle(QuietButton())
                            .disabled(model.siliconPending || model.silicon.busy || model.runtimePending || model.runtime.busy || model.changingMode || model.queue.mode == .quiet || !model.telemetry.thermal.admitsWork || (model.engine == "MLX" ? model.mlxDirectory.isEmpty : model.engine == "Core ML" ? model.coreMLDirectory.isEmpty : model.hardware?.appleAvailable != true))
                        Button("Stop & release") { model.stopNative() }.buttonStyle(QuietButton(prominent: false))
                    }
                    Text(model.engine == "Core ML" ? "One prediction at a time. Use JSON arrays matching the model’s input names and shapes. Quiet holds further work; existing apps keep running." : "One request at a time · 128 output tokens maximum. Quiet cancels Quiet’s request and releases its MLX model. Existing apps keep running.")
                        .font(.system(size: 11)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: 390)
            VStack(alignment: .leading, spacing: 16) {
                QuietCard {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack { Eyebrow(text: "02 / RUNTIME EVIDENCE"); Spacer(); if model.siliconPending || model.silicon.busy { ProgressView().controlSize(.small) } }
                        Text(model.silicon.status).font(.system(size: 14, weight: .medium))
                        if let result = model.silicon.result {
                            Text(result.backend.rawValue).font(.system(size: 19, weight: .medium))
                            Text(result.placement).font(.system(size: 11)).foregroundStyle(QuietTheme.muted)
                            HStack { Text("Request \(latency(result.milliseconds))"); Spacer(); Text("Load \(latency(result.loadMilliseconds))") }.font(.system(size: 11)).monospacedDigit()
                            if let bytes = result.allocationBytes { Text("MLX active allocations \(memory(UInt64(max(0, bytes))))").font(.system(size: 10)).foregroundStyle(QuietTheme.muted) }
                            Divider()
                            ScrollView { Text(result.output).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 130, maxHeight: 250)
                        } else { Text("Run a request to see output, latency and the runtime’s execution path.").font(.system(size: 12)).foregroundStyle(QuietTheme.muted) }
                    }.fixedSize(horizontal: false, vertical: true)
                }
                Text(model.engine == "MLX" ? "MLX uses the Metal GPU and CPU; it does not target the Neural Engine. Idle MLX weights are released after five minutes. Latency depends on the model, quantization and input." : model.engine == "Core ML" ? "Core ML allows CPU and Neural Engine execution, excluding GPU. Operators may fall back to CPU. This runner accepts fixed-shape numeric tensors; it does not convert GGUF or MLX models into Neural Engine models." : "Apple selects the processors for its on-device model. The public API does not report GPU or Neural Engine placement. Quiet never uses Private Cloud Compute or silently falls back to another provider.")
                    .font(.system(size: 11)).foregroundStyle(QuietTheme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity)
        }
    }
}

struct GlyphArtwork: View {
    private static let artwork: NSImage? = Bundle.main.url(forResource: "Glyph-avatar", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        if let image = Self.artwork {
            Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("Glyph, Quiet’s canonical robot companion")
        }
    }
}
