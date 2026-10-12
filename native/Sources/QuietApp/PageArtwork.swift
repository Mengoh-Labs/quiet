import AppKit
import SwiftUI

enum QuietPainting: String, CaseIterable {
    case overview = "Glyph-quiet-observatory"
    case workloads = "Glyph-publish"
    case acceleration = "Glyph-compare"
}

/// Cached static paintings: no animation loop, hit targets, or telemetry work.
@MainActor private enum PaintedAssets {
    static let images: [QuietPainting: NSImage] = Dictionary(uniqueKeysWithValues: QuietPainting.allCases.compactMap { painting in
        guard let url = Bundle.main.url(forResource: painting.rawValue, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return (painting, image)
    })
}

struct QuietPageHero: View {
    var painting: QuietPainting
    var eyebrow: String
    var title: String
    var subtitle: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if let image = PaintedAssets.images[painting] {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(width: geometry.size.width * (painting == .overview ? 0.48 : 0.40), height: 250)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow(text: eyebrow)
                    Text(title).font(QuietTheme.heading(37)).frame(width: geometry.size.width * 0.53, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(QuietTheme.muted)
                        .lineSpacing(4).frame(width: geometry.size.width * 0.50, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }.frame(width: geometry.size.width * 0.55, alignment: .leading)
            }.frame(width: geometry.size.width, height: 260)
        }.frame(height: 260).clipped()
    }
}
