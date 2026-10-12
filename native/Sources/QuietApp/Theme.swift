import AppKit
import SwiftUI
import QuietCore

/// Original neutral app shell. Mëngøh Labs colors are reserved for data visualization.
enum QuietTheme {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
    static let paper = adaptive(0xF5F5F5, 0x16181B)
    static let surface = adaptive(0xFFFFFF, 0x1D2024)
    static let ink = adaptive(0x1F1F1F, 0xE8E8E8)
    static let muted = adaptive(0x787878, 0x9C9C9C)
    static let accent = adaptive(0x1F7A70, 0x70D9B8)
    static let banner = adaptive(0xEBF2ED, 0x1B2E2E)
    static let line = ink.opacity(0.08)
    static let chartCPU = adaptive(MengohPalette.moss, MengohPalette.moss)
    static let chartGPU = adaptive(MengohPalette.research, MengohPalette.research)
    static func heading(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
}

struct QuietCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(QuietTheme.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(QuietTheme.line, lineWidth: 1))
    }
}

struct Eyebrow: View {
    var text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(QuietTheme.muted) }
}

struct QuietButton: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundStyle(prominent ? QuietTheme.surface : QuietTheme.ink)
            .background(prominent ? QuietTheme.ink : QuietTheme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

struct StatusPill: View {
    var text: String
    var active = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(active ? QuietTheme.accent : QuietTheme.muted).frame(width: 5, height: 5)
            Text(text).font(.system(size: 9, weight: .medium))
        }.padding(.horizontal, 9).padding(.vertical, 6)
            .background(QuietTheme.banner, in: Capsule())
    }
}

struct NavigationSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        } else {
            content.background(QuietTheme.paper, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}
