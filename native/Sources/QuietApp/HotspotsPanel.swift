import SwiftUI
import QuietCore

struct HotspotsPanel: View {
    @Bindable var model: QuietModel
    var body: some View {
        QuietCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Where to investigate").font(.system(size: 16, weight: .semibold))
                Text("Measured patterns · review before stopping · no automatic termination")
                    .font(.system(size: 11)).foregroundStyle(QuietTheme.muted)
                if model.hotspots.isEmpty {
                    Text("Watching for sustained load: ≥50% of one core for 30 seconds, or ≥20% for 60 seconds. Short spikes do not trigger findings.")
                        .font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
                }
                if model.terminationBusy { ProgressView("Inspecting or waiting for process exit…").controlSize(.small) }
                if let candidate = model.forceCandidate {
                    Button("Review force-stop for PID \(candidate.pid)…") { model.reviewStop(candidate) }
                        .disabled(model.terminationBusy)
                }
                ForEach(model.hotspots) { item in
                    let context = model.diagnosticContexts[item.id]
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(item.name).font(.system(size: 13, weight: .semibold))
                            Text("PID \(item.id.pid)").font(.system(size: 10)).foregroundStyle(QuietTheme.muted)
                            Spacer()
                            Text("\(Int(item.meanCPU))% of one core").font(.system(size: 12)).monospacedDigit()
                        }
                        Text("\(context?.role ?? "Process") · observed for \(Int(item.seconds))s · \(item.samples) recent samples")
                            .font(.system(size: 11)).foregroundStyle(QuietTheme.muted)
                        if let context {
                            if context.role == "Test runner", context.parentPID == 1, context.ageSeconds >= 3600 {
                                Text("Long-running test candidate · parent PID 1 · running \(Int(context.ageSeconds / 3600))h. Check whether it is still making progress.")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(QuietTheme.accent)
                            }
                            if let directory = context.workingDirectory {
                                Text(directory).font(.system(size: 10, design: .monospaced)).foregroundStyle(QuietTheme.muted).lineLimit(2).textSelection(.enabled)
                            }
                            Text(context.recommendation).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Context unavailable. CPU load is measured; its cause is not established.").font(.system(size: 12))
                        }
                        Button("Review stop…") { model.reviewStop(item.id) }
                            .disabled(model.terminationBusy).help("Inspect identity, test role, children and network sockets before offering a stop.")
                    }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                        .background(QuietTheme.paper, in: RoundedRectangle(cornerRadius: 10))
                }
                Text("\(model.telemetry.unreadableProcesses) processes were unreadable or exited during sampling. System and security-service CPU may be missing; this is not complete attribution. No stack samples or raw command lines are saved by Quiet.")
                    .font(.system(size: 10)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
