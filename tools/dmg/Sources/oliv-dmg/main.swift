import Foundation
import AppKit
import DSStore

enum ToolError: Error { case usage, missingImage, invalidStore }

func layout(_ volume: URL) throws {
    var store = DSStore()
    try store.setIconPosition(for: "OLIV.app", x: 165, y: 240)
    try store.setIconPosition(for: "Applications", x: 495, y: 240)
    try store.setWindowBounds(top: 140, left: 200, bottom: 540, right: 860)
    store.setWindowSettings(.init(windowBounds: "{{200, 140}, {660, 400}}",
        sidebarWidth: 0, containerShowSidebar: false, showSidebar: false,
        showTabView: false, showToolbar: false, showStatusBar: false, showPathBar: false))
    store.setViewStyle(.iconView)
    store.setIconViewSettings(.init(showIconPreview: true, showItemInfo: false,
        labelOnBottom: true, textSize: 13, iconSize: 128, arrangeBy: "none"))
    // Native alias records must be created on the mounted image itself.
    try store.setBackgroundPicture(imageURL: volume.appendingPathComponent(".background/bg.tiff"), relativeTo: volume)
    let url = volume.appendingPathComponent(".DS_Store")
    try store.write(to: url)
    try verify(volume)
}
func verify(_ volume: URL) throws {
    let store = try DSStore.read(from: volume.appendingPathComponent(".DS_Store"))
    guard let app = store.iconPosition(for: "OLIV.app"), app.x == 165, app.y == 240,
          let applications = store.iconPosition(for: "Applications"), applications.x == 495,
          store.iconViewSettings()?.iconSize == 128,
          case .picture = store.background() else { throw ToolError.invalidStore }
    print("Finder layout verified")
}
func renderBackground(_ root: URL) throws {
    let out = root.appendingPathComponent("assets/dmg")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    guard let mark = NSImage(contentsOf: root.appendingPathComponent("oliv_logo_assets/oliv-mark-transparent.png")) else { throw ToolError.missingImage }
    for scale in [1, 2] {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 660 * scale,
            pixelsHigh: 400 * scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep) else { throw ToolError.missingImage }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        NSColor(red: 251/255, green: 248/255, blue: 237/255, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 660, height: 400).fill()
        let width = mark.size.width * 84 / mark.size.height
        mark.draw(in: NSRect(x: 330 - width/2, y: 280, width: width, height: 84))
        let muted = NSColor(red: 167/255, green: 164/255, blue: 133/255, alpha: 1)
        muted.setStroke(); muted.setFill()
        let arrow = NSBezierPath(); arrow.lineWidth = 7
        arrow.move(to: NSPoint(x: 258, y: 160)); arrow.line(to: NSPoint(x: 380, y: 160)); arrow.stroke()
        let head = NSBezierPath(); head.move(to: NSPoint(x: 402, y: 160))
        head.line(to: NSPoint(x: 380, y: 145)); head.line(to: NSPoint(x: 380, y: 175)); head.close(); head.fill()
        let caption = "Drag OLIV into the Applications folder to install" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Helvetica", size: 15) ?? NSFont.systemFont(ofSize: 15), .foregroundColor: muted]
        caption.draw(at: NSPoint(x: (660 - caption.size(withAttributes: attributes).width)/2, y: 28), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "bg.png" : "bg@2x.png"
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ToolError.missingImage }
        try png.write(to: out.appendingPathComponent(name))
    }
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
    process.arguments = ["-cathidpicheck", out.appendingPathComponent("bg.png").path,
        out.appendingPathComponent("bg@2x.png").path, "-out", out.appendingPathComponent("bg.tiff").path]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ToolError.missingImage }
}

guard CommandLine.arguments.count == 3 else { throw ToolError.usage }
let url = URL(fileURLWithPath: CommandLine.arguments[2])
switch CommandLine.arguments[1] {
case "layout": try layout(url)
case "verify": try verify(url)
case "background": try renderBackground(url)
default: throw ToolError.usage
}
