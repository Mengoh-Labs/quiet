import QuietCore
import SwiftUI

struct WorkloadsPage: View {
    @Bindable var model: QuietModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            QuietPageHero(painting: .workloads, eyebrow: "YOUR WORK, AT A BETTER PACE", title: "Make room for the work.", subtitle: "Only jobs explicitly launched here receive Quiet’s scheduling controls.")
            HStack(alignment: .top, spacing: 18) {
                QuietCard {
                    VStack(alignment: .leading, spacing: 17) {
                        Text("Launch a workload").font(.system(size: 16, weight: .semibold))
                        field("Executable", text: $model.executable)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Arguments · JSON array").font(.system(size: 11, weight: .medium))
                            TextEditor(text: $model.arguments).font(.system(size: 12, design: .monospaced))
                                .frame(height: 75).padding(7).scrollContentBackground(.hidden).background(QuietTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        }
                        field("Working directory", text: $model.directory)
                        Button { model.enqueue() } label: { Label("Add to queue", systemImage: "plus") }.buttonStyle(QuietButton())
                        Text("No shell expansion. No interactive input; output goes to /dev/null. Configure logs in the workload. Jobs run one at a time.")
                            .font(.system(size: 11)).foregroundStyle(QuietTheme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: 380)
                VStack(alignment: .leading, spacing: 18) {
                    QuietCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("Your queue").font(.system(size: 16, weight: .semibold)); Spacer(); StatusPill(text: model.queue.mode.rawValue, active: model.queue.mode != .observe) }
                            if model.queue.jobs.isEmpty {
                                ContentUnavailableView("No managed jobs", systemImage: "tray", description: Text("Existing apps keep running independently. Add a batch job to manage it here.")).frame(height: 200)
                            } else {
                                ForEach(model.queue.jobs.reversed()) { job in
                                    HStack {
                                        Image(systemName: job.state == "Running" ? "arrow.up.right" : "terminal").foregroundStyle(QuietTheme.accent)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(job.name).font(.system(size: 13, weight: .medium))
                                            Text(job.state + (job.background ? " · background scheduling" : "") + (job.identity.map { " · PID \($0.pid)" } ?? ""))
                                                .font(.system(size: 10)).foregroundStyle(QuietTheme.muted)
                                        }
                                        Spacer()
                                        if job.state == "Queued" { Button("Remove") { model.remove(job) }.buttonStyle(.borderless) }
                                    }.padding(.vertical, 9)
                                    Divider().opacity(0.5)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("A clear boundary.").font(QuietTheme.heading(24))
                        Text("Balanced waits through serious thermal pressure, backgrounds Quiet jobs, and restores normal scheduling after 30 seconds at nominal pressure. Quiet also holds the queue.")
                        Text("Background scheduling is not a CPU cap. Only the launched direct process is managed; descendants are not. Quitting Quiet restores scheduling and leaves running batch jobs alive.")
                    }.font(.system(size: 12)).foregroundStyle(QuietTheme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(4)
                }
            }
        }
    }
    private func field(_ name: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(name).font(.system(size: 11, weight: .medium))
            TextField(name, text: text).textFieldStyle(.roundedBorder).font(.system(size: 12))
        }
    }
}

