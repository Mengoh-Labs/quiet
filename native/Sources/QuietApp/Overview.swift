import AppKit
import Charts
import QuietCore
import SwiftUI

struct OverviewPage: View {
    @Bindable var model: QuietModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            QuietPageHero(painting: .overview, eyebrow: "A LITTLE MORE ROOM TO BREATHE",
                          title: "Give your Mac a breather.", subtitle: "See the pressure. Choose the work. Keep control.")
            HStack(spacing: 12) {
                Metric(title: "CPU CAPACITY", value: percent(model.telemetry.cpu), detail: "Across \(model.telemetry.cores) cores", symbol: "cpu")
                Metric(title: "THERMAL PRESSURE", value: model.telemetry.thermal.label, detail: "Reported by macOS", symbol: "thermometer.medium", highlight: true)
                Metric(title: "CPU TEMPERATURE", value: model.telemetry.cpuTemperature.map { String(format: "%.1f °C", $0.hottestCelsius) } ?? "—", detail: model.telemetry.cpuTemperature.map { "Hottest of \($0.sensorCount) CPU sensors" } ?? "Sensor unavailable", symbol: "thermometer", highlight: true)
                Metric(title: "QUIET’S OWN CPU", value: percent(model.ownCPU), detail: "100% = one core", symbol: "gauge.with.dots.needle.33percent")
            }
            HStack(alignment: .top, spacing: 16) {
                QuietCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("The last three minutes").font(.system(size: 14, weight: .semibold)); Spacer(); StatusPill(text: "LIVE", active: true) }
                        Chart(model.history) { point in
                            AreaMark(x: .value("Time", point.date), y: .value("CPU", point.cpu)).foregroundStyle(QuietTheme.chartCPU.opacity(0.12))
                            LineMark(x: .value("Time", point.date), y: .value("CPU", point.cpu)).foregroundStyle(QuietTheme.chartCPU).lineStyle(.init(lineWidth: 1.6))
                        }.chartYScale(domain: 0...100)
                            .chartXScale(domain: model.telemetry.timestamp.addingTimeInterval(-180)...model.telemetry.timestamp)
                            .chartXAxis(.hidden).chartYAxis { AxisMarks(values: [0, 50, 100]) }
                            .frame(height: 106).accessibilityLabel("System CPU history, zero to one hundred percent")
                        HStack { Text("3 minutes ago"); Spacer(); Text("Now") }.font(.system(size: 9)).foregroundStyle(QuietTheme.muted)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow(text: "A QUIETER PACE")
                    Text(model.queue.mode == .quiet ? "Less work, on your terms." : "Start with the workload.").font(QuietTheme.heading(23)).fixedSize(horizontal: false, vertical: true)
                    Text(model.queue.mode == .quiet ? "New Quiet jobs wait. Quiet’s inference runtime is stopped. Existing apps keep running." : "Quiet mode holds new Quiet jobs, backgrounds its running jobs, and releases its inference runtime.")
                        .font(.system(size: 12)).foregroundStyle(QuietTheme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    Button(model.queue.mode == .quiet ? "Return to Balanced" : "Enable Quiet mode") { model.setMode(model.queue.mode == .quiet ? .balanced : .quiet) }
                        .buttonStyle(QuietButton()).disabled(model.changingMode)
                }.padding(22).frame(width: 290, alignment: .leading)
                    .background(QuietTheme.banner, in: RoundedRectangle(cornerRadius: 16))
            }
            HStack { Button("Explain this snapshot locally ↗") { model.explainPressure() }.buttonStyle(.link); Spacer(); Text("Apple Intelligence · review the prompt before running").font(.system(size: 10)).foregroundStyle(QuietTheme.muted) }
            HotspotsPanel(model: model)
            processTable
            HStack(spacing: 15) {
                Label("Native Swift · no webview", systemImage: "swift")
                Text("Sampling \(Int(model.telemetry.sampleMilliseconds)) ms")
                Text("Physical RAM \(memory(model.telemetry.ram))")
                Text("Low Power Mode: \(model.telemetry.lowPower ? "On" : "Off")")
                Spacer()
                Text("Fan speed stays under macOS control")
            }.font(.system(size: 10)).foregroundStyle(QuietTheme.muted)
        }
    }

    private var processTable: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What’s using your Mac").font(.system(size: 15, weight: .semibold))
                    Text("\(model.telemetry.processes.count) readable processes · top 80 matches · interval CPU")
                        .font(.system(size: 10)).foregroundStyle(QuietTheme.muted)
                }
                Spacer()
                Menu {
                    ForEach(["All workloads", "Development", "AI", "Virtual machine", "App / system"], id: \.self) { category in
                        Button(category) { model.category = category }
                    }
                } label: {
                    Text(model.category).font(.system(size: 11)).foregroundStyle(QuietTheme.ink)
                }.menuStyle(.borderlessButton).frame(width: 135).accessibilityLabel("Filter process category")
                TextField("Find a process", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 145)
            }
            VStack(spacing: 0) {
                HStack {
                    Text("PROCESS").frame(maxWidth: .infinity, alignment: .leading)
                    Text("CPU").frame(width: 80, alignment: .trailing)
                    Text("MEMORY").frame(width: 90, alignment: .trailing)
                    Text("CONTROL").frame(width: 95, alignment: .trailing)
                }.font(.system(size: 9, weight: .medium)).foregroundStyle(QuietTheme.muted).padding(.horizontal, 14).padding(.vertical, 12)
                Divider().opacity(0.4)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.processes.prefix(80))) { p in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text("PID \(p.id.pid) · \(p.category)").font(.system(size: 9)).foregroundStyle(QuietTheme.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading).help(p.path)
                                Text(percent(p.cpu)).monospacedDigit().font(.system(size: 12)).frame(width: 80, alignment: .trailing)
                                Text(p.memory == 0 ? "—" : memory(p.memory)).monospacedDigit().font(.system(size: 12)).frame(width: 90, alignment: .trailing)
                                let managed = model.queue.jobs.contains { $0.identity == p.id && $0.state == "Running" }
                                if managed {
                                    Text("Quiet job").font(.system(size: 10)).foregroundStyle(QuietTheme.accent).frame(width: 95, alignment: .trailing)
                                } else {
                                    Button("Review stop…") { model.reviewStop(p.id) }.buttonStyle(.link)
                                        .font(.system(size: 10)).frame(width: 95, alignment: .trailing).disabled(model.terminationBusy)
                                }
                            }.padding(.horizontal, 14).padding(.vertical, 10).accessibilityElement(children: .combine)
                            Divider().opacity(0.3)
                        }
                    }
                }.frame(height: 240)
            }.background(QuietTheme.paper.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("100% process CPU = one core. Categories are hints. External stops require review; automatic throttling is limited to Quiet jobs.")
                Spacer()
                Button("Activity Monitor ↗") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }.buttonStyle(.link)
            }.font(.system(size: 10)).foregroundStyle(QuietTheme.muted)
        }
    }
}

private struct Metric: View {
    var title: String
    var value: String
    var detail: String
    var symbol: String
    var highlight = false
    var body: some View {
        QuietCard(padding: 17) {
            VStack(alignment: .leading, spacing: 13) {
                HStack { Eyebrow(text: title); Spacer(); Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(QuietTheme.muted) }
                Text(value).font(.system(size: 29, weight: .regular, design: .rounded)).monospacedDigit().foregroundStyle(highlight ? QuietTheme.accent : QuietTheme.ink)
                Text(detail).font(.system(size: 10)).foregroundStyle(QuietTheme.muted)
            }
        }
    }
}
