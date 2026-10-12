import AppKit
import Foundation
// Deterministic packaging only: preserve the official portrait's pixels/proportions.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let sourceURL = root.appendingPathComponent("Glyph-avatar.png")
guard let source = NSImage(contentsOf: sourceURL) else { fatalError("Missing official Glyph portrait") }
let iconset = root.appendingPathComponent("Quiet.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let side = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    NSColor.clear.setFill(); NSRect(x:0,y:0,width:side,height:side).fill()
    let scale = side * 0.94 / max(source.size.width, source.size.height)
    let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
    source.draw(in: NSRect(x:(side-size.width)/2,y:(side-size.height)/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:1)
    image.unlockFocus()
    guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:data), let png = bitmap.representation(using:.png,properties:[:]) else { fatalError("Icon export failed") }
    try png.write(to:iconset.appendingPathComponent(name+".png"))
}