struct OllamaPanel: View {
    @Bindable var model: QuietModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(eyebrow: "MATCH THE WORK TO THE SILICON", title: "A verified destination.", subtitle: "CPU ↔ Metal GPU for compatible local models. A separate runtime, under your control.")
            runtimeBar
            HStack(alignment: .top, spacing: 18) {
                controls.frame(maxWidth: 385)
                VStack(spacing: 16) {
                    placement
                    benchmark
                    result
                }.frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Offload the right work.").font(QuietTheme.heading(23))
                Text("This routes requests submitted through Quiet. It cannot migrate arbitrary processes or change another app’s backend. Neural Engine execution is unavailable in Ollama. GPU-assisted work can still use CPU and shared-chip power.")
                Text("New inference is held during serious, critical or unknown thermal pressure. Compare requires nominal pressure. Quiet mode stops this runtime. Idle models unload after five minutes.")
            }.font(.system(size: 11)).foregroundStyle(QuietTheme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var runtimeBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "cpu").font(.system(size: 20)).foregroundStyle(QuietTheme.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.runtime.busy ? model.runtime.operation : model.runtime.running ? "Local runtime ready" : "Local runtime stopped").font(.system(size: 13, weight: .medium))
                Text(model.runtime.endpoint.map { "Ollama \(model.runtime.version ?? "") · \($0) · cloud disabled" } ?? "Uses installed Ollama models. No downloads. Existing server untouched.")
                    .font(.system(size: 10)).foregroundStyle(QuietTheme.muted).textSelection(.enabled)
            }
            Spacer()
            if model.runtime.busy || model.runtimePending { ProgressView().controlSize(.small) }
            if model.runtime.running || model.runtime.busy {
                Button("Stop & release") { model.runtimeAction(.stop) }.buttonStyle(QuietButton(prominent: false))
            } else {
                Button("Start local runtime") { model.runtimeAction(.start) }.buttonStyle(QuietButton())
                    .disabled(model.runtimePending || model.runtime.installed == nil || model.queue.mode == .quiet)
            }
        }.padding(18).background(QuietTheme.banner, in: RoundedRectangle(cornerRadius: 14))
    }

    private var controls: some View {
        QuietCard {
            VStack(alignment: .leading, spacing: 17) {
                Eyebrow(text: "01 / CHOOSE THE WORK")
                Text("Local inference").font(.system(size: 19, weight: .medium))
                VStack(alignment: .leading, spacing: 7) {
                    Text("Installed model").font(.system(size: 11, weight: .medium))
                    Picker("Installed model", selection: $model.selectedModel) {
                        if model.runtime.models.isEmpty { Text("Start runtime to discover models").tag("") }
                        ForEach(model.runtime.models) { Text($0.name).tag($0.name) }
                    }.labelsHidden().frame(maxWidth: .infinity).disabled(!model.runtime.running || model.runtime.busy || model.runtimePending)
                    Text("\(model.runtime.models.count) compatible · \(model.runtime.excluded) cloud or unsupported models excluded")
                        .font(.system(size: 10)).foregroundStyle(QuietTheme.muted)
                }
                Picker("Processing unit", selection: $model.selectedDevice) { ForEach(ComputeDevice.allCases, id: \.self) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().disabled(!model.canInfer)
                Button("Load / switch device") { model.runtimeAction(.load(model.selectedModel, model.selectedDevice)) }
                    .buttonStyle(QuietButton(prominent: false)).disabled(!model.canInfer)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Input text · stays on your Mac").font(.system(size: 11, weight: .medium))
                    TextEditor(text: $model.input).font(.system(size: 12)).frame(height: 100).padding(8)
                        .scrollContentBackground(.hidden).background(QuietTheme.surface, in: RoundedRectangle(cornerRadius: 8)).disabled(!model.canInfer)
                }
                HStack {
                    Button("Run inference ↗") { model.runtimeAction(.run(model.selectedModel, model.selectedDevice, model.input)) }.buttonStyle(QuietButton())
                    Button("Compare") { model.runtimeAction(.compare(model.selectedModel, model.input)) }.buttonStyle(QuietButton(prominent: false))
                }.disabled(!model.canInfer)
                Text("CPU uses 2 inference threads. Measured auto needs a comparison for this exact model and input. Switching happens between requests.")
                    .font(.system(size: 11)).foregroundStyle(QuietTheme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                if let error = model.runtime.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }
    }

    private var placement: some View {
        QuietCard {
            VStack(alignment: .leading, spacing: 17) {
                HStack { Eyebrow(text: "02 / VERIFY PLACEMENT"); Spacer(); StatusPill(text: model.runtime.observed == nil ? "UNVERIFIED / UNLOADED" : "RUNTIME REPORTED", active: model.runtime.observed != nil) }
                HStack {
                    VStack(alignment: .leading, spacing: 8) { Eyebrow(text: "Requested"); Text(model.runtime.requested?.label ?? "—").font(.system(size: 22, weight: .medium)) }
                    Spacer(); Image(systemName: "arrow.right").foregroundStyle(QuietTheme.accent); Spacer()
                    VStack(alignment: .leading, spacing: 8) { Eyebrow(text: "Observed"); Text(model.runtime.observed?.device.label ?? "—").font(.system(size: 22, weight: .medium)) }
                }
                if let p = model.runtime.observed {
                    Text("\(p.model) · GPU allocation \(memory(p.gpuBytes)) · checked \(p.date.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 10)).foregroundStyle(QuietTheme.muted)
                } else { Text("Placement comes from the loaded-model report, never the selector.").font(.system(size: 11)).foregroundStyle(QuietTheme.muted) }
                Text("GPU means GPU-assisted execution. Allocation is not utilization or dedicated VRAM.").font(.system(size: 10)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var benchmark: some View {
        QuietCard {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "03 / CHOOSE WITH EVIDENCE")
                Text("Warm request latency").font(.system(size: 16, weight: .semibold))
                if let c = model.runtime.comparison {
                    let maximum = max(c.cpuMilliseconds, c.gpuMilliseconds, 0.001)
                    benchmarkRow("CPU", value: c.cpuMilliseconds, maximum: maximum)
                    benchmarkRow("GPU", value: c.gpuMilliseconds, maximum: maximum)
                    Text("Selected \(c.winner.label). Three warm runs per device; loading excluded.").font(.system(size: 11))
                } else {
                    Text("Compare performs a warm-up and three measured requests on each device, then loads the winner.").font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
                }
                Text("Near ties favor GPU. CPU wins when more than 10% faster. This measures latency, not energy or thermal savings.").font(.system(size: 10)).foregroundStyle(QuietTheme.muted)
            }
        }
    }
    private func benchmarkRow(_ label: String, value: Double, maximum: Double) -> some View {
        HStack {
            Text(label).frame(width: 30, alignment: .leading)
            ProgressView(value: value, total: maximum).tint(label == "GPU" ? QuietTheme.chartGPU : QuietTheme.chartCPU)
            Text(latency(value)).monospacedDigit().frame(width: 75, alignment: .trailing)
        }.font(.system(size: 11))
    }
    private var result: some View {
        QuietCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Latest result").font(.system(size: 14, weight: .semibold)); Spacer(); if let r = model.runtime.result { Text(latency(r.milliseconds)).monospacedDigit().font(.system(size: 11)) } }
                if let r = model.runtime.result {
                    Text("\(r.model) · \(r.device.label) · \(r.dimensions.map { "\($0) dimensions" } ?? "\(r.tokens ?? 0) tokens")")
                        .font(.system(size: 10)).foregroundStyle(QuietTheme.muted)
                    ScrollView { Text(r.output).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 100)
                } else { Text("Embeddings return a vector. Completion models return text.").font(.system(size: 11)).foregroundStyle(QuietTheme.muted) }
            }
        }
    }
}

struct PageHeading: View {
    var eyebrow: String
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: eyebrow)
            Text(title).font(QuietTheme.heading(37))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(QuietTheme.muted)
        }.padding(.bottom, 8)
    }
}

