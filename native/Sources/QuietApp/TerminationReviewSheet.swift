import SwiftUI
import QuietCore

struct TerminationReviewSheet: View {
    @Bindable var model: QuietModel
    let review: TerminationReview
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(review.canForce ? "Review force-stop" : "Review process stop").font(QuietTheme.heading(28))
            Text("\(review.name) · PID \(review.process.pid)").font(.headline)
            Text(review.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text("Detected role: \(review.role)").font(.system(size: 12))
            if review.allowed {
                Label("Same-user test runner · no child processes · no network sockets", systemImage: "checkmark.shield")
                    .font(.system(size: 12)).foregroundStyle(QuietTheme.accent)
                Text(review.canForce
                     ? "The previous graceful stop did not exit within 10 seconds. Force-stop sends SIGKILL to this PID only, preventing cleanup and potentially losing test output or leaving temporary files."
                     : "Stop sends SIGTERM to this PID only and waits up to 10 seconds. The test can end before cleanup or output is complete. Force-stop is never automatic.")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Text("These checks cannot prove zero impact. Files, IPC or external dependencies may still be shared. Identity and isolation are checked again when you confirm; this review expires after 60 seconds.")
                    .font(.system(size: 11)).foregroundStyle(QuietTheme.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(review.blockers, id: \.self) { Text("• " + $0).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true) }
                Text("No signal will be sent. Use the service's own controls or investigate further.").font(.system(size: 12)).foregroundStyle(QuietTheme.muted)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.terminationReview = nil }.keyboardShortcut(.cancelAction)
                if review.allowed {
                    Button(review.canForce ? "Force-stop test" : "Stop test", role: .destructive) { model.confirmStop(force: review.canForce) }
                        .disabled(model.terminationBusy)
                }
            }
        }.padding(28).frame(width: 540).foregroundStyle(QuietTheme.ink).background(QuietTheme.surface)
    }
}
