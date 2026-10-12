import AppKit
import QuietCore
import SwiftUI

@main struct QuietApplication: App {
    @NSApplicationDelegateAdaptor(QuietDelegate.self) private var delegate
    @State private var model = QuietModel.shared
    var body: some Scene {
        Window("Quiet", id: "quiet") {
            ZoomableQuietShell(model: model)
                .sheet(item: $model.terminationReview) { review in TerminationReviewSheet(model: model, review: review) }
                .preferredColorScheme(model.appearance == "Dark" ? .dark : model.appearance == "Light" ? .light : nil)
                .frame(minWidth: 1080, minHeight: 760)
        }.defaultSize(width: 1240, height: 900).windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(after: .toolbar) {
                    Button("Zoom In") { model.zoomIn() }.keyboardShortcut("+", modifiers: .command).disabled(model.zoomPercent == 150)
                    Button("Zoom Out") { model.zoomOut() }.keyboardShortcut("-", modifiers: .command).disabled(model.zoomPercent == 75)
                    Button("Actual Size") { model.zoomPercent = 100 }.keyboardShortcut("0", modifiers: .command)
                }
                CommandGroup(after: .appInfo) {
                    Button("Enable Quiet mode") { model.setMode(.quiet) }.keyboardShortcut("q", modifiers: [.command, .shift])
                    Button("Restore normal scheduling") { model.setMode(.observe) }
                }
            }
        MenuBarExtra {
            MenuControls(model: model)
        } label: {
            Label(model.queue.mode == .quiet ? "Quiet" : model.telemetry.cpu.map { "\(Int($0))%" } ?? "Quiet", systemImage: model.queue.mode == .quiet ? "leaf.fill" : "wind")
        }.menuBarExtraStyle(.window)
    }
}