struct ActivityPage: View {
    var model: QuietModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            QuietPageHero(painting: .workloads, eyebrow: "A CLEAR RECORD", title: "Every change, in view.", subtitle: "The last 100 events this session. No inference input, output, or command arguments are logged.")
            VStack(alignment: .leading, spacing: 8) {
                Text("Local observation history").font(.headline)
                Text(model.recordingStatus).font(.caption).textSelection(.enabled)
                Text("CPU, temperature, top processes and findings are saved every 15 seconds. Control actions are saved when they occur.").font(.caption).foregroundStyle(QuietTheme.muted)
                Button("Open telemetry folder") {
                    if !NSWorkspace.shared.open(ObservationStore.defaultDirectory) {
                        model.message = "Telemetry folder is unavailable. Check the recording status above."
                    }
                }
            }
            if model.allEvents.isEmpty { ContentUnavailableView("Observation only", systemImage: "clock", description: Text("Actions appear here when you change a mode, launch a job, or run inference.")) }
            ForEach(model.allEvents) { event in
                HStack(alignment: .top, spacing: 20) {
                    Text(event.date.formatted(date: .omitted, time: .standard)).font(.system(size: 11, design: .monospaced)).foregroundStyle(QuietTheme.muted).frame(width: 95, alignment: .leading)
                    Text(event.text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.vertical, 12)
                Divider().opacity(0.5)
            }
        }
    }
}
