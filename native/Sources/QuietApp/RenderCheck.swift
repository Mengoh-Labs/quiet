#if DEBUG
import AppKit
import Foundation
import SwiftUI
import QuietCore

/// Debug-only rendering of this app's own content. No screen capture permission,
/// synthetic telemetry, external app control, or release automation endpoint.
@MainActor enum RenderCheck {
    static func run(directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await Task.sleep(for: .seconds(7))
            guard let window = NSApp.windows.first(where: { $0.title == "Quiet" }), let content = window.contentView else { throw QuietError("No native window to render.") }
            let model = QuietModel.shared
            let savedZoom = model.zoomPercent
            defer { model.zoomPercent = savedZoom }
            if CommandLine.arguments.contains("--art-only") { model.zoomPercent = 100 }
            guard !model.telemetry.processes.isEmpty, model.telemetry.cpu != nil else { throw QuietError("Live native telemetry missing.") }
            window.setContentSize(NSSize(width: 1240, height: 900))
            model.appearance = "Light"
            try await Task.sleep(for: .seconds(1))
            try capture(content, at: directory.appendingPathComponent("native-overview-light.png"))
            model.appearance = "Dark"
            try await Task.sleep(for: .seconds(1))
            try capture(content, at: directory.appendingPathComponent("native-overview-dark.png"))
            if CommandLine.arguments.contains("--termination-only") {
                try await verifyTermination(model, window: window, directory: directory)
                print("TERMINATION UI PASS: native review, graceful stop, separate force review, protected-self block, Activity evidence. Only owned test fixtures signaled.")
                fflush(stdout); NSApp.terminate(nil); return
            }
            if CommandLine.arguments.contains("--diagnostics-only") {
                let deadline = Date().addingTimeInterval(65)
                while (model.hotspots.isEmpty || model.diagnosticContexts.isEmpty) && Date() < deadline {
                    try await Task.sleep(for: .seconds(2))
                }
                guard !model.hotspots.isEmpty, !model.diagnosticContexts.isEmpty else { throw QuietError("No sustained live finding/context observed in verification window") }
                let panel = NSHostingView(rootView: HotspotsPanel(model: model).padding(20).frame(width: 1000).background(QuietTheme.surface))
                panel.setFrameSize(NSSize(width: 1000, height: max(600, panel.fittingSize.height)))
                try capture(panel, at: directory.appendingPathComponent("diagnostics-live.png"))
                for item in model.hotspots { print("LIVE FINDING: PID \(item.id.pid), \(Int(item.meanCPU))% CPU, \(model.diagnosticContexts[item.id]?.role ?? "unavailable")") }
                print("DIAGNOSTICS CHECK PASS: live sustained load, read-only context, native panel, normal shutdown.")
                fflush(stdout); NSApp.terminate(nil); return
            }
            if CommandLine.arguments.contains("--zoom-only") {
                defer { model.zoomPercent = 100 }
                window.setContentSize(NSSize(width: 1080, height: 760))
                for level in [75, 100, 150] {
                    model.zoomPercent = level
                    for appearance in ["Light", "Dark"] {
                        model.appearance = appearance
                        try await Task.sleep(for: .milliseconds(500))
                        try capture(content, at: directory.appendingPathComponent("zoom-\(level)-\(appearance).png"))
                    }
                }
                model.zoomPercent = 100; model.zoomIn()
                guard model.zoomPercent == 110 else { throw QuietError("Zoom in failed") }
                model.zoomOut()
                guard model.zoomPercent == 100 else { throw QuietError("Zoom out failed") }
                model.zoomPercent = 100
                print("ZOOM CHECK PASS: 75/100/150 percent, light/dark, minimum window, zoom actions and reset.")
                fflush(stdout); NSApp.terminate(nil); return
            }
            if CommandLine.arguments.contains("--art-only") {
                for page in QuietPage.allCases {
                    model.page = page
                    for appearance in ["Light", "Dark"] {
                        model.appearance = appearance
                        window.setContentSize(NSSize(width: 1080, height: 760))
                        try await Task.sleep(for: .milliseconds(500))
                        try capture(content, at: directory.appendingPathComponent("art-\(page.rawValue)-\(appearance).png"))
                    }
                }
                print("ART CHECK PASS: all four pages, light/dark, minimum window, live telemetry. No inference run.")
                fflush(stdout)
                NSApp.terminate(nil)
                return
            }
            model.page = .acceleration
            window.setContentSize(NSSize(width: 1080, height: 760))
            try await Task.sleep(for: .seconds(1))
            try capture(content, at: directory.appendingPathComponent("native-acceleration-min.png"))
            // Actual native providers and packaged Metal library, no mock responses.
            if model.hardware?.appleAvailable == true {
                model.engine = "Apple Intelligence"
                model.nativeInput = "Say hello in one short sentence."
                model.runNative()
                try await waitNative(model)
                guard model.silicon.result?.backend == .apple else { throw QuietError(model.message ?? "Apple response missing.") }
                try capture(content, at: directory.appendingPathComponent("native-apple-verified.png"))
            }
            model.engine = "MLX"
            model.nativeInput = "Say hello in one short sentence."
            model.runNative()
            try await waitNative(model)
            guard model.silicon.result?.backend == .mlx else { throw QuietError(model.message ?? "MLX response missing.") }
            try await Task.sleep(for: .milliseconds(500))
            try capture(content, at: directory.appendingPathComponent("native-mlx-verified.png"))
            model.engine = "Ollama"
            // Exercise actual native app / URLSession / controller integration.
            model.runtimeAction(.start)
            try await wait(model)
            guard model.runtime.running else { throw QuietError(model.message ?? "Native runtime did not start.") }
            model.runtimeAction(.load("nomic-embed-text:latest", .gpu))
            try await wait(model)
            guard model.runtime.observed?.device == .gpu else { throw QuietError(model.message ?? "Native GPU switch unverified.") }
            model.runtimeAction(.run("nomic-embed-text:latest", .gpu, "search_document: Native Swift UI integration check."))
            try await wait(model)
            guard model.runtime.result?.dimensions == 768 else { throw QuietError("Native inference result missing.") }
            try await Task.sleep(for: .milliseconds(500))
            try capture(content, at: directory.appendingPathComponent("native-gpu-verified.png"))
            model.setMode(.quiet)
            while model.changingMode { try await Task.sleep(for: .milliseconds(100)) }
            guard model.queue.mode == .quiet, !model.runtime.running else { throw QuietError("Quiet did not stop the owned runtime.") }
            model.setMode(.observe)
            while model.changingMode { try await Task.sleep(for: .milliseconds(100)) }
            model.message = nil
            model.page = .overview
            print("NATIVE UI CHECK PASS: live telemetry, Glyph light/dark/minimum-size rendering, native MLX and available Apple inference, GPU placement, 768-dimensional inference, Quiet shutdown and Observe restoration.")
            fflush(stdout)
        } catch { print("NATIVE UI CHECK FAILED: \(error.localizedDescription)"); fflush(stdout) }
        NSApp.terminate(nil)
    }
    private static func verifyTermination(_ model: QuietModel, window: NSWindow, directory: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-ui-stop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in ["graceful", "ignore"] {
            let marker = root.appendingPathComponent("ready")
            try? FileManager.default.removeItem(at: marker)
            let file = root.appendingPathComponent("fixture.test.js")
            let action = mode == "graceful" ? "process.exit(0)" : ""
            try "import {test} from 'bun:test'; import {writeFileSync} from 'node:fs'; process.on('SIGTERM', () => { \(action) }); writeFileSync('ready','ready'); test('UI fixture', async () => { await new Promise(r => setTimeout(r, 55000)); });".write(to: file, atomically: true, encoding: .utf8)
            let fixture = Process()
            fixture.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/bun")
            fixture.arguments = ["test", "--timeout", "60000", file.path]
            fixture.currentDirectoryURL = root
            fixture.standardOutput = FileHandle.nullDevice; fixture.standardError = FileHandle.nullDevice
            try fixture.run()
            guard let identity = NativeProcess.read(fixture.processIdentifier)?.id else { fixture.terminate(); throw QuietError("No fixture identity") }
            defer {
                if fixture.isRunning, NativeProcess.read(identity.pid)?.id == identity { _ = kill(identity.pid, SIGKILL) }
                fixture.waitUntilExit()
            }
            let ready = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: marker.path), Date() < ready { try await Task.sleep(for: .milliseconds(50)) }
            guard FileManager.default.fileExists(atPath: marker.path) else { throw QuietError("Fixture not ready") }
            model.reviewStop(identity)
            try await waitTermination(model)
            guard model.terminationReview?.allowed == true, model.terminationReview?.canForce == false else { throw QuietError("Fixture review failed") }
            try await Task.sleep(for: .milliseconds(400))
            if let sheet = window.sheets.first?.contentView { try capture(sheet, at: directory.appendingPathComponent("stop-review-\(mode).png")) }
            else { throw QuietError("Native review sheet missing") }
            model.confirmStop(force: false)
            try await waitTermination(model)
            if mode == "ignore" {
                guard model.forceCandidate == identity, fixture.isRunning else { throw QuietError("No force-review candidate") }
                model.reviewStop(identity)
                try await waitTermination(model)
                guard model.terminationReview?.canForce == true else { throw QuietError("Fresh force review missing") }
                try await Task.sleep(for: .milliseconds(400))
                guard let sheet = window.sheets.first?.contentView else { throw QuietError("Force review sheet missing") }
                try capture(sheet, at: directory.appendingPathComponent("force-review.png"))
                model.confirmStop(force: true)
                try await waitTermination(model)
            }
            guard model.forceCandidate == nil, model.message?.contains("exited after") == true else { throw QuietError("Exit not verified by model") }
        }
        guard let own = NativeProcess.read(getpid())?.id else { throw QuietError("No own identity") }
        model.reviewStop(own)
        try await waitTermination(model)
        guard model.terminationReview?.allowed == false else { throw QuietError("Protected process not blocked") }
        try await Task.sleep(for: .milliseconds(400))
        if let sheet = window.sheets.first?.contentView { try capture(sheet, at: directory.appendingPathComponent("protected-review.png")) }
        model.terminationReview = nil
        guard model.terminationEvents.count >= 3 else { throw QuietError("Termination activity missing") }
    }
    private static func waitTermination(_ model: QuietModel) async throws {
        let deadline = Date().addingTimeInterval(25)
        while model.terminationBusy {
            guard Date() < deadline else { throw QuietError("Termination check timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func waitNative(_ model: QuietModel) async throws {
        let deadline = Date().addingTimeInterval(130)
        while model.siliconPending {
            guard Date() < deadline else { throw QuietError("Native inference timed out.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private static func wait(_ model: QuietModel) async throws {
        let deadline = Date().addingTimeInterval(130)
        while model.runtimePending {
            guard Date() < deadline else { throw QuietError("Native action timed out.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private static func capture(_ view: NSView, at url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw QuietError("Native view bitmap unavailable.") }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { throw QuietError("PNG encoding failed.") }
        try data.write(to: url)
    }
}
#endif