@MainActor final class QuietDelegate: NSObject, NSApplicationDelegate {
    private var terminating = false
    private var primaryInstance = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: QuietSupport.identifier)
            .filter { $0.processIdentifier != getpid() }
        if let running = others.first {
            running.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        primaryInstance = true
        QuietModel.shared.start()
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-check"), CommandLine.arguments.indices.contains(index + 1) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await RenderCheck.run(directory: directory) }
        }
        #endif
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard primaryInstance else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        #if DEBUG
        FileHandle.standardError.write(Data("Native shutdown requested\n".utf8))
        #endif
        let (inference, jobs, nativeRuntime) = QuietModel.shared.beginShutdown()
        // terminateLater switches AppKit into a modal run loop. A MainActor Task
        // can then starve. Cleanup stays on its actors; reply explicitly in that mode.
        Task.detached {
            await nativeRuntime.stop()
            await inference.stop()
            await jobs.restoreAll()
            #if DEBUG
            FileHandle.standardError.write(Data("Native scheduling/runtime cleanup complete\n".utf8))
            #endif
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated { sender.reply(toApplicationShouldTerminate: true) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.title == "Quiet" }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

/// Scale the layout and its scrollable bounds together, keeping controls reachable at every zoom.
struct ZoomableQuietShell: View {
    @Bindable var model: QuietModel
    var body: some View {
        GeometryReader { viewport in
            let width = max(1080, viewport.size.width / model.zoom)
            let height = max(760, viewport.size.height / model.zoom)
            ScrollView([.horizontal, .vertical]) {
                QuietShell(model: model)
                    .frame(width: width, height: height)
                    .scaleEffect(model.zoom, anchor: .topLeading)
                    .frame(width: width * model.zoom, height: height * model.zoom, alignment: .topLeading)
            }.background(QuietTheme.paper)
        }
    }
}

struct QuietShell: View {
    @Bindable var model: QuietModel
    var body: some View {
        HStack(spacing: 10) {
            sidebar.modifier(NavigationSurface()).padding(.leading, 10).padding(.vertical, 10)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Spacer()

                    Picker("Workload care", selection: Binding(get: { model.queue.mode }, set: { model.setMode($0) })) {
                        ForEach(CareMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 245).disabled(model.changingMode)
                }.padding(.horizontal, 28).padding(.vertical, 20)
                Divider().opacity(0.3)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let message = model.message {
                            HStack(alignment: .top) {
                                Image(systemName: "info.circle")
                                Text(message).textSelection(.enabled)
                                Spacer()
                                Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
                            }.font(.system(size: 11)).padding(13).background(QuietTheme.banner, in: RoundedRectangle(cornerRadius: 10))
                        }
                        if let error = model.telemetry.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        switch model.page {
                        case .overview: OverviewPage(model: model)
                        case .workloads: WorkloadsPage(model: model)
                        case .acceleration: AccelerationPage(model: model)
                        case .activity: ActivityPage(model: model)
                        }
                    }.padding(28)
                }.scrollContentBackground(.hidden)
            }.background(QuietTheme.surface).clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(QuietTheme.line))
                .padding(.vertical, 10).padding(.trailing, 10)
        }.foregroundStyle(QuietTheme.ink).background(QuietTheme.paper).tint(QuietTheme.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                GlyphArtwork().frame(width: 38, height: 38)
                Text("Quiet").font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-1)
            }.padding(.horizontal, 12).padding(.top, 26).padding(.bottom, 31)
            ForEach(QuietPage.allCases) { page in
                Button { model.page = page } label: {
                    HStack(spacing: 11) {
                        Image(systemName: page.symbol).frame(width: 18)
                        Text(page.rawValue)
                        Spacer()
                        if page == .workloads && model.activeJobs > 0 { Text("\(model.activeJobs)").font(.system(size: 9)).padding(4).background(QuietTheme.line, in: RoundedRectangle(cornerRadius: 4)) }
                    }.font(.system(size: 12, weight: model.page == page ? .semibold : .regular))
                        .foregroundStyle(model.page == page ? QuietTheme.ink : QuietTheme.muted)
                        .padding(.horizontal, 13).padding(.vertical, 12)
                        .background(model.page == page ? QuietTheme.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).padding(.vertical, 2)
            }
            Spacer(minLength: 35)
            VStack(alignment: .leading, spacing: 10) {
                Label("Room to keep going.", systemImage: "leaf").font(.system(size: 12, weight: .semibold))
                Text("On-device. Under your control.\nExisting work keeps running.").font(.system(size: 11)).foregroundStyle(QuietTheme.muted).lineSpacing(4)
                StatusPill(text: "NATIVE SWIFT", active: true)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(QuietTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(QuietTheme.line)).padding(.bottom, 20)
            Picker("Appearance", selection: $model.appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }.labelsHidden().pickerStyle(.segmented).padding(.bottom, 16)
            Divider().opacity(0.4)
            Text("QUANDRY LABS / QUIET 0.8").font(.system(size: 8, weight: .medium)).tracking(1.1).foregroundStyle(QuietTheme.muted).padding(.horizontal, 12).padding(.vertical, 19)
        }.padding(.horizontal, 12).frame(width: 203)
    }
}

private struct MenuControls: View {
    @Bindable var model: QuietModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Label("Quiet", systemImage: "wind").font(.headline); Spacer(); Text("NATIVE").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary) }
            HStack { Text("CPU"); Spacer(); Text(percent(model.telemetry.cpu)).monospacedDigit() }
            HStack { Text("CPU temperature"); Spacer(); Text(model.telemetry.cpuTemperature.map { String(format: "%.1f °C", $0.hottestCelsius) } ?? "Unavailable").monospacedDigit() }
            HStack { Text("Thermal pressure"); Spacer(); Text(model.telemetry.thermal.label) }
            Divider()
            Picker("Care", selection: Binding(get: { model.queue.mode }, set: { model.setMode($0) })) { ForEach(CareMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().disabled(model.changingMode)
            Text(model.queue.mode.detail).font(.caption).foregroundStyle(.secondary)
            Button("Open Quiet") { openWindow(id: "quiet"); NSApp.activate(ignoringOtherApps: true) }
            Button("Quit & restore scheduling") { NSApp.terminate(nil) }.font(.caption)
        }.padding(20).frame(width: 310)
    }
}
